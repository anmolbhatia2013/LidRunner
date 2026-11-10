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

// Agent host apps LidRunner can keep available during a session. Gemini on this Mac is
// both the Gemini app and Google Antigravity; the IDE is excluded from capture moves only.
struct AgentApp {
    let key: String; let name: String; let bundleID: String
    let defaultsKey: String
    // ChatGPT keeps its 1.1 behaviour (opened even if closed at session start). The others are
    // only reopened if they were running earlier in this session, so unused apps never launch.
    let launchIfNeverSeen: Bool
}
let agentApps: [AgentApp] = [
    AgentApp(key: "chatgpt", name: "ChatGPT", bundleID: "com.openai.codex", defaultsKey: "keepChatGPTAvailable", launchIfNeverSeen: true),
    AgentApp(key: "claude", name: "Claude", bundleID: "com.anthropic.claudefordesktop", defaultsKey: "keepClaudeAvailable", launchIfNeverSeen: false),
    AgentApp(key: "gemini", name: "Gemini", bundleID: "com.google.GeminiMacOS", defaultsKey: "keepGeminiAvailable", launchIfNeverSeen: false),
    AgentApp(key: "antigravity", name: "Antigravity", bundleID: "com.google.antigravity", defaultsKey: "keepAntigravityAvailable", launchIfNeverSeen: false),
]
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
