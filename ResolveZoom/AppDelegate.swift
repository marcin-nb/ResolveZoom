import ApplicationServices
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @State private var multiplier: Double
    @State private var invertZoom: Bool
    @State private var launchAtLogin: Bool

    let onSave: (Double, Bool, Bool) -> Void
    let onCancel: () -> Void

    private let defaultMultiplier = 800.0

    init(
        multiplier: Double, invertZoom: Bool, launchAtLogin: Bool,
        onSave: @escaping (Double, Bool, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _multiplier = State(initialValue: multiplier)
        _invertZoom = State(initialValue: invertZoom)
        _launchAtLogin = State(initialValue: launchAtLogin)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sekcja slidera poza Form — daje pełną szerokość
            VStack(alignment: .leading, spacing: 6) {
                Text("Zoom Sensitivity")
                    .font(.headline)
                    .padding(.leading, 4)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Slider(value: $multiplier, in: 100...1500)
                        Text("\(Int(multiplier))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Button("Reset to Default") { multiplier = defaultMultiplier }
                        .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)

            // Pstryczki w Form — tu grouped style działa idealnie
            Form {
                Section {
                    Toggle("Invert zoom direction", isOn: $invertZoom)
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                }
            }
            .formStyle(.grouped)
            .frame(height: 130)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("OK") { onSave(multiplier, invertZoom, launchAtLogin) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 360, height: 310)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var permissionTimer: Timer?
    private var fusionPollTimer: DispatchSourceTimer?

    var statusMenuItem: NSMenuItem!
    var diagnosticsMenuItem: NSMenuItem!
    var selectResolveMenuItem: NSMenuItem!
    var clearResolveMenuItem: NSMenuItem!
    var permissionsWindow: NSWindow?
    var preferencesWindow: NSWindow?

    let defaults = UserDefaults.standard

    let defaultMultiplier: Double = 800.0
    let sliderMin: Double = 100.0
    let sliderMax: Double = 1500.0

    // Settings are held in memory and mirrored to UserDefaults on write.
    // They used to be computed properties that read UserDefaults on every access —
    // which meant a lookup per magnify event, i.e. 60–120 times a second during a
    // pinch. Reading a stored property costs nothing; `didSet` keeps persistence
    // identical, so every existing assignment site still works unchanged.
    var multiplier: Double = 800.0 {
        didSet { defaults.set(multiplier, forKey: "multiplier") }
    }

    var invertZoom: Bool = false {
        didSet { defaults.set(invertZoom, forKey: "invertZoom") }
    }

    // Scroll-artifact detection
    var lastMagnifyTime: Double = 0
    var lastMagnifySign: Double = 0
    var lastHorizontalScrollTime: Double = 0

    // Consecutive event counter — filters out accidental taps/clicks
    var consecutiveMagnifyCount: Int = 0
    let magnifyCountThreshold: Int = 3
    let magnifyTimeWindow: Double = 0.3

    /// Carries the sub-pixel remainder between events. `Int32(delta)` truncates
    /// toward zero, so at low sensitivity settings a slow pinch produced deltas
    /// below 1.0 that were silently discarded and the gesture appeared to stall.
    var zoomAccumulator: Double = 0

    /// Cached frontmost bundle id. Calling `NSWorkspace.shared.frontmostApplication`
    /// inside the tap callback meant one lookup per event; it only changes when the
    /// active app changes, which we already observe.
    var cachedFrontmostBundleId: String?

    // Diagnostics — surfaced in the menu so a user reporting "it doesn't work" can
    // tell us what the app actually sees instead of us guessing.
    var magnifyEventsSeen: Int = 0
    var magnifyEventsActedOn: Int = 0
    var lastMagnifyMagnitude: Double = 0
    var lastSkipReason: String = "—"

    /// Bundle id the user pinned manually by picking Resolve.app. Empty = auto-detect.
    var resolveBundleIdOverride: String = "" {
        didSet { defaults.set(resolveBundleIdOverride, forKey: "resolveBundleIdOverride") }
    }

    // This state is deliberately main-thread-only. The AX walk returns to the main
    // queue before changing it, and the event tap itself is attached to the main run
    // loop, so the hot path never needs a lock or performs an AX call.
    private var isPausedForFusion = false
    private var activeResolvePage: String?
    private var activeFusionScanID: UUID?
    private var fusionPollingGeneration = 0
    private let fusionPollQueue = DispatchQueue(
        label: "com.resolvezoom.fusion-page-poll", qos: .utility)
    private let fusionPollInterval: TimeInterval = 1.0
    private let axMessagingTimeout: Float = 0.05
    private static let resolvePageNames: Set<String> = [
        "Media", "Cut", "Edit", "Fusion", "Color", "Fairlight", "Deliver",
    ]

    /// Matches DaVinci Resolve. If the user pinned a specific app, only that one counts.
    /// Otherwise fall back to a prefix match: Blackmagic ships one bundle for both the
    /// free and Studio editions, but betas and future builds may differ, and a prefix
    /// costs nothing while failing less often. The prefix is narrow enough to exclude
    /// the siblings installed alongside Resolve (`…DaVinciRemoteMonitor`,
    /// `…UninstallDaVinciResolve`).
    func isResolveApp(_ id: String?) -> Bool {
        guard let id = id else { return false }
        if !resolveBundleIdOverride.isEmpty {
            return id.caseInsensitiveCompare(resolveBundleIdOverride) == .orderedSame
        }
        return id.lowercased().hasPrefix("com.blackmagic-design.davinciresolve")
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadSettings()
        setupMenuBar()
        refreshFrontmostApp()
        checkAccessibilityAndStart()
    }

    /// Reads persisted settings once at launch. Uses the same UserDefaults keys as
    /// before, so existing users keep their configuration.
    func loadSettings() {
        multiplier =
            defaults.object(forKey: "multiplier") == nil
            ? defaultMultiplier
            : defaults.double(forKey: "multiplier")
        invertZoom = defaults.bool(forKey: "invertZoom")
        resolveBundleIdOverride = defaults.string(forKey: "resolveBundleIdOverride") ?? ""
    }

    /// Lets the user point at Resolve.app directly. Auto-detection covers the normal
    /// case, so this is an escape hatch rather than a setup step — it exists for
    /// unusual installs, beta builds, or anything reporting an unexpected bundle id.
    @objc func selectResolveApp() {
        let panel = NSOpenPanel()
        panel.title = "Select DaVinci Resolve"
        panel.message = "Choose the DaVinci Resolve application."
        panel.prompt = "Select"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let id = Bundle(url: url)?.bundleIdentifier else {
            presentInfo(
                title: "Not a valid application",
                text: "Could not read a bundle identifier from that item.")
            return
        }
        resolveBundleIdOverride = id
        refreshFrontmostApp()
        updateStatus()
        presentInfo(
            title: "Resolve selected",
            text:
                "ResolveZoom will now act on \(url.lastPathComponent)\n\nBundle identifier:\n\(id)")
    }

    @objc func clearResolveAppOverride() {
        resolveBundleIdOverride = ""
        updateStatus()
    }

    private func presentInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.runModal()
    }

    func refreshFrontmostApp() {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        // Ignore ourselves. Opening our own menu or Preferences window makes this app
        // frontmost, which would otherwise clear the cached Resolve state and make the
        // menu permanently read "Waiting for Resolve…" even while Resolve is in use.
        if id == Bundle.main.bundleIdentifier { return }
        cachedFrontmostBundleId = id
    }

    // MARK: - Accessibility
    func checkAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            setupEventTap()
            startFusionPolling()
            updateStatus()
            startPermissionWatchdog()
        } else {
            // Tear down any running timer before scheduling a new one. Previously the
            // 2 s watchdog stayed scheduled while this method overwrote `permissionTimer`
            // with a fresh 1 s timer — so the watchdog kept firing, kept re-entering
            // here, and spawned another NSWindow plus another timer every 2 seconds for
            // as long as the permission was missing.
            permissionTimer?.invalidate()
            permissionTimer = nil

            // Register app in accessibility list without showing system dialog
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
            AXIsProcessTrustedWithOptions(options as CFDictionary)

            showPermissionsWindow()

            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if self.permissionTimer === timer { self.permissionTimer = nil }
                        self.closePermissionsWindow()
                        self.setupEventTap()
                        self.updateStatus()
                        self.startPermissionWatchdog()
                    }
                }
            }
        }
    }

    /// Continuously monitors whether permissions have been revoked while the app is running.
    func startPermissionWatchdog() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if !AXIsProcessTrusted() {
                // Stop this watchdog before handing control back to
                // checkAccessibilityAndStart(), otherwise both timers stay alive.
                timer.invalidate()
                if self.permissionTimer === timer { self.permissionTimer = nil }
                DispatchQueue.main.async {
                    self.disableEventTap()
                    self.updateStatus()
                    self.checkAccessibilityAndStart()
                }
            }
        }
    }

    /// Safely removes the event tap from the run loop and releases it.
    /// MUST be called before permissions are considered lost — prevents mouse click blocking.
    func disableEventTap() {
        stopFusionPolling()
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Without invalidating the mach port, the port and its run-loop source
            // stay alive after we drop our reference to them.
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            // The source was added to the main run loop, so it has to be removed from
            // the main run loop — CFRunLoopGetCurrent() would be the wrong loop if this
            // is ever called off the main thread.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    func closePermissionsWindow() {
        let w = permissionsWindow
        permissionsWindow = nil
        w?.orderOut(nil)
        w?.close()
    }

    func showPermissionsWindow() {
        // Reuse the existing window instead of stacking up new ones. The window is
        // created with `isReleasedWhenClosed = false`, so every extra instance stayed
        // retained for the lifetime of the app.
        if let existing = permissionsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "ResolveZoom"
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .floating

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 190))

        let icon = NSImageView(frame: NSRect(x: 24, y: 120, width: 44, height: 44))
        icon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        cv.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: "Accessibility permission required")
        titleLabel.frame = NSRect(x: 82, y: 146, width: 340, height: 20)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        cv.addSubview(titleLabel)

        let desc = NSTextField(
            wrappingLabelWithString:
                "ResolveZoom needs Accessibility access to detect pinch gestures. Click the button below, then find ResolveZoom in the list and toggle the switch ON."
        )
        desc.frame = NSRect(x: 82, y: 82, width: 340, height: 60)
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        cv.addSubview(desc)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitBtn.frame = NSRect(x: 24, y: 24, width: 80, height: 32)
        quitBtn.bezelStyle = .rounded
        cv.addSubview(quitBtn)

        let openBtn = NSButton(
            title: "Open Accessibility Settings", target: self,
            action: #selector(openAccessibilitySettings))
        openBtn.frame = NSRect(x: 220, y: 24, width: 200, height: 32)
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "\r"
        cv.addSubview(openBtn)

        w.contentView = cv
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionsWindow = w
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Event Tap
    func setupEventTap() {
        disableEventTap()  // clean up any previous tap first

        // `passUnretained`, not `passRetained`: this delegate lives for the whole app
        // lifetime, and a retained pointer here leaked one AppDelegate every time the
        // tap was rebuilt.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // MEMORY MANAGEMENT CONTRACT of CGEventTapCallBack:
        //
        // The `event` argument is owned by the system. When we pass it through
        // unchanged we must return an *unretained* reference. Returning
        // `Unmanaged.passRetained(event)` adds a +1 retain that nothing ever balances,
        // so every scroll and magnify event flowing through the tap was leaked. Under
        // sustained trackpad use that is thousands of leaked CGEvents per minute — the
        // cause of the unbounded memory growth reported by users (22 MB → 60 MB → GBs
        // over a long editing session).
        //
        // Only return `passRetained` for an event *we* created and are handing
        // ownership of to the system.
        let callback: CGEventTapCallBack = { proxy, type, event, userInfoPtr in
            // Drain autoreleased temporaries immediately instead of letting them pile
            // up until the next run-loop turn. This callback fires 60–120 times a
            // second during a pinch.
            return autoreleasepool { () -> Unmanaged<CGEvent>? in
                guard let ptr = userInfoPtr else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()

                // Handle tap being disabled (e.g. accessibility permission revoked)
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    DispatchQueue.main.async {
                        if AXIsProcessTrusted(), let tap = delegate.tap {
                            // Permission still valid — just re-enable the tap
                            CGEvent.tapEnable(tap: tap, enable: true)
                        } else {
                            // Permission lost — remove tap to unblock mouse events
                            delegate.disableEventTap()
                            delegate.updateStatus()
                            delegate.checkAccessibilityAndStart()
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                let kMagnify = CGEventType(rawValue: 29)!
                let kField = CGEventField(rawValue: 113)!

                // Detect horizontal scroll from mouse side wheel — record timestamp and pass through
                if type == CGEventType.scrollWheel {
                    let deltaH1 = event.getDoubleValueField(CGEventField(rawValue: 12)!)  // discrete axis2
                    let deltaH2 = event.getDoubleValueField(CGEventField(rawValue: 97)!)  // precise axis2
                    if abs(deltaH1) > 0 || abs(deltaH2) > 0 {
                        delegate.lastHorizontalScrollTime = CFAbsoluteTimeGetCurrent()
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == kMagnify else { return Unmanaged.passUnretained(event) }

                delegate.magnifyEventsSeen += 1

                // If horizontal scroll happened within last 100ms, this magnify is a mouse artifact
                if CFAbsoluteTimeGetCurrent() - delegate.lastHorizontalScrollTime < 0.1 {
                    delegate.lastSkipReason = "horizontal scroll artifact"
                    return Unmanaged.passUnretained(event)
                }
                // Cached — refreshed on didActivateApplicationNotification.
                guard delegate.isResolveApp(delegate.cachedFrontmostBundleId) else {
                    delegate.lastSkipReason =
                        "not Resolve (\(delegate.cachedFrontmostBundleId ?? "unknown"))"
                    return Unmanaged.passUnretained(event)
                }

                // Fusion handles pinch-to-zoom natively. Pass the original event through
                // rather than injecting an Alt-scroll event intended for the timeline.
                if delegate.isPausedForFusion {
                    delegate.lastSkipReason = "Fusion page (native pinch zoom)"
                    delegate.zoomAccumulator = 0
                    delegate.consecutiveMagnifyCount = 0
                    return Unmanaged.passUnretained(event)
                }

                // Never interfere while a mouse button is held: the user is dragging —
                // e.g. pulling a clip into the timeline — and a stray pinch would make us
                // inject Option-flagged scroll events into an active drag, which Resolve
                // reinterprets as a modified drag. Reported as clips stretching/folding
                // and the cursor jumping around.
                if CGEventSource.buttonState(.combinedSessionState, button: .left)
                    || CGEventSource.buttonState(.combinedSessionState, button: .right)
                {
                    delegate.lastSkipReason = "mouse button held (drag in progress)"
                    // Drop any partial gesture state so the drag can't seed the next zoom.
                    delegate.zoomAccumulator = 0
                    delegate.consecutiveMagnifyCount = 0
                    return Unmanaged.passUnretained(event)
                }

                let mag = event.getDoubleValueField(kField)
                delegate.lastMagnifyMagnitude = mag
                guard abs(mag) < 0.5 && abs(mag) > 0.005 else {
                    delegate.lastSkipReason = "magnitude out of range"
                    return Unmanaged.passUnretained(event)
                }

                // Consecutive event counter: require sustained stream of events (real pinch)
                // before triggering zoom — clicks generate only 1-2 events
                let now = CFAbsoluteTimeGetCurrent()
                // Captured *before* lastMagnifyTime is overwritten. Previously the
                // quick-flip check below compared `now` against a value that had just
                // been set to `now`, so the elapsed time was always 0 and the check was
                // dead code.
                let timeSinceLastMagnify = now - delegate.lastMagnifyTime

                if timeSinceLastMagnify > delegate.magnifyTimeWindow {
                    delegate.consecutiveMagnifyCount = 0
                    delegate.zoomAccumulator = 0
                }
                delegate.consecutiveMagnifyCount += 1
                delegate.lastMagnifyTime = now
                guard delegate.consecutiveMagnifyCount >= delegate.magnifyCountThreshold else {
                    return Unmanaged.passUnretained(event)
                }

                // Filter scroll artifacts: real pinch gestures don't flip direction within 100ms
                let currentSign = mag > 0 ? 1.0 : -1.0
                let isSignFlip =
                    currentSign != delegate.lastMagnifySign && delegate.lastMagnifySign != 0
                let isQuickFlip = timeSinceLastMagnify < 0.1
                delegate.lastMagnifySign = currentSign
                if isSignFlip && isQuickFlip {
                    // Drop the stale remainder so it can't leak into the new direction.
                    delegate.zoomAccumulator = 0
                    return Unmanaged.passUnretained(event)
                }

                let direction: Double = delegate.invertZoom ? 1.0 : -1.0

                // Accumulate in floating point and only emit whole pixels, carrying the
                // remainder forward. A bare Int32(delta) truncated anything below 1.0 to
                // zero, so slow pinches at low sensitivity dropped out entirely.
                delegate.zoomAccumulator += mag * direction * delegate.multiplier
                // Defensive clamp — Int32() traps on out-of-range values.
                delegate.zoomAccumulator = max(-100_000, min(100_000, delegate.zoomAccumulator))
                let intDelta = Int32(delegate.zoomAccumulator)
                guard intDelta != 0 else { return Unmanaged.passUnretained(event) }
                delegate.zoomAccumulator -= Double(intDelta)

                // Bierzemy pozycję kursora wprost z eventu magnify — już jest w układzie CGEvent,
                // działa poprawnie na wszystkich monitorach bez ręcznej konwersji współrzędnych
                let cgPoint = event.location

                guard
                    let scrollEvent = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel,
                        wheelCount: 1, wheel1: intDelta, wheel2: 0, wheel3: 0
                    )
                else { return Unmanaged.passUnretained(event) }

                scrollEvent.flags = .maskAlternate
                scrollEvent.location = cgPoint
                scrollEvent.post(tap: .cghidEventTap)
                delegate.magnifyEventsActedOn += 1
                delegate.lastSkipReason = "—"
                // Swallow the original magnify event. `scrollEvent` is ARC-managed and
                // released when this closure returns — posting already handed a copy to
                // the system.
                return nil
            }
        }

        let mask: CGEventMask = (1 << 29) | (1 << 22)  // magnify + scroll wheel
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        )
        guard let tap = tap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Fusion page detection

    /// Starts a lightweight main-queue timer. The timer only captures the current
    /// PID; all Accessibility IPC happens on `fusionPollQueue`.
    private func startFusionPolling() {
        stopFusionPolling()
        fusionPollingGeneration += 1
        scheduleFusionPagePoll()

        // Use a dispatch timer instead of a run-loop Timer. The latter can stop
        // firing while the app is in another run-loop mode (desktop/focus changes,
        // tracking, or menu interaction). This timer only schedules work; AX IPC
        // still runs exclusively on fusionPollQueue.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + fusionPollInterval,
            repeating: fusionPollInterval,
            leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.scheduleFusionPagePoll()
        }
        timer.resume()
        fusionPollTimer = timer
    }

    private func stopFusionPolling() {
        fusionPollTimer?.cancel()
        fusionPollTimer = nil
        fusionPollingGeneration += 1
        activeFusionScanID = nil
    }

    /// This function runs on the main queue. It does not call AX APIs, preventing
    /// Resolve from ever delaying the event tap or menu/UI work.
    private func scheduleFusionPagePoll() {
        precondition(Thread.isMainThread)
        guard activeFusionScanID == nil, AXIsProcessTrusted() else { return }
        guard
            let resolve = NSWorkspace.shared.runningApplications.first(where: {
                $0.isActive && isResolveApp($0.bundleIdentifier)
            })
        else { return }

        let scanID = UUID()
        let generation = fusionPollingGeneration
        let pid = resolve.processIdentifier
        let timeout = axMessagingTimeout
        activeFusionScanID = scanID

        fusionPollQueue.async { [weak self] in
            let result = AppDelegate.scanActiveResolvePage(pid: pid, timeout: timeout)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.activeFusionScanID == scanID else { return }
                self.activeFusionScanID = nil
                guard self.fusionPollingGeneration == generation else { return }
                self.applyFusionPageScanResult(result)
            }
        }
    }

    /// Applies results only after a confirmed page change. A missing element or a
    /// timed-out AX request leaves the last known page untouched, which is safer than
    /// accidentally re-enabling interception while Resolve is loading Fusion.
    private func applyFusionPageScanResult(_ result: FusionPageScanResult) {
        precondition(Thread.isMainThread)
        guard case .page(let page) = result, page != activeResolvePage else { return }

        activeResolvePage = page
        let shouldPause = page.caseInsensitiveCompare("Fusion") == .orderedSame
        guard shouldPause != isPausedForFusion else { return }

        isPausedForFusion = shouldPause
        zoomAccumulator = 0
        consecutiveMagnifyCount = 0
    }

    private enum FusionPageScanResult {
        case page(String)
        case noActivePage
        case unavailable
    }

    private enum AXAttributeValue {
        case value(CFTypeRef)
        case missing
        case unavailable
    }

    /// Performs a bounded scan of Resolve's current AX tree. This function is called
    /// only from `fusionPollQueue`; no AXUIElement references are retained or shared.
    private static func scanActiveResolvePage(
        pid: pid_t, timeout: Float
    ) -> FusionPageScanResult {
        // The per-message timeout protects each synchronous IPC call. The additional
        // budget caps the entire recursive pass, so a large AX tree cannot monopolize
        // even the utility queue when Resolve is slow.
        let deadline = Date().addingTimeInterval(0.25)
        let application = AXUIElementCreateApplication(pid)
        guard setMessagingTimeout(application, timeout: timeout) else { return .unavailable }

        let mainWindow: AXUIElement
        switch copyAttribute(
            kAXMainWindowAttribute as CFString, from: application, timeout: timeout,
            deadline: deadline)
        {
        case .value(let value) where CFGetTypeID(value) == AXUIElementGetTypeID():
            mainWindow = value as! AXUIElement
        case .missing:
            switch copyAttribute(
                kAXFocusedWindowAttribute as CFString, from: application, timeout: timeout,
                deadline: deadline)
            {
            case .value(let value) where CFGetTypeID(value) == AXUIElementGetTypeID():
                mainWindow = value as! AXUIElement
            default:
                return .unavailable
            }
        default:
            return .unavailable
        }

        return scanForActivePage(
            in: mainWindow, depth: 0, maxDepth: 10, timeout: timeout, deadline: deadline)
    }

    private static func scanForActivePage(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        timeout: Float,
        deadline: Date
    ) -> FusionPageScanResult {
        guard depth <= maxDepth, Date() <= deadline else { return .unavailable }

        switch copyAttribute(
            kAXRoleAttribute as CFString, from: element, timeout: timeout, deadline: deadline)
        {
        case .value(let value) where (value as? String) == "AXCheckBox":
            let pageName: String
            switch copyAttribute(
                kAXTitleAttribute as CFString, from: element, timeout: timeout, deadline: deadline)
            {
            case .value(let value) where !(value as? String ?? "").isEmpty:
                pageName = value as! String
            case .missing, .value(_):
                switch copyAttribute(
                    kAXDescriptionAttribute as CFString, from: element, timeout: timeout,
                    deadline: deadline)
                {
                case .value(let value) where !(value as? String ?? "").isEmpty:
                    pageName = value as! String
                case .unavailable:
                    return .unavailable
                default:
                    pageName = ""
                }
            case .unavailable:
                return .unavailable
            }

            if Self.resolvePageNames.contains(pageName) {
                switch copyAttribute(
                    kAXValueAttribute as CFString, from: element, timeout: timeout,
                    deadline: deadline)
                {
                case .value(let value) where isSelectedPageValue(value):
                    return .page(pageName)
                case .unavailable:
                    return .unavailable
                default:
                    break
                }
            }
        case .unavailable:
            return .unavailable
        default:
            break
        }

        switch copyAttribute(
            kAXChildrenAttribute as CFString, from: element, timeout: timeout, deadline: deadline)
        {
        case .value(let value) where CFGetTypeID(value) == CFArrayGetTypeID():
            let children = value as! [AXUIElement]
            for child in children {
                let result = scanForActivePage(
                    in: child, depth: depth + 1, maxDepth: maxDepth,
                    timeout: timeout, deadline: deadline)
                switch result {
                case .page, .unavailable:
                    return result
                case .noActivePage:
                    continue
                }
            }
        case .unavailable:
            return .unavailable
        default:
            break
        }

        return .noActivePage
    }

    private static func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        timeout: Float,
        deadline: Date
    ) -> AXAttributeValue {
        guard Date() <= deadline, setMessagingTimeout(element, timeout: timeout) else {
            return .unavailable
        }

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch error {
        case .success:
            return value.map(AXAttributeValue.value) ?? .missing
        case .noValue, .attributeUnsupported:
            return .missing
        default:
            return .unavailable
        }
    }

    private static func setMessagingTimeout(_ element: AXUIElement, timeout: Float) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout) == .success
    }

    private static func isSelectedPageValue(_ value: CFTypeRef) -> Bool {
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.intValue == 1 }
        return false
    }

    // MARK: - Menu Bar
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let btn = statusItem.button {
            let img = NSImage(
                systemSymbolName: "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: "ResolveZoom")
            img?.isTemplate = true
            btn.image = img
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem()
        let titleStr = NSMutableAttributedString(
            string: "ResolveZoom\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        // Read from the bundle so the menu can never drift out of sync with Info.plist.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        titleStr.append(
            NSAttributedString(
                string: "Version: \(appVersion)  ·  © Marcin Kuśnierz",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        titleItem.attributedTitle = titleStr
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        statusMenuItem = NSMenuItem(title: "Checking permissions…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Diagnostics line. Refreshed in menuWillOpen, so a user who reports "nothing
        // happens" can read off exactly what the app sees instead of us guessing.
        diagnosticsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        diagnosticsMenuItem.isEnabled = false
        menu.addItem(diagnosticsMenuItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(prefsItem)

        selectResolveMenuItem = NSMenuItem(
            title: "Select DaVinci Resolve…",
            action: #selector(selectResolveApp), keyEquivalent: "")
        menu.addItem(selectResolveMenuItem)

        clearResolveMenuItem = NSMenuItem(
            title: "Use automatic detection",
            action: #selector(clearResolveAppOverride), keyEquivalent: "")
        menu.addItem(clearResolveMenuItem)

        menu.addItem(.separator())

        menu.addItem(
            NSMenuItem(title: "Quit ResolveZoom", action: #selector(quit), keyEquivalent: "q"))

        menu.delegate = self
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    // MARK: - Preferences Window
    @objc func openPreferences() {
        if let win = preferencesWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView(
            multiplier: multiplier,
            invertZoom: invertZoom,
            launchAtLogin: isAutolaunchEnabled(),
            onSave: { [weak self] mult, invert, login in
                guard let self = self else { return }
                self.multiplier = mult
                self.invertZoom = invert
                self.setAutolaunch(login)
                self.preferencesWindow?.close()
            },
            onCancel: { [weak self] in
                self?.preferencesWindow?.close()
            }
        )

        let controller = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: controller)
        w.title = "Preferences"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = w
    }

    // MARK: - Status
    @objc func activeAppChanged() {
        DispatchQueue.main.async {
            // Keep the cached bundle id in sync so the tap callback never has to ask.
            self.refreshFrontmostApp()
            self.scheduleFusionPagePoll()
            self.updateStatus()
        }
    }

    /// Refresh right before the menu is drawn. Previously the status was only recomputed
    /// on app-activation notifications, so whatever it happened to say could be stale by
    /// the time the user actually looked at it.
    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
        updateDiagnostics()
        clearResolveMenuItem?.isHidden = resolveBundleIdOverride.isEmpty
    }

    func updateStatus() {
        guard let item = statusMenuItem else { return }
        let (text, color): (String, NSColor) = {
            if !AXIsProcessTrusted() {
                return ("⬤  No accessibility permission", .systemRed)
            }
            // Uses the cached id, which deliberately ignores this app itself — opening
            // this very menu would otherwise make us the frontmost app and the line
            // would always read "Waiting for Resolve…".
            return isResolveApp(cachedFrontmostBundleId)
                ? ("⬤  DaVinci Resolve active", .systemGreen)
                : ("⬤  Waiting for Resolve…", .secondaryLabelColor)
        }()
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 13),
            ])
    }

    func updateDiagnostics() {
        guard let item = diagnosticsMenuItem else { return }
        let seenApp = cachedFrontmostBundleId ?? "unknown"
        let matching =
            resolveBundleIdOverride.isEmpty
            ? "auto (com.blackmagic-design.DaVinciResolve*)"
            : resolveBundleIdOverride
        let lines = """
            Frontmost app: \(seenApp)
            Matching: \(matching)
            Pinch events: \(magnifyEventsSeen) seen · \(magnifyEventsActedOn) used
            Last magnitude: \(String(format: "%.4f", lastMagnifyMagnitude))
            Last skip: \(lastSkipReason)
            """
        item.attributedTitle = NSAttributedString(
            string: lines,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    // MARK: - Actions
    @objc func sliderChanged(_ sender: NSSlider) {
        multiplier = sender.doubleValue
        preferencesWindow?.contentView?.viewWithTag(2).flatMap { $0 as? NSTextField }?.stringValue =
            "\(Int(multiplier))"
    }

    @objc func resetToDefault(_ sender: Any) {
        multiplier = defaultMultiplier
        preferencesWindow?.contentView?.viewWithTag(1).flatMap { $0 as? NSSlider }?.doubleValue =
            defaultMultiplier
        preferencesWindow?.contentView?.viewWithTag(2).flatMap { $0 as? NSTextField }?.stringValue =
            "\(Int(defaultMultiplier))"
    }

    @objc func invertChanged(_ sender: NSButton) {
        invertZoom = (sender.state == .on)
    }

    @objc func toggleAutolaunch(_ sender: NSMenuItem) {
        let enable = sender.state == .off
        setAutolaunch(enable)
        sender.state = enable ? .on : .off
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - Autostart
    func isAutolaunchEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL().path)
    }

    func setAutolaunch(_ enable: Bool) {
        let url = launchAgentURL()
        if enable {
            let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
            let plist: [String: Any] = [
                "Label": "com.resolvezoom.app",
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func launchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.resolvezoom.app.plist")
    }
}
