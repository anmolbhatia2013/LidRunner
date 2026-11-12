import AppKit
import CoreImage

// Phone remote and "stay reachable on charger": the AppDelegate side. Protocol rules live in
// RemoteProtocol.swift, the socket in RemoteServer.swift, and the page in remote.html.
extension AppDelegate {
    var remoteSecretPath: String { userDir.appendingPathComponent("remote-secret").path }
    var remotePort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "remotePort")
        return (1024...65535).contains(stored) ? UInt16(stored) : remoteDefaultPort
    }

    func setupRemote() {
        remoteSecret = loadRemoteSecret()
        remotePage = Bundle.main.url(forResource: "remote", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
        remoteIcon = Bundle.main.url(forResource: "remote-icon", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
        remoteServer.respond = { [weak self] request in self?.remoteRespond(request) ?? jsonResponse(500, ["error": "unavailable"]) }
        remoteServer.onState = { [weak self] problem in
            self?.remoteProblem = problem; self?.remoteListening = problem == nil; self?.tick()
        }
        // Enabled but the secret is missing (deleted by hand, restored preferences): make a new one
        // rather than listen with nothing to pair against.
        if remoteEnabled, remoteSecret == nil { createRemoteSecret() }
        if remoteEnabled { remoteServer.start(port: remotePort) }
        // RustDesk prints its ID on request; ask once, off the main thread.
        if let rustDesk = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.carriez.rustdesk") {
            DispatchQueue.global(qos: .utility).async {
                let output = run(rustDesk.appendingPathComponent("Contents/MacOS/RustDesk").path, ["--get-id"]).1
                let id = output.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if (6...16).contains(id.count), id.allSatisfy(\.isNumber) { DispatchQueue.main.async { self.rustDeskID = id } }
            }
        }
    }

    // MARK: Pairing secret (32 random bytes, hex, readable only by this user)

    func loadRemoteSecret() -> Data? {
        guard let text = try? String(contentsOfFile: remoteSecretPath, encoding: .utf8),
              let data = dataFromHex(text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else { return nil }
        return data
    }
    @discardableResult func createRemoteSecret() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        try? FileManager.default.removeItem(atPath: remoteSecretPath)
        guard FileManager.default.createFile(atPath: remoteSecretPath, contents: Data(hex(bytes).utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        remoteSecret = Data(bytes); remoteNonces = NonceCache(); remoteLastSeen = nil
        UserDefaults.standard.removeObject(forKey: "remoteLastSeen")
        return remoteSecret
    }

    // MARK: Switches

    @objc func toggleRemote(_ sender: NSSwitch) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "remoteEnabled")
        if on {
            let firstTime = remoteSecret == nil
            if firstTime, createRemoteSecret() == nil { error("Couldn't create a pairing code.", start: false); UserDefaults.standard.set(false, forKey: "remoteEnabled"); return }
            remoteServer.start(port: remotePort); remoteProbedAt = 0
            if firstTime { showPairing() }
        } else {
            remoteServer.stop(); remoteListening = false; remoteProblem = nil; remoteBlocked = false
            pairingWindow?.orderOut(nil)
        }
        tick()
    }
    @objc func toggleStandby(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "stayReachable")
        lastStandbyStart = nil
        tick()
    }
    func describeRemote(_ v: inout SessionView, now: Double, onCharger: Bool) {
        helperVersion = readJSON(HelperConfig.self, systemDir + "/config.json")?.version ?? 0
        if remoteLastSeen == nil { let stored = UserDefaults.standard.double(forKey: "remoteLastSeen"); if stored > 0 { remoteLastSeen = stored } }
        if remoteEnabled, remoteListening, now - remoteProbedAt >= 20 || now < remoteProbedAt, let address = lanAddress() {
            remoteProbedAt = now
            probeListener(host: address, port: remotePort) { [weak self] reachable in
                guard let self, self.remoteBlocked == reachable else { return }
                self.remoteBlocked = !reachable; self.tick()
            }
        }
        if remoteEnabled {
            if let remoteProblem { v.remote = SettingView(on: true, detail: remoteProblem, warn: true) }
            else if remoteBlocked {
                v.remote = SettingView(on: true, detail: "Blocked by the macOS firewall. Allow LidRunner in System Settings → Network → Firewall → Options.", warn: true)
            } else {
                let paths = tailscaleAddress() == nil ? "Wi-Fi only (Tailscale is off)" : "Wi-Fi and Tailscale"
                let seen = remoteLastSeen.map { "phone last seen \(ago(now - $0))" } ?? "no phone connected yet"
                v.remote = SettingView(on: true, detail: "On · \(paths) · \(seen)")
            }
        }
        if standbyEnabled {
            let detail: String
            if sessionIsStandby { detail = onCharger ? "Active: the Mac stays awake while plugged in" : "Charger disconnected: ending in two minutes" }
            else if request != nil { detail = "On · resumes after the current session, while plugged in" }
            else if !onCharger { detail = "On · waiting for the charger. On battery the Mac sleeps normally when the lid closes." }
            else { detail = "On · starting…" }
            v.reach = SettingView(on: true, detail: detail)
        }
    }
    func ago(_ seconds: Double) -> String {
        switch seconds {
        case ..<90: return "just now"
        case ..<5400: return "\(Int(seconds / 60)) minutes ago"
        case ..<129600: return "\(Int((seconds / 3600).rounded())) hours ago"
        default: return "\(Int(seconds / 86400)) days ago"
        }
    }

    // MARK: Requests

    func remoteRespond(_ request: HTTPRequest) -> Data {
        let now = Date().timeIntervalSince1970
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            guard let remotePage else { return jsonResponse(500, ["error": "page missing"]) }
            return httpResponse(status: 200, contentType: "text/html; charset=utf-8", body: remotePage, extraHeaders: [
                "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'"])
        case ("GET", "/icon.png"), ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"), ("GET", "/favicon.ico"):
            guard let remoteIcon else { return jsonResponse(404, ["error": "not found"]) }
            return httpResponse(status: 200, contentType: "image/png", body: remoteIcon, extraHeaders: ["Cache-Control": "max-age=86400"])
        case ("GET", "/api/time"):
            return jsonResponse(200, ["time": Int(now)])
        case ("GET", "/api/status"), ("POST", "/api/session"), ("POST", "/api/standby"):
            switch authorize(request, secret: remoteSecret, now: now, nonces: &remoteNonces, lockout: &remoteLockout) {
            case .locked: return jsonResponse(429, ["error": "Too many failed attempts. Try again in a few minutes."])
            case .denied(let reason): return jsonResponse(401, ["error": "Not paired", "reason": reason, "time": Int(now)])
            case .ok: break
            }
            if remoteLastSeen == nil || now - (remoteLastSeen ?? 0) > 30 { remoteLastSeen = now; UserDefaults.standard.set(now, forKey: "remoteLastSeen") }
            if request.method == "GET" { tick(); return jsonResponse(200, remoteStatus(now: now)) }
            guard let command = parseRemoteCommand(path: request.path, body: request.body) else { return jsonResponse(400, ["error": "Unknown command"]) }
            return perform(command)
        default:
            return jsonResponse(404, ["error": "not found"])
        }
    }

    func perform(_ command: RemoteCommand) -> Data {
        let lidClosed = rootProperty("AppleClamshellState") ?? false
        switch command {
        case .start(let hours):
            if busy || stopping { return jsonResponse(409, ["error": "LidRunner is busy. Try again in a moment."]) }
            if request != nil, !sessionIsStandby { return jsonResponse(409, ["error": "A session is already running."]) }
            if sessionIsStandby, lidClosed {
                // Switching would briefly restore sleep, and a closed Mac would go to sleep in the gap.
                return jsonResponse(409, ["error": "Your Mac is already staying awake on its charger, so it is ready to use. A timed session can only replace that while the lid is open."])
            }
            lastError = nil; lastErrorAt = nil
            startUserSession(seconds: hours * 3600)
            if request == nil, pendingStart == nil, let lastError { return jsonResponse(409, ["error": lastError]) }
            if authenticating { return jsonResponse(409, ["error": "LidRunner needs a one-time administrator approval at the Mac before it can start sessions."]) }
            return jsonResponse(200, ["ok": true])
        case .stop:
            if sessionIsStandby { UserDefaults.standard.set(false, forKey: "stayReachable") }
            pendingStart = nil
            stop()
            return jsonResponse(200, ["ok": true])
        case .standby(let enabled):
            if enabled, helperVersion < 3 {
                return jsonResponse(409, ["error": "Turn on Stay reachable at the Mac first. It needs a one-time administrator approval there."])
            }
            UserDefaults.standard.set(enabled, forKey: "stayReachable")
            lastStandbyStart = nil
            tick()
            return jsonResponse(200, ["ok": true])
        }
    }

    func remoteStatus(now: Double) -> [String: Any] {
        let v = lastView
        var status: [String: Any] = [
            "name": Host.current().localizedName ?? "Mac",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "state": v.state, "headline": v.headline, "detail": v.detail,
            "charging": v.power.ac, "lidClosed": v.lidClosed, "thermal": v.thermal, "hours": v.hours,
            "standby": ["enabled": standbyEnabled, "available": helperVersion >= 3],
            "time": Int(now),
        ]
        if let percent = v.power.percent { status["battery"] = percent }
        if let remaining = v.remaining, let total = v.total { status["remaining"] = remaining; status["total"] = total }
        if let error = v.error { status["error"] = error }
        status["apps"] = keepers.filter { $0.installedURL != nil }.map { keeper -> [String: Any] in
            var app: [String: Any] = ["name": keeper.app.name, "running": keeper.running]
            switch keeper.app.key {
            case "rustdesk":
                if let rustDeskID { app["link"] = "rustdesk://connection/new/\(rustDeskID)"; app["hint"] = "Remote desktop · ID \(rustDeskID)" }
            case "chatgpt": app["link"] = "https://chatgpt.com/"; app["hint"] = "ChatGPT → Remote"
            case "claude": app["link"] = "https://claude.ai/code"; app["hint"] = "Claude → Remote Control"
            default: break
            }
            return app
        }
        return status
    }

    // MARK: Pairing window

    func pairingLinks() -> [(title: String, host: String)] {
        var links: [(String, String)] = []
        if let name = bonjourHostName() { links.append(("Same Wi-Fi", name)) }
        if let address = tailscaleAddress() { links.append(("Tailscale", address)) }
        return links
    }
    @objc func showPairing() {
        guard remoteSecret != nil || createRemoteSecret() != nil else { return }
        if pairingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pair your phone"; window.isReleasedWhenClosed = false
            pairingImage.imageScaling = .scaleProportionallyUpOrDown
            pairingImage.widthAnchor.constraint(equalToConstant: 240).isActive = true; pairingImage.heightAnchor.constraint(equalToConstant: 240).isActive = true
            pairingImage.setAccessibilityLabel("Pairing QR code")
            pairingPicker.segmentStyle = .rounded; pairingPicker.trackingMode = .selectOne
            pairingPicker.target = self; pairingPicker.action = #selector(pairingTransportChanged)
            pairingLink.font = .monospacedSystemFont(ofSize: 11, weight: .regular); pairingLink.textColor = .secondaryLabelColor
            pairingLink.alignment = .center; pairingLink.isSelectable = true; pairingLink.maximumNumberOfLines = 2
            let intro = wrappingLabel("Scan this with your phone's camera, then use Share → Add to Home Screen to keep it as an app.", size: 13, color: .labelColor)
            intro.alignment = .center
            let note = wrappingLabel("The code is this Mac's pairing secret. Anyone who scans it can start and stop sessions from the same network, so show it only to your own devices. Each network needs its own scan.", size: 11)
            note.alignment = .center
            let reset = NSButton(title: "Reset pairing…", target: self, action: #selector(resetPairing)); reset.bezelStyle = .rounded; reset.controlSize = .small
            let stack = NSStackView(views: [intro, pairingPicker, pairingImage, pairingLink, note, reset])
            stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView(); content.addSubview(stack); window.contentView = content
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                         stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                                         stack.widthAnchor.constraint(equalToConstant: 380)])
            [intro, note, pairingLink].forEach { $0.widthAnchor.constraint(equalToConstant: 332).isActive = true }
            window.center(); pairingWindow = window
        }
        let links = pairingLinks()
        pairingPicker.segmentCount = links.count
        for (index, link) in links.enumerated() { pairingPicker.setLabel(link.title, forSegment: index); pairingPicker.setWidth(120, forSegment: index) }
        pairingPicker.isHidden = links.count < 2
        if pairingPicker.selectedSegment < 0 || pairingPicker.selectedSegment >= links.count { pairingPicker.selectedSegment = 0 }
        pairingTransportChanged()
        pairingWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func pairingTransportChanged() {
        let links = pairingLinks()
        guard let secret = remoteSecret, !links.isEmpty else {
            pairingImage.image = nil; pairingLink.stringValue = "This Mac has no network name yet. Connect to Wi-Fi and reopen this window."; return
        }
        let link = links[min(max(pairingPicker.selectedSegment, 0), links.count - 1)]
        let base = "http://\(link.host):\(remotePort)/"
        pairingImage.image = qrImage(base + "#k=" + hex(secret))
        pairingLink.stringValue = base
        pairingWindow?.contentView?.layoutSubtreeIfNeeded()
        if let size = pairingWindow?.contentView?.fittingSize { pairingWindow?.setContentSize(size) }
    }
    @objc func resetPairing() {
        let alert = NSAlert()
        alert.messageText = "Reset the pairing code?"
        alert.informativeText = "Every phone paired with this Mac stops working until it scans the new code."
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createRemoteSecret(); pairingTransportChanged(); tick()
    }
    func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Scale by a whole number so every module stays a crisp square.
        let scale = max(1, floor(960 / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        let size = NSSize(width: scaled.extent.width + 2 * 4 * scale, height: scaled.extent.height + 2 * 4 * scale)
        let image = NSImage(size: size)
        image.lockFocus() // white quiet zone, so it scans in dark mode too
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cg, size: scaled.extent.size).draw(in: NSRect(x: 4 * scale, y: 4 * scale, width: scaled.extent.width, height: scaled.extent.height))
        image.unlockFocus()
        return image
    }
}
