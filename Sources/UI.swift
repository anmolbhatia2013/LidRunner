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
]

/// One agent: app icon, name, live state, LidRunner skill/plugin badge, keep-alive switch.
final class AgentRow: NSView {
    let toggle = NSSwitch()
    private let dot = symbol("circle.fill", size: 7, color: .tertiaryLabelColor)
    private let state = label("", size: 11, color: .secondaryLabelColor)
    private let badge = label("", size: 10, weight: .semibold, color: .systemGreen)
    private let presentation: AgentPresentation?
    init(app: AgentApp, url: URL?, index: Int, target: AnyObject, action: Selector) {
        presentation = agentPresentation[app.key]
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
        let row = hstack([icon, text, spacer(), keepLabel, toggle], spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    func update(running: Bool, launching: Bool, error: String?, enabled: Bool) {
        dot.contentTintColor = running ? .systemGreen : (launching ? .systemOrange : .tertiaryLabelColor)
        let status = error.map { "Couldn't open: \($0)" } ?? (running ? "Running" : (launching ? "Opening…" : "Not running"))
        state.stringValue = [status, presentation?.remote].compactMap { $0 }.joined(separator: " · ")
        state.textColor = error == nil ? .secondaryLabelColor : .systemRed
        let integration = presentation?.integration()
        badge.stringValue = integration.map { "✓ " + $0 } ?? ""
        badge.isHidden = integration == nil
        badge.toolTip = integration.map { "\($0) installed: the agent is told when the lid closes" }
        toggle.state = enabled ? .on : .off
    }
}

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
}

func duration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
