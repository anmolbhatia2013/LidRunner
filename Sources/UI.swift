import AppKit

// Small AppKit building blocks for the LidRunner window. All colours are dynamic system
// colours so the window follows light/dark mode without extra code.

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}
func wrappingLabel(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size); field.textColor = color
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}
func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) -> NSImageView {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.preferringMonochrome()))
    view.contentTintColor = color
    view.setContentHuggingPriority(.required, for: .horizontal)
    return view
}
func hstack(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = align
    return stack
}
func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    return stack
}
func spacer() -> NSView {
    let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
}

/// Window content background (so snapshots and the live window match in both appearances).
final class BackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
}

/// Rounded card that hosts a vertical stack and stretches it to the card width.
final class Card: NSBox {
    let stack: NSStackView
    init(_ views: [NSView], spacing: CGFloat = 12) {
        stack = vstack(views, spacing: spacing)
        super.init(frame: .zero)
        boxType = .custom; titlePosition = .noTitle
        cornerRadius = 12; borderWidth = 1
        borderColor = .separatorColor
        // White card in light mode; a faint lift over the window background in dark mode.
        fillColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.045) : .controlBackgroundColor }
        contentViewMargins = NSSize(width: 18, height: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(); holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor), stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            stack.topAnchor.constraint(equalTo: holder.topAnchor), stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
        contentView = holder
    }
    required init?(coder: NSCoder) { nil }
    func fill(_ view: NSView) { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    /// Replace the card's rows (used when an app is added or removed).
    func setViews(_ views: [NSView]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { stack.addArrangedSubview(view); fill(view) }
    }
}

/// Icon + text pill used for power, lid, network and thermal readouts.
final class Chip: NSView {
    private let icon = symbol("circle", size: 11)
    private let text = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 9
        let row = hstack([icon, text], spacing: 5)
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 9)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func set(_ symbolName: String, _ value: String, tint: NSColor = .secondaryLabelColor) {
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.contentTintColor = tint; text.stringValue = value
        setAccessibilityLabel(value)
    }
    override func updateLayer() { layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor }
    override var wantsUpdateLayer: Bool { true }
}

/// Per-agent presentation details that don't belong in the policy layer.
struct AgentPresentation {
    let remote: String
    var tip = "installed: the agent is told when the lid closes"
    let integration: () -> String?
}
let agentPresentation: [String: AgentPresentation] = [
    "chatgpt": AgentPresentation(remote: "Phone: ChatGPT → Remote") {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/skills/closed-lid-mode/SKILL.md") ? "Codex skill" : nil
    },
    "claude": AgentPresentation(remote: "Phone: Remote Control") {
        let path = NSHomeDirectory() + "/.claude/plugins/installed_plugins.json"
        guard let data = FileManager.default.contents(atPath: path), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return nil }
        return plugins.keys.contains { $0.hasPrefix("lidrunner@") } ? "Claude plugin" : nil
    },
    "gemini": AgentPresentation(remote: "Chat app · agents run in Antigravity") { nil },
    "antigravity": AgentPresentation(remote: "Phone: agy remote-control") {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gemini/config/plugins/lidrunner/plugin.json") ? "Gemini plugin" : nil
    },
    // RustDesk's own service keeps it reachable at the login screen; LidRunner keeps the Mac awake for it.
    "rustdesk": AgentPresentation(remote: "Phone: RustDesk app", tip: "is installed, so RustDesk can connect without anyone at the Mac") {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.carriez.RustDesk_service.plist") ? "Unattended service" : nil
    },
]

