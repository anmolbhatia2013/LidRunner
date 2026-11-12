import Foundation
import Darwin

@main struct Guardian {
    static func main() {
        guard getuid() == 0 else { fputs("Guardian must be launched by macOS as root.\n", stderr); exit(1) }
        umask(0o022)
        let statusPath = systemDir + "/status.json"
        // After a helper crash or reboot, restore first. Never resume the old request.
        if var prior = readJSON(Status.self, statusPath), ["active", "restoring"].contains(prior.phase) {
            restore(&prior, "Recovered interrupted session", statusPath)
        }
        guard let config = readJSON(HelperConfig.self, systemDir + "/config.json"), (2...3).contains(config.version), config.uid >= 501 else { exit(1) }
        while true {
            if var r = safeRead(Request.self, config.requestPath, config.uid) {
                // The administrator-approved configuration fixes every user-controlled path.
                // This service can only change the bounded sleep override; it executes no user commands.
                r.heartbeat = config.heartbeatPath
                let previous = readJSON(Status.self, statusPath)
                if previous?.token != r.token {
                    session(r, config.uid, statusPath)
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
    static func session(_ r: Request, _ uid: UInt32, _ statusPath: String) {
        let now = Date().timeIntervalSince1970
        var s = Status(token: r.token, phase: "failed", reason: "Session request expired or invalid", updated: now, deadline: r.created + Double(r.seconds), previous: 0)
        func save() { try? writeJSON(s, statusPath) }
        let acOnly = r.acOnly == true
        guard r.boot == bootID(), r.uid == uid, r.pid > 1, r.seconds >= 30, r.seconds <= maxSessionSeconds(acOnly: acOnly),
              now - r.created < 300, now >= r.created, UUID(uuidString: r.token) != nil else { save(); return }
        guard sleepDisabled() == 0 else {
            s.reason = "Sleep is already disabled, or its setting could not be read. No changes made."; save(); return
        }
        if let reason = stopReason(now: now, deadline: s.deadline, heartbeat: safeRead(Heartbeat.self, r.heartbeat, uid), token: r.token,
                                   alive: kill(r.pid, 0) == 0, battery: power(), thermal: ProcessInfo.processInfo.thermalState.rawValue) {
            s.reason = reason; save(); return
        }
        if acOnly && !power().ac { s.reason = "Stay reachable needs the charger"; save(); return }
        s.phase = "active"; s.reason = acOnly ? "Staying reachable on charger" : "Closed-lid sleep override enabled"
        do { try writeJSON(s, statusPath) } catch { exit(1) }
        guard run("/usr/bin/pmset", ["-a", "disablesleep", "1"]).0 == 0, sleepDisabled() == 1 else {
            restore(&s, "Could not enable closed-lid override", statusPath); return
        }
        let monotonicDeadline = ProcessInfo.processInfo.systemUptime + Double(r.seconds)
        var unpluggedSince: Double?
        while true {
            let t = Date().timeIntervalSince1970
            let battery = power()
            let reason = stopReason(now: t, deadline: s.deadline, heartbeat: safeRead(Heartbeat.self, r.heartbeat, uid), token: r.token,
                                    alive: kill(r.pid, 0) == 0, battery: battery, thermal: ProcessInfo.processInfo.thermalState.rawValue)
            if let reason { restore(&s, reason, statusPath); return }
            // A charger-only session ends by itself shortly after the charger is disconnected.
            if battery.ac { unpluggedSince = nil } else if unpluggedSince == nil || t < unpluggedSince! { unpluggedSince = t }
            if let reason = standbyStopReason(acOnly: acOnly, onCharger: battery.ac, unpluggedFor: unpluggedSince.map { t - $0 }) {
                restore(&s, reason, statusPath); return
            }
            if ProcessInfo.processInfo.systemUptime >= monotonicDeadline { restore(&s, "Session timer finished", statusPath); return }
            if rootProperty("SleepDisabled") != true { restore(&s, "Power setting changed outside LidRunner", statusPath); return }
            s.updated = t; save(); Thread.sleep(forTimeInterval: 2)
        }
    }
    static func safeRead<T: Decodable>(_ type: T.Type, _ path: String, _ uid: UInt32) -> T? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var statbuf = stat()
        guard fstat(fd, &statbuf) == 0, statbuf.st_uid == uid,
              (statbuf.st_mode & S_IFMT) == S_IFREG, statbuf.st_size <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &buffer, 4097)
        guard count > 0, count <= 4096 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(buffer.prefix(count)))
    }
    static func restore(_ s: inout Status, _ reason: String, _ path: String) {
        s.phase = "restoring"; s.reason = reason; s.updated = Date().timeIntervalSince1970
        try? writeJSON(s, path)
        for _ in 0..<3 {
            if run("/usr/bin/pmset", ["-a", "disablesleep", String(s.previous)]).0 == 0, sleepDisabled() == s.previous {
                s.phase = "stopped"; s.updated = Date().timeIntervalSince1970
                do { try writeJSON(s, path) } catch { exit(1) }
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        exit(1) // launchd retries a failed restoration.
    }
}
