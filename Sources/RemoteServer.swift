import Foundation
import Network
import SystemConfiguration

/// The phone-remote listener. Deliberately tiny: one request per connection, strict size and
/// time limits, and every decision about a request is made by the pure functions in
/// RemoteProtocol.swift. Off unless the user turns Phone remote on.
final class RemoteServer {
    private let queue = DispatchQueue(label: "LidRunner.remote")
    private var listener: NWListener?
    private var openConnections = 0 // queue only
    /// Main thread: nil when listening, otherwise why not.
    var onState: ((String?) -> Void)?
    /// Main thread: turn one parsed request into complete response bytes.
    var respond: ((HTTPRequest) -> Data)?

    func start(port: UInt16) {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { report("Invalid port"); return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: endpointPort)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report(nil)
                case .failed(let error): self?.report("Couldn't listen on port \(port): \(error.localizedDescription)")
                case .waiting(let error): self?.report("Waiting for the network: \(error.localizedDescription)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch { report("Couldn't listen on port \(port): \(error.localizedDescription)") }
    }
    func stop() { listener?.cancel(); listener = nil }

    private func report(_ problem: String?) { DispatchQueue.main.async { self.onState?(problem) } }

    private func accept(_ connection: NWConnection) {
        guard openConnections < 16, RemoteServer.allowed(connection.endpoint) else { connection.cancel(); return }
        openConnections += 1
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true; self?.openConnections -= 1; connection.cancel()
        }
        connection.stateUpdateHandler = { state in if case .failed = state { finish() } }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8, execute: finish) // a slow client cannot hold a slot
        read(connection, Data(), finish)
    }
    private func read(_ connection: NWConnection, _ received: Data, _ finish: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { finish(); return }
            var buffer = received
            if let data { buffer.append(data) }
            switch parseHTTPRequest(buffer) {
            case .incomplete:
                if complete || error != nil || buffer.count > remoteMaxHeaderBytes + remoteMaxBodyBytes { finish() }
                else { self.read(connection, buffer, finish) }
            case .bad(let status):
                self.send(connection, jsonResponse(status, ["error": "bad request"]), finish)
            case .ok(let request):
                DispatchQueue.main.async {
                    let reply = self.respond?(request) ?? jsonResponse(500, ["error": "unavailable"])
                    self.queue.async { self.send(connection, reply, finish) }
                }
            }
        }
    }
    private func send(_ connection: NWConnection, _ reply: Data, _ finish: @escaping () -> Void) {
        connection.send(content: reply, completion: .contentProcessed { _ in finish() })
    }

    static func allowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return remoteAddressAllowed([UInt8](address.rawValue))
        case .ipv6(let address): return remoteAddressAllowed([UInt8](address.rawValue))
        default: return false
        }
    }
}

// MARK: Addresses for the pairing link

/// This Mac's Tailscale IPv4 address (100.64.0.0/10), if Tailscale is connected.
func tailscaleAddress() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              interface.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) } }
        if bytes.count == 4, bytes[0] == 100, (64...127).contains(bytes[1]) { return bytes.map(String.init).joined(separator: ".") }
    }
    return nil
}
/// This Mac's address on the local network (first private IPv4 that is not Tailscale).
func lanAddress() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              interface.pointee.ifa_flags & UInt32(IFF_UP) != 0, interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { [UInt8]($0) } }
        guard bytes.count == 4, remoteAddressAllowed(bytes), bytes[0] != 100, bytes[0] != 169 else { continue }
        return bytes.map(String.init).joined(separator: ".")
    }
    return nil
}
/// Ask our own listener for the time through the network address a phone would use. Loopback
/// bypasses the macOS firewall; this does not, so no answer means phones are being blocked.
func probeListener(host: String, port: UInt16, completion: @escaping (Bool) -> Void) {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { completion(false); return }
    let queue = DispatchQueue(label: "LidRunner.remote.probe")
    let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    var done = false
    let finish: (Bool) -> Void = { ok in
        guard !done else { return }
        done = true; connection.cancel(); DispatchQueue.main.async { completion(ok) }
    }
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connection.send(content: Data("GET /api/time HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in finish((data?.count ?? 0) > 0) }
        case .failed, .cancelled: finish(false)
        default: break
        }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 3) { finish(false) }
}

/// "Name.local": stable on the home network even when the router hands out a new IP address.
func bonjourHostName() -> String? {
    guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
    return name + ".local"
}
