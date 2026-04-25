import Cocoa
import SwiftUI

struct PreferencesView: View {
    @State private var multiplier: Double
    @State private var invertZoom: Bool
    @State private var launchAtLogin: Bool

    let onSave: (Double, Bool, Bool) -> Void
    let onCancel: () -> Void

    private let defaultMultiplier = 800.0

    init(multiplier: Double, invertZoom: Bool, launchAtLogin: Bool,
         onSave: @escaping (Double, Bool, Bool) -> Void,
         onCancel: @escaping () -> Void) {
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
                .background(RoundedRectangle(cornerRadius: 10)
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

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var permissionTimer: Timer?

    var statusMenuItem: NSMenuItem!
    var permissionsWindow: NSWindow?
    var preferencesWindow: NSWindow?

    let defaults = UserDefaults.standard

    let defaultMultiplier: Double = 800.0
    let sliderMin: Double = 100.0
    let sliderMax: Double = 1500.0

    var multiplier: Double {
        get { defaults.object(forKey: "multiplier") == nil ? defaultMultiplier : defaults.double(forKey: "multiplier") }
        set { defaults.set(newValue, forKey: "multiplier") }
    }

    var invertZoom: Bool {
        get { defaults.bool(forKey: "invertZoom") }
        set { defaults.set(newValue, forKey: "invertZoom") }
    }

    // Scroll-artifact detection
    var lastMagnifyTime: Double = 0
    var lastMagnifySign: Double = 0
    var lastHorizontalScrollTime: Double = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        checkAccessibilityAndStart()
    }

    // MARK: - Accessibility
    func checkAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            setupEventTap()
            updateStatus()
            startPermissionWatchdog()
        } else {
            // Register app in accessibility list without showing system dialog
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
            AXIsProcessTrustedWithOptions(options as CFDictionary)

            showPermissionsWindow()

            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    DispatchQueue.main.async {
                        self?.permissionsWindow?.close()
                        self?.permissionsWindow = nil
                        self?.setupEventTap()
                        self?.updateStatus()
                        self?.startPermissionWatchdog()
                    }
                }
            }
        }
    }

    /// Continuously monitors whether permissions have been revoked while the app is running.
    func startPermissionWatchdog() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !AXIsProcessTrusted() {
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
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    func showPermissionsWindow() {
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

        let desc = NSTextField(wrappingLabelWithString: "ResolveZoom needs Accessibility access to detect pinch gestures. Click the button below, then find ResolveZoom in the list and toggle the switch ON.")
        desc.frame = NSRect(x: 82, y: 82, width: 340, height: 60)
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        cv.addSubview(desc)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitBtn.frame = NSRect(x: 24, y: 24, width: 80, height: 32)
        quitBtn.bezelStyle = .rounded
        cv.addSubview(quitBtn)

        let openBtn = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Event Tap
    func setupEventTap() {
        disableEventTap() // clean up any previous tap first

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let callback: CGEventTapCallBack = { proxy, type, event, userInfoPtr in
            guard let ptr = userInfoPtr else { return Unmanaged.passRetained(event) }
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
                return Unmanaged.passRetained(event)
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
                return Unmanaged.passRetained(event)
            }

            guard type == kMagnify else { return Unmanaged.passRetained(event) }

            // If horizontal scroll happened within last 100ms, this magnify is a mouse artifact
            if CFAbsoluteTimeGetCurrent() - delegate.lastHorizontalScrollTime < 0.1 {
                return Unmanaged.passRetained(event)
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == "com.blackmagic-design.DaVinciResolve" else {
                return Unmanaged.passRetained(event)
            }

            let mag = event.getDoubleValueField(kField)
            guard abs(mag) < 0.5 && abs(mag) > 0.005 else {
                return Unmanaged.passRetained(event)
            }

            // Filter scroll artifacts: real pinch gestures don't flip direction within 100ms
            let now = CFAbsoluteTimeGetCurrent()
            let currentSign = mag > 0 ? 1.0 : -1.0
            let isSignFlip = currentSign != delegate.lastMagnifySign && delegate.lastMagnifySign != 0
            let isQuickFlip = (now - delegate.lastMagnifyTime) < 0.1
            delegate.lastMagnifyTime = now
            delegate.lastMagnifySign = currentSign
            if isSignFlip && isQuickFlip {
                return Unmanaged.passRetained(event)
            }

            let direction: Double = delegate.invertZoom ? 1.0 : -1.0
            let delta = mag * direction * delegate.multiplier

            // Bierzemy pozycję kursora wprost z eventu magnify — już jest w układzie CGEvent,
            // działa poprawnie na wszystkich monitorach bez ręcznej konwersji współrzędnych
            let cgPoint = event.location

            guard let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0
            ) else { return Unmanaged.passRetained(event) }

            scrollEvent.flags = .maskAlternate
            scrollEvent.location = cgPoint
            scrollEvent.post(tap: .cghidEventTap)
            return nil
        }

        let mask: CGEventMask = (1 << 29) | (1 << 22) // magnify + scroll wheel
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Menu Bar
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                              accessibilityDescription: "ResolveZoom")
            img?.isTemplate = true
            btn.image = img
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem()
        let titleStr = NSMutableAttributedString(string: "ResolveZoom\n",
                                                 attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        titleStr.append(NSAttributedString(string: "Version: 0.2  ·  © Marcin Kuśnierz",
                                           attributes: [
                                               .font: NSFont.systemFont(ofSize: 10),
                                               .foregroundColor: NSColor.secondaryLabelColor
                                           ]))
        titleItem.attributedTitle = titleStr
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        statusMenuItem = NSMenuItem(title: "Checking permissions…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit ResolveZoom", action: #selector(quit), keyEquivalent: "q"))

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
        DispatchQueue.main.async { self.updateStatus() }
    }

    func updateStatus() {
        guard let item = statusMenuItem else { return }
        let (text, color): (String, NSColor) = {
            if !AXIsProcessTrusted() {
                return ("⬤  No accessibility permission", .systemRed)
            }
            let isResolve = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == "com.blackmagic-design.DaVinciResolve"
            return isResolve
                ? ("⬤  DaVinci Resolve active", .systemGreen)
                : ("⬤  Waiting for Resolve…", .secondaryLabelColor)
        }()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13)
        ])
    }

    // MARK: - Actions
    @objc func sliderChanged(_ sender: NSSlider) {
        multiplier = sender.doubleValue
        preferencesWindow?.contentView?.viewWithTag(2).flatMap { $0 as? NSTextField }?.stringValue = "\(Int(multiplier))"
    }

    @objc func resetToDefault(_ sender: Any) {
        multiplier = defaultMultiplier
        preferencesWindow?.contentView?.viewWithTag(1).flatMap { $0 as? NSSlider }?.doubleValue = defaultMultiplier
        preferencesWindow?.contentView?.viewWithTag(2).flatMap { $0 as? NSTextField }?.stringValue = "\(Int(defaultMultiplier))"
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
                "KeepAlive": false
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
