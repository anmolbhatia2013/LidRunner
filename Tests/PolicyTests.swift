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
        print("\(count) policy checks passed")
    }
}
