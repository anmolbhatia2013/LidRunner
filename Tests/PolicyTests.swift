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
        check(agentApps.filter { !$0.launchIfNeverSeen }.map(\.key) == ["claude", "gemini", "antigravity"])
        check(Set(agentApps.map(\.bundleID)).count == agentApps.count && Set(agentApps.map(\.defaultsKey)).count == agentApps.count)
        check(agentBundleIDs.contains("com.anthropic.claudefordesktop") && agentBundleIDs.contains("com.google.antigravity-ide"))
        print("\(count) policy checks passed")
    }
}
