import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

let service = "com.anmolbhatia.lidrunner"
let systemDir = "/Library/Application Support/LidRunner"
let helperPath = "/Library/PrivilegedHelperTools/\(service)"
let daemonPath = "/Library/LaunchDaemons/\(service).plist"
let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LidRunner")

@discardableResult
func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
func bootID() -> String { run("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"]).1.trimmingCharacters(in: .whitespacesAndNewlines) }
func sleepDisabled() -> Int? {
    let output = run("/usr/bin/pmset", ["-g"]).1
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.first == "SleepDisabled", parts.count == 2 { return Int(parts[1]) }
    }
    return nil
}
func rootProperty(_ key: String) -> Bool? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { return nil }; defer { IOObjectRelease(entry) }
    return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}
struct Power: Codable {
    var percent: Int?; var ac: Bool
}
func power() -> Power {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return Power(percent: nil, ac: false) }
    for source in list {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let current = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return Power(percent: current * 100 / max, ac: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }
    return Power(percent: nil, ac: false)
}
struct Request: Codable {
    var token: String; var uid: UInt32; var pid: Int32; var boot: String
    var created: Double; var seconds: Int; var heartbeat: String
    // Helper protocol 3: a "stay reachable" session that only holds while on the charger.
    var acOnly: Bool? = nil
}
/// Normal sessions stay bounded at eight hours. A charger-only session may run for a week,
/// because the helper itself ends it two minutes after the charger is disconnected.
let standbyUnplugGrace = 120.0
func maxSessionSeconds(acOnly: Bool) -> Int { acOnly ? 7 * 86400 : 28800 }
func standbyStopReason(acOnly: Bool, onCharger: Bool, unpluggedFor: Double?) -> String? {
    guard acOnly, !onCharger, let unpluggedFor, unpluggedFor >= standbyUnplugGrace else { return nil }
    return "Charger disconnected"
}
struct Heartbeat: Codable { var token: String; var time: Double; var stop: Bool }
struct Status: Codable {
    var token: String; var phase: String; var reason: String; var updated: Double
    var deadline: Double; var previous: Int
}
func readJSON<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
func writeJSON<T: Encodable>(_ object: T, _ path: String) throws {
    let data = try JSONEncoder().encode(object)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
func stopReason(now: Double, deadline: Double, heartbeat: Heartbeat?, token: String,
                alive: Bool, battery: Power, thermal: Int) -> String? {
    if now >= deadline { return "Session timer finished" }
    if !alive { return "LidRunner closed" }
    guard let h = heartbeat, h.token == token, now - h.time < 20, h.time - now < 5 else { return "LidRunner heartbeat lost" }
    if h.stop { return "Stopped by user" }
    if !battery.ac {
        guard let percent = battery.percent else { return "Battery reading unavailable" }
        if percent <= 15 { return "Battery reached 15%" }
    }
    if thermal >= 2 { return "Mac is under high thermal pressure" }
    return nil
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

struct HelperConfig: Codable {
    var version: Int; var uid: UInt32; var requestPath: String; var heartbeatPath: String
}

// Apps LidRunner can keep available during a session: AI agents, remote-desktop tools, and any
// app the user adds. Gemini is both the Gemini app and Google Antigravity; the IDE is excluded
// from capture moves only.
struct AgentApp {
    let key: String; let name: String; let bundleID: String
    let defaultsKey: String
    // ChatGPT keeps its 1.1 behaviour (opened even if closed at session start). The others are
    // only reopened if they were running earlier in this session, so unused apps never launch.
    let launchIfNeverSeen: Bool
    var custom = false
}
let agentApps: [AgentApp] = [
    AgentApp(key: "chatgpt", name: "ChatGPT", bundleID: "com.openai.codex", defaultsKey: "keepChatGPTAvailable", launchIfNeverSeen: true),
    AgentApp(key: "claude", name: "Claude", bundleID: "com.anthropic.claudefordesktop", defaultsKey: "keepClaudeAvailable", launchIfNeverSeen: false),
    AgentApp(key: "gemini", name: "Gemini", bundleID: "com.google.GeminiMacOS", defaultsKey: "keepGeminiAvailable", launchIfNeverSeen: false),
    AgentApp(key: "antigravity", name: "Antigravity", bundleID: "com.google.antigravity", defaultsKey: "keepAntigravityAvailable", launchIfNeverSeen: false),
    AgentApp(key: "rustdesk", name: "RustDesk", bundleID: "com.carriez.rustdesk", defaultsKey: "keepRustDeskAvailable", launchIfNeverSeen: false),
]
/// Apps added with "Add app…", stored as [["name": ..., "bundleID": ...]]. They get the cautious
/// keep-alive rule (reopened only if seen running this session) and are never launched otherwise.
func customApps(from stored: Any?) -> [AgentApp] {
    guard let rows = stored as? [[String: String]] else { return [] }
    var seen = Set(agentApps.map(\.bundleID)), result: [AgentApp] = []
    for row in rows.prefix(12) {
        guard let name = row["name"], let id = row["bundleID"], !name.isEmpty, name.count <= 60,
              id.count <= 200, id.contains("."), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
              seen.insert(id).inserted else { continue }
        result.append(AgentApp(key: "custom:" + id, name: name, bundleID: id, defaultsKey: "keepCustom." + id, launchIfNeverSeen: false, custom: true))
    }
    return result
}
// Capture Guard never moves an agent's own windows.
let agentBundleIDs: Set<String> = Set(agentApps.map(\.bundleID)).union(["com.google.antigravity-ide"])

// Only keep an agent app available inside a user-enabled sleep session.
// Debounce process-list gaps and cap retries instead of relaunching in a loop.
func shouldReopenAgentApp(active: Bool, enabled: Bool, running: Bool, launching: Bool,
                          now: Double, missingSince: Double?, lastAttempt: Double?, attempts: Int,
                          seenThisSession: Bool = true, launchIfNeverSeen: Bool = true) -> Bool {
    guard active, enabled, !running, !launching, attempts < 3, launchIfNeverSeen || seenThisSession,
          let missingSince, now - missingSince >= 15 else { return false }
    return lastAttempt == nil || now - lastAttempt! >= 60
}

// MARK: - 1.4 policy helpers (pure, covered by Tests/PolicyTests.swift)

let sessionLengths = [1, 2, 4, 8]
/// The remembered session length, clamped to a supported value (default 8 hours).
func sessionSeconds(storedHours: Int) -> Int {
    (sessionLengths.contains(storedHours) ? storedHours : 8) * 3600
}

/// The sampling history is evidence for sessions, not an idle activity log: record every
/// sample while a session is active, otherwise only state changes plus a slow keep-alive.
func shouldAppendSample(now: Double, lastAppend: Double?, sessionActive: Bool, changed: Bool) -> Bool {
    if sessionActive || changed { return true }
    guard let lastAppend else { return true }
    return now - lastAppend >= 60 || now < lastAppend
}

/// A session that was running and ended without the user stopping it deserves an
/// explanation the next time they look at the Mac. Returns the reason to show, or nil.
func sessionEndNotice(wasActive: Bool, phase: String, reason: String, userStopping: Bool) -> String? {
    guard wasActive, !userStopping, phase == "stopped" || phase == "failed" else { return nil }
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "Stopped by user" { return nil }
    return trimmed
}

/// A stale start error should not label the window forever.
func errorStillRelevant(now: Double, shownAt: Double?) -> Bool {
    guard let shownAt else { return false }
    return now - shownAt < 120 && now >= shownAt - 5
}

/// What the main window says about the optional Capture Guard companion.
enum GuardState: Equatable {
    case notInstalled, notRunning, needsPermission, paused
    case ready(String)
}
func captureGuardState(installed: Bool, report: [String: Any]?, now: Double) -> GuardState {
    guard installed else { return .notInstalled }
    guard let report, let time = report["time"] as? Double, now - time < 10, now - time > -5 else { return .notRunning }
    if report["accessibilityTrusted"] as? Bool != true { return .needsPermission }
    if report["enabled"] as? Bool == false { return .paused }
    let repairs = report["repairs"] as? Int ?? 0
    let shared = report["sharedWindows"] as? Int ?? 0
    if shared > 0 { return .ready("Watching \(shared) shared window\(shared == 1 ? "" : "s")") }
    if report["sessionEligible"] as? Bool == true {
        return .ready(repairs > 0 ? "Active · \(repairs) window\(repairs == 1 ? "" : "s") re-centred" : "Active · no shared windows yet")
    }
    return .ready("Ready · works when the lid is closed in a session")
}

/// The heartbeat is written off the main thread so an open menu or a briefly busy UI cannot
/// end a session (1.3 lost a session this way). It still stops if the UI stays unresponsive
/// for ten minutes, so a truly hung app cannot hold the Mac awake until the deadline.
let mainThreadStallLimit = 600.0
func heartbeatShouldContinue(now: Double, lastMainTick: Double) -> Bool {
    now - lastMainTick < mainThreadStallLimit && now >= lastMainTick - 5
}

/// Plain-language account of why the previous session ended.
func lastSessionSentence(_ reason: String) -> String {
    switch reason.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "Stopped by user": return "Last session: you stopped it."
    case "Session timer finished": return "Last session ran its full time."
    case "Battery reached 15%": return "Last session stopped at 15% battery."
    case "Battery reading unavailable": return "Last session stopped because the battery level couldn't be read."
    case "Mac is under high thermal pressure": return "Last session stopped because the Mac got too hot."
    case "LidRunner closed": return "Last session stopped when LidRunner quit."
    case "LidRunner heartbeat lost": return "Last session stopped because LidRunner stopped responding."
    case "Power setting changed outside LidRunner": return "Last session stopped because something else changed the sleep setting."
    case "Charger disconnected": return "Stay reachable ended because the charger was disconnected."
    case "Recovered interrupted session": return "Last session was interrupted by a restart or crash; normal sleep was restored."
    case let other:
        let text = other.hasSuffix(".") ? String(other.dropLast()) : other
        return text.isEmpty ? "Last session ended." : "Last session: \(text)."
    }
}

// MARK: - 1.5 stay reachable on charger

enum StandbyAction: Equatable { case none, start, stop }
/// "Stay reachable on charger": while plugged in, hold a charger-only session so the Mac stays
/// awake with the lid closed and the phone can reach it. Only ever touches sessions it started.
func standbyAction(enabled: Bool, onCharger: Bool, sessionRequested: Bool, sessionIsStandby: Bool, busy: Bool,
                   thermal: Int, lidClosed: Bool, remaining: Int?, now: Double, lastStart: Double?) -> StandbyAction {
    if sessionRequested {
        guard sessionIsStandby, !busy else { return .none }
        if !enabled { return .stop }
        // Renew a long-running hold while the lid is open, when stopping cannot put the Mac to sleep.
        if !lidClosed, onCharger, let remaining, remaining < 86400 { return .stop }
        return .none
    }
    guard enabled, onCharger, !busy, thermal < 2 else { return .none }
    if let lastStart, now - lastStart < 30, now >= lastStart { return .none }
    return .start
}
