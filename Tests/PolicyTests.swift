import Foundation
@main struct Tests {
    static func main() {
        let h = Heartbeat(token: "test", time: 100, stop: false)
        func reason(_ now: Double = 100, _ deadline: Double = 200, _ heartbeat: Heartbeat? = h,
                    _ alive: Bool = true, _ battery: Power = Power(percent: 50, ac: false), _ thermal: Int = 0) -> String? {
            stopReason(now: now, deadline: deadline, heartbeat: heartbeat, token: "test", alive: alive, battery: battery, thermal: thermal)
        }
        var count = 0
        func check(_ v: Bool) { precondition(v, "Policy case \(count + 1) failed"); count += 1 }
        check(reason() == nil)
        check(reason(200) == "Session timer finished")
        check(reason(100, 200, h, false) == "LidRunner closed")
        check(reason(100, 200, nil) == "LidRunner heartbeat lost")
        check(reason(120) == "LidRunner heartbeat lost")
        check(reason(94) == "LidRunner heartbeat lost")
        check(reason(100, 200, Heartbeat(token: "other", time: 100, stop: false)) == "LidRunner heartbeat lost")
        check(reason(100, 200, Heartbeat(token: "test", time: 100, stop: true)) == "Stopped by user")
        check(reason(100, 200, h, true, Power(percent: 15, ac: false)) == "Battery reached 15%")
        check(reason(100, 200, h, true, Power(percent: 16, ac: false)) == nil)
        check(reason(100, 200, h, true, Power(percent: 3, ac: true)) == nil)
        check(reason(100, 200, h, true, Power(percent: nil, ac: false)) == "Battery reading unavailable")
        check(reason(100, 200, h, true, Power(percent: 80, ac: true), 2) == "Mac is under high thermal pressure")
        check(reason(100, 200, h, true, Power(percent: 80, ac: true), 3) == "Mac is under high thermal pressure")
        check(reason(100, 200, h, true, Power(percent: 80, ac: true), 1) == nil)
        check(shellQuote("a'b") == "'a'\\''b'")
        func reopen(active: Bool = true, enabled: Bool = true, running: Bool = false, launching: Bool = false,
                    now: Double = 120, missing: Double? = 100, last: Double? = nil, attempts: Int = 0,
                    seen: Bool = true, launchIfNeverSeen: Bool = true) -> Bool {
            shouldReopenAgentApp(active: active, enabled: enabled, running: running, launching: launching,
                                 now: now, missingSince: missing, lastAttempt: last, attempts: attempts,
                                 seenThisSession: seen, launchIfNeverSeen: launchIfNeverSeen)
        }
        check(!reopen(active: false)) // An expired/stopped session must not reopen a deliberately closed app.
        check(!reopen(enabled: false))
        check(!reopen(running: true))
        check(!reopen(launching: true))
        check(!reopen(now: 102)) // A brief process-list omission previously caused an early stop.
        check(!reopen(missing: nil))
        check(reopen())
        check(!reopen(last: 110))
        check(reopen(now: 180, last: 120, attempts: 2))
        check(!reopen(attempts: 3)) // Repeated launch failure is bounded.
        // Multi-agent: ChatGPT keeps 1.1 behaviour; Claude/Gemini/Antigravity reopen only if seen this session.
        check(reopen(seen: false, launchIfNeverSeen: true))
        check(!reopen(seen: false, launchIfNeverSeen: false)) // Never launch an agent the user wasn't using.
        check(reopen(seen: true, launchIfNeverSeen: false))
        check(!reopen(active: false, seen: true, launchIfNeverSeen: false))
        check(agentApps.first?.bundleID == "com.openai.codex" && agentApps.first?.defaultsKey == "keepChatGPTAvailable")
        check(agentApps.filter { !$0.launchIfNeverSeen }.map(\.key) == ["claude", "gemini", "antigravity", "rustdesk"])
        check(Set(agentApps.map(\.bundleID)).count == agentApps.count && Set(agentApps.map(\.defaultsKey)).count == agentApps.count)
        check(agentBundleIDs.contains("com.anthropic.claudefordesktop") && agentBundleIDs.contains("com.google.antigravity-ide"))
        // 1.4: remembered session length
        check(sessionSeconds(storedHours: 2) == 7200)
        check(sessionSeconds(storedHours: 0) == 28800 && sessionSeconds(storedHours: 3) == 28800 && sessionSeconds(storedHours: 99) == 28800)
        // 1.4: sampling history is throttled while idle
        check(shouldAppendSample(now: 10, lastAppend: 8, sessionActive: true, changed: false))
        check(shouldAppendSample(now: 10, lastAppend: 8, sessionActive: false, changed: true))
        check(!shouldAppendSample(now: 10, lastAppend: 8, sessionActive: false, changed: false))
        check(shouldAppendSample(now: 70, lastAppend: 8, sessionActive: false, changed: false))
        check(shouldAppendSample(now: 10, lastAppend: nil, sessionActive: false, changed: false))
        check(shouldAppendSample(now: 5, lastAppend: 8, sessionActive: false, changed: false)) // clock moved backwards
        // 1.4: explain sessions that ended on their own, never ones the user stopped
        check(sessionEndNotice(wasActive: true, phase: "stopped", reason: "Battery reached 15%", userStopping: false) == "Battery reached 15%")
        check(sessionEndNotice(wasActive: true, phase: "stopped", reason: "Session timer finished", userStopping: false) == "Session timer finished")
        check(sessionEndNotice(wasActive: true, phase: "stopped", reason: "Stopped by user", userStopping: false) == nil)
        check(sessionEndNotice(wasActive: true, phase: "stopped", reason: "LidRunner closed", userStopping: true) == nil)
        check(sessionEndNotice(wasActive: false, phase: "failed", reason: "Sleep is already disabled", userStopping: false) == nil) // never started: shown in the window instead
        check(sessionEndNotice(wasActive: true, phase: "active", reason: "x", userStopping: false) == nil)
        check(sessionEndNotice(wasActive: true, phase: "stopped", reason: "  ", userStopping: false) == nil)
        // 1.4: start errors expire
        check(errorStillRelevant(now: 100, shownAt: 50) && !errorStillRelevant(now: 300, shownAt: 50) && !errorStillRelevant(now: 100, shownAt: nil))
        // 1.4: Capture Guard summary
        func guardState(_ installed: Bool = true, _ report: [String: Any]? = ["time": 100.0, "accessibilityTrusted": true, "sessionEligible": false, "repairs": 0], _ now: Double = 101) -> GuardState {
            captureGuardState(installed: installed, report: report, now: now)
        }
        check(guardState(false) == .notInstalled)
        check(guardState(true, nil) == .notRunning)
        check(guardState(true, ["time": 80.0, "accessibilityTrusted": true]) == .notRunning) // stale file
        check(guardState(true, ["time": 100.0, "accessibilityTrusted": false]) == .needsPermission)
        check(guardState(true, ["time": 100.0]) == .needsPermission) // missing key is not trust
        check(guardState(true, ["time": 100.0, "accessibilityTrusted": true, "enabled": false]) == .paused)
        check(guardState() == .ready("Ready · works when the lid is closed in a session"))
        check(guardState(true, ["time": 100.0, "accessibilityTrusted": true, "sessionEligible": true, "sharedWindows": 1]) == .ready("Watching 1 shared window"))
        check(guardState(true, ["time": 100.0, "accessibilityTrusted": true, "sessionEligible": true, "repairs": 2]) == .ready("Active · 2 windows re-centred"))
        // 1.4: heartbeat survives short UI stalls (open menus), not a hung app
        check(heartbeatShouldContinue(now: 100, lastMainTick: 98))
        check(heartbeatShouldContinue(now: 100 + 134, lastMainTick: 100)) // the 134 s stall that ended a 1.3 session
        check(!heartbeatShouldContinue(now: 100 + 600, lastMainTick: 100))
        check(!heartbeatShouldContinue(now: 50, lastMainTick: 100)) // clock moved backwards
        check(lastSessionSentence("Battery reached 15%") == "Last session stopped at 15% battery.")
        check(lastSessionSentence("LidRunner heartbeat lost") == "Last session stopped because LidRunner stopped responding.")
        check(lastSessionSentence("Sleep is already disabled. No changes made.") == "Last session: Sleep is already disabled. No changes made.")
        check(lastSessionSentence("  ") == "Last session ended.")
        // 1.5: apps added by the user
        let custom = customApps(from: [["name": "Henge", "bundleID": "com.example.henge"], ["name": "Dup", "bundleID": "com.example.henge"],
                                       ["name": "Claude again", "bundleID": "com.anthropic.claudefordesktop"], ["name": "", "bundleID": "a.b"],
                                       ["name": "Bad", "bundleID": "no spaces.allowed"], ["name": "NoDot", "bundleID": "nodot"]])
        check(custom.map(\.bundleID) == ["com.example.henge"] && custom[0].custom && !custom[0].launchIfNeverSeen && custom[0].defaultsKey == "keepCustom.com.example.henge")
        check(customApps(from: nil).isEmpty && customApps(from: "junk").isEmpty && customApps(from: [["name": 1]]).isEmpty)
        check(customApps(from: (0..<40).map { ["name": "A\($0)", "bundleID": "com.example.a\($0)"] }).count == 12)
        check(agentBundleIDs.contains("com.carriez.rustdesk"))
        // 1.5: charger-only "stay reachable" sessions
        check(maxSessionSeconds(acOnly: false) == 28800 && maxSessionSeconds(acOnly: true) == 604800)
        check(standbyStopReason(acOnly: true, onCharger: false, unpluggedFor: 120) == "Charger disconnected")
        check(standbyStopReason(acOnly: true, onCharger: false, unpluggedFor: 119) == nil) // brief unplug tolerated
        check(standbyStopReason(acOnly: true, onCharger: true, unpluggedFor: 500) == nil)
        check(standbyStopReason(acOnly: false, onCharger: false, unpluggedFor: 9999) == nil) // normal sessions run on battery
        check(standbyStopReason(acOnly: true, onCharger: false, unpluggedFor: nil) == nil)
        func standby(enabled: Bool = true, charger: Bool = true, requested: Bool = false, isStandby: Bool = false, busy: Bool = false,
                     thermal: Int = 0, closed: Bool = false, remaining: Int? = nil, now: Double = 1000, last: Double? = nil) -> StandbyAction {
            standbyAction(enabled: enabled, onCharger: charger, sessionRequested: requested, sessionIsStandby: isStandby, busy: busy,
                          thermal: thermal, lidClosed: closed, remaining: remaining, now: now, lastStart: last)
        }
        check(standby() == .start)
        check(standby(enabled: false) == .none && standby(charger: false) == .none && standby(busy: true) == .none && standby(thermal: 2) == .none)
        check(standby(last: 990) == .none && standby(last: 960) == .start) // back off between attempts
        check(standby(requested: true, isStandby: false) == .none) // never touches a session the user started
        check(standby(enabled: false, requested: true, isStandby: false) == .none)
        check(standby(enabled: false, requested: true, isStandby: true) == .stop)
        check(standby(requested: true, isStandby: true, remaining: 500000) == .none)
        check(standby(requested: true, isStandby: true, closed: false, remaining: 3600) == .stop) // renew while the lid is open
        check(standby(requested: true, isStandby: true, closed: true, remaining: 3600) == .none)  // never stop with the lid closed
        check(standby(charger: false, requested: true, isStandby: true) == .none) // the helper enforces the unplug limit
        check(lastSessionSentence("Charger disconnected") == "Stay reachable ended because the charger was disconnected.")
        // 1.5: phone remote, HTTP parsing
        func parse(_ text: String) -> HTTPParse { parseHTTPRequest(Data(text.utf8)) }
        check(parse("GET /api/status HTTP/1.1\r\nHost: x\r\n") == .incomplete)
        if case .ok(let r) = parse("GET /api/status?x=1 HTTP/1.1\r\nHost: mac\r\nX-LR-Time: 5\r\n\r\n") {
            check(r.method == "GET" && r.path == "/api/status" && r.headers["x-lr-time"] == "5" && r.body.isEmpty)
        } else { check(false) }
        if case .ok(let r) = parse("POST /api/session HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}extra") { check(r.body == Data("{}".utf8)) } else { check(false) }
        check(parse("POST /api/session HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}") == .incomplete)
        check(parse("DELETE / HTTP/1.1\r\n\r\n") == .bad(405))
        check(parse("GET /../etc/passwd HTTP/1.1\r\n\r\n") == .bad(400))
        check(parse("GET / HTTP/2\r\n\r\n") == .bad(400) && parse("garbage\r\n\r\n") == .bad(400))
        check(parse("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n") == .bad(413))
        check(parse("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .bad(400) && parse("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab") == .bad(400))
        check(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .bad(400))
        check(parse("GET / HTTP/1.1\r\n" + String(repeating: "A: b\r\n", count: 3000)) == .bad(431))
        check(String(data: httpResponse(status: 200, body: Data("{}".utf8)), encoding: .utf8)!.hasPrefix("HTTP/1.1 200 OK\r\n"))
        // 1.5: phone remote, signed requests
        let secret = Data((0..<32).map { UInt8($0) })
        func signed(_ method: String, _ path: String, body: String = "", time: Double = 1000, nonce: String = "00112233445566778899aabbccddeeff", key: Data? = nil) -> HTTPRequest {
            let t = String(Int(time)), b = Data(body.utf8)
            let sign = remoteSignature(secret: key ?? secret, method: method, path: path, time: t, nonce: nonce, body: b)
            return HTTPRequest(method: method, path: path, headers: ["x-lr-time": t, "x-lr-nonce": nonce, "x-lr-sign": sign], body: b)
        }
        // Known-answer vector shared with the web page's own HMAC implementation.
        check(remoteSignature(secret: secret, method: "GET", path: "/api/status", time: "1000", nonce: "00112233445566778899aabbccddeeff", body: Data()) == "cd80e3608337f5fa627ff66f2d2b04b5baa54ae9d7c80ac8b3f1d979cfea8377")
        var nonces = NonceCache(), lock = Lockout()
        check(authorize(signed("GET", "/api/status"), secret: secret, now: 1000, nonces: &nonces, lockout: &lock) == .ok)
        check(authorize(signed("GET", "/api/status"), secret: secret, now: 1001, nonces: &nonces, lockout: &lock) == .denied("replay"))
        check(authorize(signed("GET", "/api/status", nonce: "aa112233445566778899aabbccddeeff"), secret: secret, now: 1000 + 91, nonces: &nonces, lockout: &lock) == .denied("clock"))
        check(authorize(signed("GET", "/api/status", nonce: "bb112233445566778899aabbccddeeff", key: Data(repeating: 9, count: 32)), secret: secret, now: 1000, nonces: &nonces, lockout: &lock) == .denied("signature"))
        var tampered = signed("POST", "/api/session", body: "{\"action\":\"stop\"}", nonce: "cc112233445566778899aabbccddeeff")
        tampered.body = Data("{\"action\":\"start\",\"hours\":8}".utf8)
        check(authorize(tampered, secret: secret, now: 1000, nonces: &nonces, lockout: &lock) == .denied("signature"))
        var moved = signed("POST", "/api/session", body: "{\"action\":\"stop\"}", nonce: "dd112233445566778899aabbccddeeff"); moved.path = "/api/standby"
        check(authorize(moved, secret: secret, now: 1000, nonces: &nonces, lockout: &lock) == .denied("signature"))
        check(authorize(HTTPRequest(method: "GET", path: "/api/status", headers: [:], body: Data()), secret: secret, now: 1000, nonces: &nonces, lockout: &lock) == .denied("unsigned"))
        check(authorize(signed("GET", "/api/status", nonce: "ee112233445566778899aabbccddeeff"), secret: nil, now: 1000, nonces: &nonces, lockout: &lock) == .denied("not paired"))
        check(authorize(signed("GET", "/api/status", nonce: "ff112233445566778899aabbccddeeff"), secret: Data(repeating: 1, count: 8), now: 1000, nonces: &nonces, lockout: &lock) == .denied("not paired"))
        var guessLock = Lockout(), guessNonces = NonceCache()
        for i in 0..<20 { _ = authorize(signed("GET", "/api/status", nonce: String(format: "%032x", i), key: Data(repeating: 7, count: 32)), secret: secret, now: 2000, nonces: &guessNonces, lockout: &guessLock) }
        check(authorize(signed("GET", "/api/status", time: 2001), secret: secret, now: 2001, nonces: &guessNonces, lockout: &guessLock) == .locked) // even a valid request waits
        check(authorize(signed("GET", "/api/status", time: 2302), secret: secret, now: 2302, nonces: &guessNonces, lockout: &guessLock) == .ok)
        // 1.5: phone remote, who may connect
        check(remoteAddressAllowed([127, 0, 0, 1]) && remoteAddressAllowed([192, 168, 10, 5]) && remoteAddressAllowed([10, 1, 2, 3]) && remoteAddressAllowed([172, 20, 0, 1]))
        check(remoteAddressAllowed([100, 64, 255, 122]) && remoteAddressAllowed([100, 127, 0, 1]) && remoteAddressAllowed([169, 254, 1, 1]))
        check(!remoteAddressAllowed([8, 8, 8, 8]) && !remoteAddressAllowed([100, 128, 0, 1]) && !remoteAddressAllowed([172, 32, 0, 1]) && !remoteAddressAllowed([192, 169, 0, 1]) && !remoteAddressAllowed([]))
        check(remoteAddressAllowed([UInt8](repeating: 0, count: 15) + [1]) && remoteAddressAllowed([0xfe, 0x80] + [UInt8](repeating: 0, count: 14)) && remoteAddressAllowed([0xfd, 0x7a, 0x11, 0x5c] + [UInt8](repeating: 1, count: 12)))
        check(!remoteAddressAllowed([0x20, 0x01, 0x48, 0x60] + [UInt8](repeating: 0, count: 12)))
        check(remoteAddressAllowed([UInt8](repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 1, 1]) && !remoteAddressAllowed([UInt8](repeating: 0, count: 10) + [0xff, 0xff, 8, 8, 8, 8]))
        // 1.5: phone remote, the whole command surface
        func command(_ path: String, _ body: String) -> RemoteCommand? { parseRemoteCommand(path: path, body: Data(body.utf8)) }
        check(command("/api/session", "{\"action\":\"start\",\"hours\":4}") == .start(hours: 4) && command("/api/session", "{\"action\":\"start\",\"hours\":1}") == .start(hours: 1))
        check(command("/api/session", "{\"action\":\"stop\"}") == .stop)
        check(command("/api/standby", "{\"enabled\":true}") == .standby(true) && command("/api/standby", "{\"enabled\":false}") == .standby(false))
        check(command("/api/session", "{\"action\":\"start\",\"hours\":3}") == nil && command("/api/session", "{\"action\":\"start\",\"hours\":999}") == nil)
        check(command("/api/session", "{\"action\":\"start\",\"hours\":true}") == nil && command("/api/session", "{\"action\":\"start\",\"hours\":\"8\"}") == nil)
        check(command("/api/session", "{\"action\":\"start\",\"hours\":8,\"command\":\"rm\"}") == nil && command("/api/session", "{\"action\":\"run\"}") == nil)
        check(command("/api/standby", "{\"enabled\":1}") == nil && command("/api/other", "{\"action\":\"stop\"}") == nil && command("/api/session", "not json") == nil && command("/api/session", "[]") == nil)
        print("\(count) policy checks passed")
    }
}
