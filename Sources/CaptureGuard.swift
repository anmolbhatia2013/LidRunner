import AppKit
import ApplicationServices
import CoreGraphics

@main struct CaptureGuardMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = CaptureGuard(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run()
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
private func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
private func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

// Only read window chrome, never document contents or text fields. macOS adds this
// menu button while an app window is being controlled through Window Sharing.
private func isShared(_ window: AXUIElement) -> Bool {
    for child in children(window) {
        let role = attribute(child, kAXRoleAttribute) as? String
        let chrome = role == kAXToolbarRole ? children(child) : [child]
        for item in chrome {
            if sharingChromeMatches(title: attribute(item, kAXTitleAttribute) as? String,
                                    description: attribute(item, kAXDescriptionAttribute) as? String) { return true }
        }
    }
    return false
}

private struct TrackedWindow {
    var lastFrame: CGRect
    var stableSince: Double
    var handled = false
    var attempts = 0
    var nextAttempt: Double = 0
}

final class CaptureGuard: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var statusItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var timer: Timer?
    private var setupWindow: NSWindow?
    private var scanning = false
    private let queue = DispatchQueue(label: "LidRunner.CaptureGuard")
    private var records: [String: TrackedWindow] = [:] // worker queue only
    private var previousDisplaySignature = ""
    private var previousActive = false
    private var repairs = 0
    private var lastRepair: [String: Any]?
    private let statusURL = userDir.appendingPathComponent("capture-guard.json")
    private var enabled: Bool { !UserDefaults.standard.bool(forKey: "paused") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "LidRunner Capture Guard")
        let menu = NSMenu()
        statusItem = menu.addItem(withTitle: "Checking…", action: nil, keyEquivalent: "")
        enabledItem = menu.addItem(withTitle: "Automatic screenshot recovery", action: #selector(toggle), keyEquivalent: "")
        enabledItem.state = enabled ? .on : .off
        menu.addItem(withTitle: "Show setup", action: #selector(showSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Allow window positioning…", action: #selector(requestPermission), keyEquivalent: "")
        menu.addItem(withTitle: "Open recovery diagnostics", action: #selector(openDiagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Capture Guard", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }; item.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        if !AXIsProcessTrusted() { showSetup() }
    }
    @objc private func showSetup() {
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 235), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "LidRunner Capture Guard"; w.isReleasedWhenClosed = false
            let text = NSTextField(wrappingLabelWithString: "Automatic screenshot recovery\n\nAllows this helper to re-center windows being controlled remotely while a closed-lid LidRunner session is active. macOS requires Accessibility permission to move windows.\n\nEnable LidRunner Capture Guard in Accessibility / Device Control and Data Access settings.")
            text.frame = NSRect(x:24,y:72,width:462,height:140)
            w.contentView?.addSubview(text)
            let button = NSButton(title: "Open Accessibility Settings", target:self, action:#selector(requestPermission))
            button.bezelStyle = .rounded; button.frame = NSRect(x:24,y:22,width:250,height:34)
            w.contentView?.addSubview(button)
            w.center(); setupWindow = w
        }
        setupWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    @objc private func toggle() {
        UserDefaults.standard.set(enabled, forKey: "paused")
        enabledItem.state = enabled ? .on : .off
        tick()
    }
    @objc private func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openDiagnostics() { NSWorkspace.shared.open(statusURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func tick() {
        guard !scanning else { return }; scanning = true
        let now = Date().timeIntervalSince1970
        let closed = rootProperty("AppleClamshellState") == true
        let session = readJSON(CaptureSession.self, userDir.appendingPathComponent("diagnostics.json").path)
        let active = captureRecoveryAllowed(session, now: now, lidClosed: closed, enabled: enabled)
        let trusted = AXIsProcessTrusted()
        // AX and CG use top-left global coordinates; AppKit uses bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.map { s -> CGRect in
            let r = s.visibleFrame
            return CGRect(x: r.minX, y: primaryTop-r.maxY, width: r.width, height: r.height)
        }
        let signature = screens.map { NSStringFromRect($0) }.joined(separator: ";")
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !$0.isHidden &&
            !agentBundleIDs.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }.map { ($0.processIdentifier, $0.bundleIdentifier ?? "unknown") }
        queue.async { [self] in
            let report = scan(active: active, trusted: trusted, now: now, screens: screens, signature: signature, apps: apps)
            var state = report
            state["time"] = Date().timeIntervalSince1970
            state["lidClosed"] = closed
            state["accessibilityTrusted"] = trusted
            state["sessionEligible"] = active
            state["repairs"] = repairs
            if let lastRepair { state["lastRepair"] = lastRepair }
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: statusURL, options: .atomic)
            }
            let label = state["status"] as? String ?? "Unknown"
            DispatchQueue.main.async { [self] in statusItem.title = label; scanning = false }
        }
    }
    private func scan(active: Bool, trusted: Bool, now: Double, screens: [CGRect], signature: String,
                      apps: [(pid_t, String)]) -> [String: Any] {
        if !active || !trusted {
            records.removeAll(); previousActive = false
            return ["status": trusted ? "Waiting for a closed-lid LidRunner session" : "Accessibility permission needed"]
        }
        if !previousActive || signature != previousDisplaySignature { records.removeAll() }
        previousActive = true; previousDisplaySignature = signature
        // Restrict scans to normal, on-screen app windows. No screen-recording access is requested.
        let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visiblePIDs = Set(cgWindows.compactMap { w -> pid_t? in
            guard w[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        })
        var seen = Set<String>(), shared = 0, normal = 0
        var failures: [String] = []
        for (pid, bundle) in apps where visiblePIDs.contains(pid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows.prefix(32) {
                guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      attribute(window, kAXMinimizedAttribute) as? Bool != true,
                      attribute(window, "AXFullScreen") as? Bool != true else { continue }
                normal += 1
                guard isShared(window), let before = frame(window) else { continue }
                shared += 1
                let key = "\(pid):\(CFHash(window))"
                seen.insert(key)
                var record = records[key] ?? TrackedWindow(lastFrame: before, stableSince: now)
                if !framesNear(record.lastFrame, before) {
                    // Window sharing and sidebar changes can replace the capture surface.
                    record.lastFrame = before; record.stableSince = now; record.handled = false
                }
                guard !record.handled, now-record.stableSince >= 1, now >= record.nextAttempt else {
                    records[key] = record; continue
                }
                // Limit retries so an app refusing movement cannot cause a constant loop.
                if record.attempts >= 3 {
                    if now-record.nextAttempt < 60 { records[key] = record; continue }
                    record.attempts = 0
                }
                guard var origin = centeredOrigin(window: before, screens: screens) else { continue }
                // AX calls can stall. Recheck the session immediately before a mutation.
                guard captureRecoveryAllowed(readJSON(CaptureSession.self, userDir.appendingPathComponent("diagnostics.json").path),
                                             now: Date().timeIntervalSince1970,
                                             lidClosed: rootProperty("AppleClamshellState") == true,
                                             enabled: !UserDefaults.standard.bool(forKey: "paused")) else { continue }
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success, settable.boolValue,
                      let value = AXValueCreate(.cgPoint, &origin) else {
                    failures.append("\(bundle): position unavailable"); records[key] = record; continue
                }
                record.attempts += 1; record.nextAttempt = now + 5
                let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
                if result == .success, let after = frame(window), abs(after.minX-origin.x) <= 2, abs(after.minY-origin.y) <= 2 {
                    record.lastFrame = after; record.handled = true
                    record.attempts = 0; record.nextAttempt = 0
                    repairs += 1
                    lastRepair = ["time": now, "bundle": bundle, "pid": pid, "before": NSStringFromRect(before), "after": NSStringFromRect(after), "verification": "position readback; screenshot must be checked separately"]
                } else { failures.append("\(bundle): position result \(result.rawValue)") }
                records[key] = record
            }
        }
        records = records.filter { seen.contains($0.key) }
        return ["status": shared > 0 ? "Watching \(shared) shared window(s)" : "Ready for remote app control", "sharedWindows": shared, "normalWindowsScanned": normal, "failures": failures, "displayFrames": screens.map { NSStringFromRect($0) }]
    }
}
