import AppKit
import Carbon
import ServiceManagement
import Network
import IOKit.pwr_mgt
import CoreGraphics
import UserNotifications

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory); app.run()
    }
}
// Per-app keep-alive state. Reset when the session ends so a later session starts clean.
final class AgentKeeper {
    let app: AgentApp
    var installedURL: URL?
    var missingSince: Double?
    var lastLaunch: Double?
    var attempts = 0
    var launching = false
    var launchError: String?
    var seenThisSession = false
    var running = false
    init(_ app: AgentApp) { self.app = app; installedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) }
    var enabled: Bool { UserDefaults.standard.bool(forKey: app.defaultsKey) }
    func reset() { missingSince = nil; lastLaunch = nil; attempts = 0; launchError = nil }
}
/// Writes the heartbeat on its own queue. The main thread reports in through `update`; an open
/// menu, a modal picker or a slow system call no longer makes the helper think LidRunner died.
final class HeartbeatWriter {
    private let queue = DispatchQueue(label: "LidRunner.heartbeat", qos: .userInitiated)
    private let path: String
    private var timer: DispatchSourceTimer?
    private var token: String?            // queue only
    private var stop = false              // queue only
    private var lastMainTick = 0.0        // queue only
    init(path: String) { self.path = path }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.write(now: Date().timeIntervalSince1970) }
        timer.resume(); self.timer = timer
    }
    /// Main thread: record the current session (nil = none) and write immediately.
    func update(token: String?, stop: Bool) {
        let now = Date().timeIntervalSince1970
        queue.sync { self.token = token; self.stop = stop; self.lastMainTick = now; self.write(now: now) }
    }
    private func write(now: Double) {
        guard let token, heartbeatShouldContinue(now: now, lastMainTick: lastMainTick) else { return }
        try? writeJSON(Heartbeat(token: token, time: now, stop: stop), path)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    var item: NSStatusItem?
    var window: NSWindow!
    // Window controls (built in makeWindow)
    let headline = label("Ready", size: 19, weight: .semibold)
    let detailLabel = wrappingLabel("")
    let toneDot = symbol("circle.fill", size: 10, color: .tertiaryLabelColor)
    let progress = NSProgressIndicator()
    let powerChip = Chip(), lidChip = Chip(), networkChip = Chip(), thermalChip = Chip()
    let errorLabel = wrappingLabel("", color: .systemRed)
    let durationPopup = NSPopUpButton()
    var startButton: NSButton!
    var stopButton: NSButton!
    let shortcutLabel = label("", size: 11, color: .secondaryLabelColor)
    let footerLabel = wrappingLabel("", size: 11, color: .tertiaryLabelColor)
    var agentRows: [Int: AgentRow] = [:]
    var guardRow: GuardRow!
    // Menu items refreshed each time the menu opens
    var menuStatus: NSMenuItem!, menuToggle: NSMenuItem!, menuStartFor: NSMenuItem!, menuLogin: NSMenuItem!
    var lastView = SessionView()
    // Badges and Capture Guard presence are re-probed every few seconds, not on every tick.
    var integrationCache: [Int: String] = [:]
    var probedAt: Double = 0
    var guardURL: URL?
    let guardBundleID = "com.anmolbhatia.lidrunner.captureguard"
    var selectedHours: Int { sessionSeconds(storedHours: UserDefaults.standard.integer(forKey: "sessionHours")) / 3600 }
    // --snapshot <png> [--appearance dark|light] [--demo idle|active|closed|error]: render the
    // window once and exit. Read-only: no heartbeat, diagnostics, launches, hotkey or login changes.
    lazy var snapshotPath: String? = argument("--snapshot")
    lazy var demo: String? = argument("--demo")
    var snapshotMode: Bool { snapshotPath != nil }
    func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    var timer: Timer?
    var request: Request?
    var busy = false
    var authenticating = false
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var hotKeyRegistered = false
    var stopping = false
    var assertions: [IOPMAssertionID] = []
    var lastTick = Date().timeIntervalSince1970
    var maximumGap: Double = 0
    var closedSamples = 0
    var testClicks = 0
    var closedControlClicks = 0
    var began = Date().timeIntervalSince1970
    var status: Status?
    var lastError: String?
    var lastErrorAt: Double?
    var lastErrorIsStart = true
    var wasActive = false
    var tickCount = 0
    var lastAppend: Double?
    var lastSampleFingerprint = ""
    var quitAfterStop = false
    let networkMonitor = NWPathMonitor()
    var networkAvailable = false
    let keepers = agentApps.map(AgentKeeper.init)
    var chatGPT: AgentKeeper { keepers[0] }
    let heartbeatPath = userDir.appendingPathComponent("heartbeat.json").path
    lazy var heart = HeartbeatWriter(path: heartbeatPath)
    var activity: NSObjectProtocol?
    let diagnosticsPath = userDir.appendingPathComponent("diagnostics.json").path

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var defaults: [String: Any] = Dictionary(uniqueKeysWithValues: agentApps.map { ($0.defaultsKey, true) })
        defaults["sessionHours"] = 8
        UserDefaults.standard.register(defaults: defaults)
        if snapshotMode { renderSnapshot(); return }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkAvailable = path.status == .satisfied }
        }
        networkMonitor.start(queue: DispatchQueue(label: "LidRunner.network"))
        // A second copy (for example the build folder's app next to the installed one) would fight
        // over the shortcut and the heartbeat. Hand over to the running copy instead.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != NSRunningApplication.current }) {
            if let url = other.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in exit(0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            } else { exit(0) }
            return
        }
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "LidRunner")
        item.button?.title = ""
        let menu = NSMenu(); menu.delegate = self
        menuStatus = menu.addItem(withTitle: "LidRunner", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menuToggle = menu.addItem(withTitle: "Start session", action: #selector(toggleSession), keyEquivalent: "l")
        menuToggle.keyEquivalentModifierMask = [.command, .option, .control, .shift]
        let lengths = NSMenu()
        for hours in sessionLengths {
            let entry = lengths.addItem(withTitle: hours == 1 ? "1 hour" : "\(hours) hours", action: #selector(startMenu(_:)), keyEquivalent: "")
            entry.tag = hours * 3600; entry.target = self
        }
        menuStartFor = menu.addItem(withTitle: "Start for", action: nil, keyEquivalent: ""); menuStartFor.submenu = lengths
        menu.addItem(withTitle: "Show LidRunner", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menuLogin = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "ChatGPT Remote setup guide", action: #selector(remoteGuide), keyEquivalent: "")
        menu.addItem(withTitle: "Claude Remote Control guide", action: #selector(claudeRemoteGuide), keyEquivalent: "")
        menu.addItem(withTitle: "Open diagnostics folder", action: #selector(openDiagnostics), keyEquivalent: "")
        menu.addItem(withTitle: "Computer-control diagnostic", action: #selector(diagnosticClick), keyEquivalent: "")
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(withTitle: "LidRunner \(version)".trimmingCharacters(in: .whitespaces), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit LidRunner", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
        registerShortcut()
        if !UserDefaults.standard.bool(forKey: "loginConfigured") {
            do { try SMAppService.mainApp.register(); UserDefaults.standard.set(true, forKey: "loginConfigured") }
            catch { lastError = "Open at Login could not be enabled. Use the menu to try again."; lastErrorAt = Date().timeIntervalSince1970; lastErrorIsStart = false }
        }
        makeWindow()
        // Stay in the background when macOS opened us at login or a test flag is driving the app.
        let testing = CommandLine.arguments.contains("--start-verification")
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if testing { window.orderFront(nil) } else if !loginLaunch { showWindow() }
        heart.start()
        // Common modes: keep ticking while a menu or the session-length picker is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        tick()
        if testing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.begin(seconds: 300) }
        }
        // Regression check: hold the status menu open for N seconds during a session and
        // report whether ticks continued. Used with --start-verification.
        if let hold = argument("--test-menu-hold").flatMap(Double.init), hold > 0, hold <= 120 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [self] in
                let closer = Timer(timeInterval: hold, repeats: false) { [weak self] _ in self?.item?.menu?.cancelTracking() }
                RunLoop.main.add(closer, forMode: .common)
                let opened = Date(), ticksBefore = tickCount
                self.item?.button?.performClick(nil) // returns when the menu closes
                print(String(format: "menu-hold: open %.1fs, ticks during hold %d, session %@",
                             Date().timeIntervalSince(opened), tickCount - ticksBefore, request != nil ? "requested" : "none"))
                fflush(stdout)
            }
        }
    }
    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "LidRunner"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        let content = BackgroundView(); content.wantsLayer = true; window.contentView = content

        // Header
        let tile = NSView(); tile.wantsLayer = true; tile.layer?.cornerRadius = 11
        tile.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.47, blue: 0.32, alpha: 1).cgColor
        let tileIcon = symbol("laptopcomputer", size: 22, weight: .medium, color: .white)
        tileIcon.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(tileIcon)
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 44), tile.heightAnchor.constraint(equalToConstant: 44),
                                     tileIcon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), tileIcon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
        let header = hstack([tile, vstack([label("LidRunner", size: 22, weight: .bold),
                                           label("Keep ChatGPT, Claude and Gemini working with the lid closed", size: 12, color: .secondaryLabelColor)], spacing: 1)], spacing: 12)

        // Session card
        progress.style = .bar; progress.isIndeterminate = false; progress.controlSize = .small; progress.minValue = 0
        let chips = hstack([powerChip, lidChip, networkChip, thermalChip], spacing: 6)
        durationPopup.addItems(withTitles: ["1 hour", "2 hours", "4 hours", "8 hours"])
        for (item, hours) in zip(durationPopup.itemArray, [1, 2, 4, 8]) { item.tag = hours }
        durationPopup.selectItem(withTag: UserDefaults.standard.integer(forKey: "sessionHours"))
        durationPopup.target = self; durationPopup.action = #selector(durationChanged)
        durationPopup.setAccessibilityLabel("Session length")
        startButton = NSButton(title: "Start session", target: self, action: #selector(startSelected))
        startButton.bezelStyle = .rounded; startButton.keyEquivalent = "\r"; startButton.controlSize = .large
        stopButton = NSButton(title: "Stop", target: self, action: #selector(stop))
        stopButton.bezelStyle = .rounded; stopButton.controlSize = .large
        durationPopup.controlSize = .large
        let controls = hstack([durationPopup, startButton, stopButton, spacer(), shortcutLabel], spacing: 8)
        let session = Card([hstack([toneDot, headline], spacing: 8), detailLabel, progress, chips, errorLabel, controls], spacing: 10)
        [detailLabel, progress, controls, errorLabel].forEach(session.fill)

        // Agents card
        let agentsTitle = hstack([label("Agents", size: 13, weight: .semibold), spacer(),
                                  label("The Mac stays awake for all of them", size: 11, color: .secondaryLabelColor)])
        var agentViews: [NSView] = [agentsTitle]
        for (index, keeper) in keepers.enumerated() where keeper.installedURL != nil {
            let row = AgentRow(app: keeper.app, url: keeper.installedURL, index: index, target: self, action: #selector(toggleRemoteKeepAlive(_:)))
            agentRows[index] = row; agentViews.append(row)
        }
        if agentRows.isEmpty { agentViews.append(wrappingLabel("No ChatGPT, Claude, Gemini or Antigravity app found. Sessions still keep the Mac awake for command-line agents.")) }
        guardRow = GuardRow(target: self, action: #selector(guardAction))
        let divider = NSBox(); divider.boxType = .separator
        agentViews += [divider, guardRow]
        let agents = Card(agentViews, spacing: 12)
        agentViews.forEach(agents.fill)

        let root = vstack([header, session, agents, footerLabel], spacing: 14)
        root.edgeInsets = NSEdgeInsets(top: 34, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                                     root.widthAnchor.constraint(equalToConstant: 580)])
        [session, agents, footerLabel].forEach { $0.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true }
        fitWindow(); window.center()
    }
    func fitWindow() {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let size = window.contentView?.fittingSize, size.height > 0,
              abs(size.height - window.contentLayoutRect.height) > 0.5 else { return }
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.y += frame.height - newFrame.height; frame.size = newFrame.size
        window.setFrame(frame, display: true)
    }
    func render(_ v: SessionView) {
        switch v.tone {
        case .active: toneDot.contentTintColor = .systemGreen
        case .busy: toneDot.contentTintColor = .systemOrange
        case .warning: toneDot.contentTintColor = .systemRed
        case .idle: toneDot.contentTintColor = .tertiaryLabelColor
        }
        headline.stringValue = v.headline
        detailLabel.stringValue = v.detail
        if let remaining = v.remaining, let total = v.total, total > 0 {
            progress.isHidden = false; progress.maxValue = Double(total); progress.doubleValue = Double(total - remaining)
        } else { progress.isHidden = true }
        let low = !v.power.ac && (v.power.percent ?? 100) <= 25
        powerChip.set(v.power.ac ? "powerplug.fill" : (low ? "battery.25percent" : "battery.75percent"),
                      (v.power.ac ? "Charger" : "Battery") + (v.power.percent.map { " \($0)%" } ?? ""),
                      tint: low ? .systemOrange : (v.power.ac ? .systemGreen : .secondaryLabelColor))
        lidChip.set(v.lidClosed ? "laptopcomputer.slash" : "laptopcomputer", v.lidClosed ? "Lid closed" : "Lid open",
                    tint: v.lidClosed ? .systemBlue : .secondaryLabelColor)
        networkChip.set(v.network ? "wifi" : "wifi.slash", v.network ? "Online" : "Offline", tint: v.network ? .secondaryLabelColor : .systemOrange)
        thermalChip.isHidden = v.thermal < 1
        thermalChip.set("thermometer.medium", v.thermal >= 2 ? "Hot" : "Warm", tint: v.thermal >= 2 ? .systemRed : .systemOrange)
        errorLabel.stringValue = v.error ?? ""; errorLabel.isHidden = v.error == nil
        // While a session runs (or is starting/stopping) the only useful action is Stop.
        startButton.isHidden = !v.canStart; durationPopup.isHidden = !v.canStart
        stopButton.isHidden = !v.canStop && !v.canStart; stopButton.isEnabled = v.canStop
        stopButton.title = v.canStart ? "Stop" : "Stop session"
        stopButton.keyEquivalent = v.canStart ? "" : "\u{1b}"
        startButton.keyEquivalent = v.canStart ? "\r" : ""
        shortcutLabel.stringValue = v.shortcutRegistered ? "⌘⌥⌃⇧L starts or stops" : "⌘⌥⌃⇧L unavailable (conflict)"
        shortcutLabel.toolTip = "Starts a session of the selected length (\(v.hours) hour\(v.hours == 1 ? "" : "s")), or stops the current one"
        shortcutLabel.textColor = v.shortcutRegistered ? .secondaryLabelColor : .systemOrange
        for (index, row) in agentRows {
            let k = keepers[index]
            row.update(running: k.running, launching: k.launching, error: k.launchError, enabled: k.enabled, integration: integrationCache[index])
        }
        guardRow.update(v.captureGuard)
        lastView = v
        footerLabel.stringValue = "Stops automatically at 15% battery, high thermal pressure, the time limit, or if LidRunner quits. Keep the Mac ventilated and stop the session before putting it in a bag." + (v.loginEnabled ? "" : "  Open at Login is off.")
        fitWindow()
    }
    // Design review only: fake a state for --snapshot. Never used by a normal launch.
    func applyDemo(_ v: inout SessionView) {
        guard snapshotMode, let demo else { return }
        switch demo {
        case "active", "closed":
            v.tone = .active; v.headline = "Session active · 6h 12m left"; v.remaining = 22320; v.total = 28800
            v.detail = "Safe to close the lid. Normal sleep returns at 21:30 or when you stop."
            v.canStart = false; v.canStop = true; v.lidClosed = demo == "closed"; v.power = Power(percent: demo == "closed" ? 22 : 64, ac: false)
            v.captureGuard = demo == "closed" ? .ready("Watching 1 shared window") : .ready("Active · no shared windows yet")
        case "idle": v.captureGuard = .ready("Ready · works when the lid is closed in a session")
        case "guard": v.captureGuard = .needsPermission
        case "error":
            v.tone = .warning; v.headline = "Session not started"; v.error = "Another sleep override is already active, or the setting could not be read. LidRunner has not changed it."
        default: break
        }
    }
    func renderSnapshot() {
        if let look = argument("--appearance") { NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) }
        makeWindow()
        for keeper in keepers { keeper.running = !NSRunningApplication.runningApplications(withBundleIdentifier: keeper.app.bundleID).isEmpty }
        tick()
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            fitWindow()
            let view = window.contentView!
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotPath!))
            }
            exit(0)
        }
    }
    @objc func durationChanged() { UserDefaults.standard.set(durationPopup.selectedTag(), forKey: "sessionHours") }
    @objc func startSelected() { begin(seconds: sessionSeconds(storedHours: durationPopup.selectedTag())) }
    @objc func guardAction() {
        switch lastView.captureGuard {
        case .needsPermission:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .notRunning:
            guard let guardURL else { return }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            NSWorkspace.shared.openApplication(at: guardURL, configuration: configuration, completionHandler: nil)
        default: break
        }
    }
    // MARK: Menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === item?.menu else { return }
        let running = request != nil
        menuStatus.title = lastView.menuTitle
        menuToggle.title = running ? "Stop session and restore sleep" : "Start \(selectedHours)-hour session"
        menuStartFor.isHidden = running
        menuLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSession): return !busy && !stopping
        case #selector(startMenu(_:)): return !busy && request == nil
        default: return true
        }
    }
    // MARK: Notifications
    func notifySessionEnded(_ reason: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "LidRunner session ended"
        content.body = lastSessionSentence(reason).replacingOccurrences(of: "Last session", with: "The session") + " Normal sleep is restored."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "session-ended", content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        showWindow(); completionHandler()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func remoteGuide() {
        NSWorkspace.shared.open(URL(string: "https://learn.chatgpt.com/docs/remote-connections")!)
    }
    @objc func claudeRemoteGuide() {
        NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/remote-control")!)
    }
    @objc func toggleRemoteKeepAlive(_ sender: NSSwitch) {
        guard keepers.indices.contains(sender.tag) else { return }
        let keeper = keepers[sender.tag]
        UserDefaults.standard.set(sender.state == .on, forKey: keeper.app.defaultsKey)
        keeper.reset()
        tick()
    }
    func maintainAgentApps(active: Bool, now: Double) {
        for keeper in keepers {
            keeper.running = !NSRunningApplication.runningApplications(withBundleIdentifier: keeper.app.bundleID).isEmpty
            if snapshotMode { continue }
            if !active { keeper.seenThisSession = false }
            else if keeper.running { keeper.seenThisSession = true }
            maintain(keeper, active: active, now: now)
        }
    }
    func maintain(_ keeper: AgentKeeper, active: Bool, now: Double) {
        if !active || !keeper.enabled || keeper.running {
            keeper.missingSince = nil
            if keeper.running { keeper.attempts = 0; keeper.launchError = nil }
            return
        }
        if keeper.missingSince == nil { keeper.missingSince = now }
        guard shouldReopenAgentApp(active: active, enabled: keeper.enabled, running: keeper.running, launching: keeper.launching,
                                   now: now, missingSince: keeper.missingSince, lastAttempt: keeper.lastLaunch, attempts: keeper.attempts,
                                   seenThisSession: keeper.seenThisSession, launchIfNeverSeen: keeper.app.launchIfNeverSeen) else { return }
        keeper.lastLaunch = now; keeper.attempts += 1
        guard let url = keeper.installedURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: keeper.app.bundleID) else {
            keeper.launchError = "\(keeper.app.name) is not installed"; return
        }
        keeper.launching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                keeper.launching = false
                keeper.launchError = error?.localizedDescription
            }
        }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    // Shortcut and menu: stop the current session, or start one of the remembered length.
    @objc func toggleSession() {
        if request != nil && !busy { stop() }
        else if request == nil && !busy { begin(seconds: selectedHours * 3600) }
    }
    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { self.error("Could not change Open at Login: \(error.localizedDescription)", start: false) }
    }
    func registerShortcut() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var received = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  received.signature == 0x4C494452, received.id == 1 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.toggleSession()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let id = EventHotKeyID(signature: 0x4C494452, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey | controlKey | shiftKey), id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &hotKey)
        hotKeyRegistered = result == noErr
    }
    @objc func startMenu(_ sender: NSMenuItem) { begin(seconds: sender.tag) }
    @objc func diagnosticClick() {
        testClicks += 1
        if rootProperty("AppleClamshellState") == true { closedControlClicks += 1 }
        tick()
    }
    @objc func openDiagnostics() { NSWorkspace.shared.open(userDir) }
    @objc func quit() {
        if request != nil { quitAfterStop = true; stop() } else { NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if request != nil { quitAfterStop = true; stop(); return .terminateCancel }
        return .terminateNow
    }
    @objc func stop() {
        guard request != nil else { return }; stopping = true; heartbeat(); tick()
    }
    func heartbeat() { heart.update(token: request?.token, stop: stopping) }
    // A session is user-initiated work: opt out of App Nap and timer throttling while one is wanted.
    func updateActivity(wanted: Bool) {
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "LidRunner closed-lid session")
        } else if !wanted, let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
    }
    func begin(seconds: Int) {
        guard !busy, request == nil else { return }
        let battery = power()
        guard battery.ac || (battery.percent ?? 0) > 15 else { error("Connect the charger or charge above 15% before starting."); return }
        guard sleepDisabled() == 0 else { error("Another sleep override is already active, or the setting could not be read. LidRunner has not changed it."); return }
        guard let helper = Bundle.main.path(forResource: "LidRunnerGuardian", ofType: nil) else { error("Missing helper executable."); return }
        if let existing = readJSON(Status.self, systemDir + "/status.json"), ["active", "restoring"].contains(existing.phase) {
            error("A previous session is still restoring sleep. Wait a few seconds and retry."); return
        }
        let r = Request(token: UUID().uuidString, uid: getuid(), pid: getpid(), boot: bootID(), created: Date().timeIntervalSince1970, seconds: seconds, heartbeat: heartbeatPath)
        request = r; busy = true; stopping = false; lastError = nil; lastErrorAt = nil; wasActive = false; heartbeat()
        // Ask once, in context: the only notification is "your session ended on its own".
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        do {
            try writeJSON(r, userDir.appendingPathComponent("request.json").path)
            let config = HelperConfig(version: 2, uid: getuid(), requestPath: userDir.appendingPathComponent("request.json").path, heartbeatPath: heartbeatPath)
            let installed = readJSON(HelperConfig.self, systemDir + "/config.json")
            if installed?.version == 2 && installed?.uid == getuid() && installed?.requestPath == config.requestPath && installed?.heartbeatPath == config.heartbeatPath && run("/bin/launchctl", ["print", "system/" + service]).1.contains("state = running") {
                busy = false; tick(); return
            }
            authenticating = true
            let payload = try JSONEncoder().encode(config).base64EncodedString()
            let plist: [String: Any] = ["Label": service, "ProgramArguments": [helperPath], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 3, "StandardOutPath": "/var/log/\(service).log", "StandardErrorPath": "/var/log/\(service).log"]
            let daemon = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).base64EncodedString()
            let script = """
            set -eu
            export PATH=/usr/bin:/bin:/usr/sbin:/sbin
            test ! -L '\(systemDir)'
            /usr/bin/install -d -o root -g wheel -m 755 '\(systemDir)' /Library/PrivilegedHelperTools
            /bin/launchctl bootout system '\(daemonPath)' >/dev/null 2>&1 || true
            /usr/bin/install -o root -g wheel -m 755 \(shellQuote(helper)) '\(helperPath)'
            /usr/bin/printf '%s' '\(payload)' | /usr/bin/base64 -D > '\(systemDir)/config.json.new'
            /usr/sbin/chown root:wheel '\(systemDir)/config.json.new'
            /bin/chmod 644 '\(systemDir)/config.json.new'
            /bin/mv -f '\(systemDir)/config.json.new' '\(systemDir)/config.json'
            /usr/bin/printf '%s' '\(daemon)' | /usr/bin/base64 -D > '\(daemonPath).new'
            /usr/sbin/chown root:wheel '\(daemonPath).new'
            /bin/chmod 644 '\(daemonPath).new'
            /bin/mv -f '\(daemonPath).new' '\(daemonPath)'
            /bin/launchctl bootstrap system '\(daemonPath)'
            """
            let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
            // macOS handles authentication. No passwords are read or stored by this app.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run("/usr/bin/osascript", ["-e", appleScript])
                DispatchQueue.main.async {
                    self.busy = false; self.authenticating = false
                    if result.0 != 0 { self.request = nil; self.error("Session was not enabled: \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))") }
                    self.tick()
                }
            }
        } catch { busy = false; authenticating = false; request = nil; self.error(error.localizedDescription) }
        tick()
    }
    func error(_ message: String, start: Bool = true) {
        lastError = message; lastErrorAt = Date().timeIntervalSince1970; lastErrorIsStart = start
        // A shortcut press with the window closed must not fail silently.
        if start, !snapshotMode, window != nil, !window.isVisible { showWindow() }
        tick()
    }
    func updateAssertions(active: Bool) {
        if active && assertions.isEmpty {
            for kind in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(kind as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "LidRunner active session" as CFString, &id) == kIOReturnSuccess { assertions.append(id) }
            }
        } else if !active { for id in assertions { IOPMAssertionRelease(id) }; assertions = [] }
    }
    func tick() {
        let now = Date().timeIntervalSince1970
        tickCount += 1
        if !snapshotMode { maximumGap = max(maximumGap, now - lastTick); lastTick = now; heartbeat() }
        status = readJSON(Status.self, systemDir + "/status.json")
        let mine = status?.token == request?.token && request != nil
        let active = mine && status?.phase == "active" && now - (status?.updated ?? 0) < 10
        if !snapshotMode {
            if active { wasActive = true }
            if mine && ["stopped", "failed"].contains(status?.phase ?? "") && !busy {
                if let notice = sessionEndNotice(wasActive: wasActive, phase: status?.phase ?? "", reason: status?.reason ?? "", userStopping: stopping || quitAfterStop) {
                    notifySessionEnded(notice)
                }
                request = nil; stopping = false; wasActive = false
                if quitAfterStop { updateAssertions(active: false); NSApp.terminate(nil); return }
            }
            if request != nil && !busy && !active && now - (request?.created ?? now) > 310 && !mine {
                request = nil; lastError = "Helper did not report a session. Check diagnostics before closing the lid."
                lastErrorAt = now; lastErrorIsStart = true
            }
            updateAssertions(active: active)
            updateActivity(wanted: request != nil)
        }
        let p = power(), closed = rootProperty("AppleClamshellState") ?? false
        if closed { closedSamples += 1 }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16); var count: UInt32 = 0
        CGGetActiveDisplayList(16, &displays, &count)
        maintainAgentApps(active: active, now: now)
        let chatRunning = chatGPT.running
        let remaining = max(0, Int((status?.deadline ?? now) - now))
        let login = SMAppService.mainApp.status == .enabled

        var v = SessionView()
        v.power = p; v.lidClosed = closed; v.thermal = ProcessInfo.processInfo.thermalState.rawValue
        v.network = snapshotMode ? ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)))) as? [String: Any])?["networkLinkAvailable"] as? Bool ?? false : networkAvailable
        v.shortcutRegistered = snapshotMode ? true : hotKeyRegistered
        v.loginEnabled = login
        v.canStart = !busy && request == nil; v.canStop = request != nil && !stopping
        let anyAgent = keepers.contains(where: \.running)
        if authenticating {
            v.tone = .busy; v.headline = "Waiting for administrator approval"; v.detail = "One-time setup installs the bounded sleep helper. LidRunner never sees your password."
        } else if busy || (request != nil && !mine) {
            v.tone = .busy; v.headline = "Starting session…"; v.detail = "Wait for “Session active” before closing the lid."
        } else if stopping {
            v.tone = .busy; v.headline = "Restoring normal sleep…"
        } else if active {
            let ends = DateFormatter.localizedString(from: Date(timeIntervalSince1970: status?.deadline ?? now), dateStyle: .none, timeStyle: .short)
            v.tone = .active; v.headline = "Session active · \(duration(remaining)) left"
            v.detail = "Safe to close the lid. Normal sleep returns at \(ends) or when you stop." + (anyAgent ? "" : " No agent app is running.")
            v.remaining = remaining; v.total = request?.seconds
        } else {
            v.headline = "Ready"
            if status?.phase == "stopped" { v.detail = lastSessionSentence(status!.reason) + " Start a new one before closing the lid." }
            else if status?.phase == "failed" { v.tone = .warning; v.detail = status!.reason }
            else { v.detail = "Start a session before closing the lid. The Mac then stays awake on charger or battery." }
        }
        if lastError != nil, !errorStillRelevant(now: now, shownAt: lastErrorAt) { lastError = nil; lastErrorAt = nil }
        v.error = lastError
        if lastError != nil, !active, !busy, !stopping {
            v.tone = .warning
            if lastErrorIsStart { v.headline = "Session not started" }
        }
        v.hours = selectedHours
        if now - probedAt >= 6 || now < probedAt {
            probedAt = now
            for (index, row) in agentRows { integrationCache[index] = row.integrationProbe?() }
            guardURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: guardBundleID)
        }
        let guardReport = (try? Data(contentsOf: userDir.appendingPathComponent("capture-guard.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        v.captureGuard = captureGuardState(installed: guardURL != nil, report: guardReport, now: now)
        applyDemo(&v)
        render(v)
        if snapshotMode { return }
        menuStatus?.title = v.menuTitle // stays live while the menu is open
        item?.button?.title = active ? " \(duration(remaining))" : ""
        item?.button?.toolTip = active ? "LidRunner session active · \(duration(remaining)) left" : "LidRunner"
        let diagnostic: [String: Any] = ["time": now, "started": began, "lidClosed": closed, "activeDisplays": count, "chatGPTRunning": chatRunning, "closedSamples": closedSamples, "largestSamplingGapSeconds": maximumGap, "controlTestClicks": testClicks, "closedControlTestClicks": closedControlClicks, "phase": status?.phase ?? "idle", "reason": status?.reason ?? "", "onCharger": p.ac, "batteryPercent": p.percent ?? -1, "sleepDisabled": rootProperty("SleepDisabled") ?? false, "thermalState": ProcessInfo.processInfo.thermalState.rawValue, "shortcutRegistered": hotKeyRegistered, "networkLinkAvailable": networkAvailable, "keepChatGPTAvailable": chatGPT.enabled, "chatGPTLaunchAttempts": chatGPT.attempts, "chatGPTLaunching": chatGPT.launching, "agentApps": Dictionary(uniqueKeysWithValues: keepers.map { ($0.app.key, $0.running) }), "agentKeepAlive": Dictionary(uniqueKeysWithValues: keepers.map { ($0.app.key, $0.enabled) }), "agentLaunchAttempts": Dictionary(uniqueKeysWithValues: keepers.map { ($0.app.key, $0.attempts) }), "phoneConnectionVerifiedByMonitor": false, "loginEnabled": login, "shortcut": "Command-Option-Control-Shift-L"]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: diagnosticsPath), options: .atomic)
            // Session samples are evidence; idle samples are only state changes plus one a minute.
            let fingerprint = "\(status?.phase ?? "idle")|\(closed)|\(p.ac)|\(rootProperty("SleepDisabled") ?? false)|\(ProcessInfo.processInfo.thermalState.rawValue)|\(networkAvailable)|\(count)|\(keepers.map { $0.running ? "1" : "0" }.joined())"
            guard shouldAppendSample(now: now, lastAppend: lastAppend, sessionActive: active || request != nil, changed: fingerprint != lastSampleFingerprint) else { return }
            lastAppend = now; lastSampleFingerprint = fingerprint
            let log = userDir.appendingPathComponent("verification.jsonl")
            if let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? NSNumber, size.intValue > 10_000_000 {
                let old = userDir.appendingPathComponent("verification.previous.jsonl")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: log, to: old)
            }
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            if let f = try? FileHandle(forWritingTo: log) { defer { try? f.close() }; _ = try? f.seekToEnd(); try? f.write(contentsOf: data + Data([10])) }
        }
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