/// One agent: app icon, name, live state, LidRunner skill/plugin badge, keep-alive switch.
final class AgentRow: NSView {
    let toggle = NSSwitch()
    private let dot = symbol("circle.fill", size: 7, color: .tertiaryLabelColor)
    private let state = label("", size: 11, color: .secondaryLabelColor)
    private let badge = label("", size: 10, weight: .semibold, color: .systemGreen)
    private let presentation: AgentPresentation?
    private let custom: Bool
    init(app: AgentApp, url: URL?, index: Int, target: AnyObject, action: Selector, removeAction: Selector? = nil) {
        presentation = agentPresentation[app.key]
        custom = app.custom
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true; icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let name = label(app.name, size: 13, weight: .semibold)
        badge.wantsLayer = true
        let titleRow = hstack([name, badge], spacing: 6, align: .firstBaseline)
        let detail = hstack([dot, state], spacing: 5)
        let text = vstack([titleRow, detail], spacing: 2)
        toggle.tag = index; toggle.target = target; toggle.action = action
        toggle.controlSize = .small
        toggle.toolTip = app.launchIfNeverSeen ? "Keep \(app.name) running during a session (opens it if it's closed)"
                                               : "Reopen \(app.name) if it quits during a session (never opens it otherwise)"
        toggle.setAccessibilityLabel(app.launchIfNeverSeen ? "Keep \(app.name) running" : "Reopen \(app.name) if it quits")
        let keepLabel = label(app.launchIfNeverSeen ? "Keep running" : "Reopen if quit", size: 11, color: .secondaryLabelColor)
        var views: [NSView] = [icon, text, spacer()]
        if app.custom, let removeAction {
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")!, target: target, action: removeAction)
            remove.isBordered = false; remove.tag = index; remove.contentTintColor = .tertiaryLabelColor
            remove.toolTip = "Remove \(app.name) from LidRunner"; remove.setAccessibilityLabel("Remove \(app.name) from LidRunner")
            views.append(remove)
        }
        views += [keepLabel, toggle] // switches stay in one column, with or without a remove button
        let row = hstack(views, spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    /// `integration` is the cached badge text from `presentation.integration()`; the caller
    /// refreshes it every few seconds rather than re-reading config files on every tick.
    var integrationProbe: (() -> String?)? { presentation?.integration }
    func update(running: Bool, launching: Bool, error: String?, enabled: Bool, integration: String?, remote: String? = nil) {
        dot.contentTintColor = running ? .systemGreen : (launching ? .systemOrange : .tertiaryLabelColor)
        let status = error.map { "Couldn't open: \($0)" } ?? (running ? "Running" : (launching ? "Opening…" : "Not running"))
        state.stringValue = [status, remote ?? presentation?.remote ?? (custom ? "Added by you" : nil)].compactMap { $0 }.joined(separator: " · ")
        state.textColor = error == nil ? .secondaryLabelColor : .systemRed
        badge.stringValue = integration.map { "✓ " + $0 } ?? ""
        badge.isHidden = integration == nil
        badge.toolTip = integration.map { "\($0) \(presentation?.tip ?? "")" }
        toggle.state = enabled ? .on : .off
    }
}

/// Optional Capture Guard companion: one line of state, plus a button only when it needs you.
final class GuardRow: NSView {
    let button = NSButton(title: "", target: nil, action: nil)
    private let dot = symbol("circle.fill", size: 7, color: .tertiaryLabelColor)
    private let state = label("", size: 11, color: .secondaryLabelColor)
    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        let icon = symbol("macwindow.on.rectangle", size: 19, weight: .regular, color: .secondaryLabelColor)
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true; icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let name = label("Capture Guard", size: 13, weight: .semibold)
        let text = vstack([name, hstack([dot, state], spacing: 5)], spacing: 2)
        button.bezelStyle = .rounded; button.controlSize = .small; button.target = target; button.action = action
        let row = hstack([icon, text, spacer(), button], spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
        toolTip = "Optional companion that re-centres remotely controlled windows so screenshots aren't clipped while the lid is closed"
    }
    required init?(coder: NSCoder) { nil }
    func update(_ guardState: GuardState) {
        isHidden = guardState == .notInstalled
        var text = "", tint = NSColor.tertiaryLabelColor, action: String? = nil, warn = false
        switch guardState {
        case .notInstalled: break
        case .notRunning: text = "Not running · screenshots may be clipped with the lid closed"; tint = .systemOrange; action = "Open"; warn = true
        case .needsPermission: text = "Needs Accessibility permission to re-centre windows"; tint = .systemOrange; action = "Open Settings…"; warn = true
        case .paused: text = "Paused from its menu-bar icon"; tint = .tertiaryLabelColor
        case .ready(let detail): text = detail; tint = .systemGreen
        }
        dot.contentTintColor = tint; state.stringValue = text
        state.textColor = warn ? .systemOrange : .secondaryLabelColor
        button.isHidden = action == nil; button.title = action ?? ""
        setAccessibilityLabel("Capture Guard: \(text)")
    }
}

/// A switch with a title, a line of live state, and an optional button (Phone remote, Stay reachable).
final class SettingRow: NSView {
    let toggle = NSSwitch()
    let button = NSButton(title: "", target: nil, action: nil)
    private let detail = wrappingLabel("", size: 11)
    init(symbolName: String, title: String, target: AnyObject, toggleAction: Selector, buttonTitle: String? = nil, buttonAction: Selector? = nil) {
        super.init(frame: .zero)
        let icon = symbol(symbolName, size: 19, weight: .regular, color: .secondaryLabelColor)
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true; icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        detail.maximumNumberOfLines = 2
        let text = vstack([label(title, size: 13, weight: .semibold), detail], spacing: 2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toggle.controlSize = .small; toggle.target = target; toggle.action = toggleAction; toggle.setAccessibilityLabel(title)
        button.bezelStyle = .rounded; button.controlSize = .small; button.target = target; button.action = buttonAction
        button.title = buttonTitle ?? ""; button.isHidden = buttonTitle == nil
        button.setContentHuggingPriority(.required, for: .horizontal); toggle.setContentHuggingPriority(.required, for: .horizontal)
        let row = hstack([icon, text, spacer(), button, toggle], spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func update(_ setting: SettingView, showButton: Bool = false) {
        toggle.state = setting.on ? .on : .off
        detail.stringValue = setting.detail
        detail.textColor = setting.warn ? .systemOrange : .secondaryLabelColor
        button.isHidden = !showButton || button.title.isEmpty
    }
}
struct SettingView { var on = false; var detail = ""; var warn = false }

/// Everything the window shows, computed once per tick (or faked for --demo snapshots).
struct SessionView {
    enum Tone { case idle, active, busy, warning }
    var tone: Tone = .idle
    var headline = "Ready"
    var detail = ""
    var remaining: Int?
    var total: Int?
    var power = Power(percent: nil, ac: false)
    var lidClosed = false
    var network = false
    var thermal = 0
    var error: String?
    var canStart = true
    var canStop = false
    var shortcutRegistered = true
    var loginEnabled = true
    var captureGuard = GuardState.notInstalled
    var hours = 8
    /// idle, starting, active, standby or stopping: the phone remote's view of the session.
    var state = "idle"
    var remote = SettingView(detail: "Start, stop and check sessions from your phone")
    var reach = SettingView(detail: "Plugged in, the Mac stays awake with the lid closed")
    /// One line for the menu-bar menu.
    var menuTitle: String { tone == .idle ? "LidRunner · no session" : headline }
}

func duration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
