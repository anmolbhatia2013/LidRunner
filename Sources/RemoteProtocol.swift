import Foundation
import CryptoKit

// Phone remote: the wire protocol, kept free of sockets and UI so every rule is testable.
//
// Threat model. The listener is reachable from the local network and, when connected, the
// user's Tailscale network. Anyone there can open a connection and read the static page, which
// holds no secrets. Everything else needs a request signed with the pairing secret. The secret
// is shown once as a QR code on the Mac's own screen and never crosses the network, so plain
// HTTP on a shared Wi-Fi leaks no credential. A captured request cannot be replayed (nonce) or
// reused later (timestamp). The only commands are: read status, start a bounded session, stop a
// session, and switch "stay reachable" on or off. There is no way to run a command or read a file.

let remoteDefaultPort: UInt16 = 47600
let remoteMaxHeaderBytes = 8192
let remoteMaxBodyBytes = 2048
let remoteClockSkew = 90.0

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String] // lowercased names
    var body: Data
}
enum HTTPParse: Equatable {
    case incomplete
    case bad(Int)
    case ok(HTTPRequest)
}

/// Parse one HTTP/1.1 request. Strict on purpose: small limits, no chunked bodies, no folding.
func parseHTTPRequest(_ data: Data) -> HTTPParse {
    let separator = Data("\r\n\r\n".utf8)
    guard let headEnd = data.range(of: separator) else {
        return data.count > remoteMaxHeaderBytes ? .bad(431) : .incomplete
    }
    guard headEnd.lowerBound <= remoteMaxHeaderBytes,
          let head = String(data: data.subdata(in: data.startIndex..<headEnd.lowerBound), encoding: .utf8) else { return .bad(400) }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else { return .bad(400) }
    let method = String(requestLine[0])
    guard method == "GET" || method == "POST" else { return .bad(405) }
    var path = String(requestLine[1])
    if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
    guard path.hasPrefix("/"), path.count <= 200, !path.contains(".."),
          path.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value != 127 }) else { return .bad(400) }
    var headers: [String: String] = [:]
    guard lines.count <= 64 else { return .bad(431) }
    for line in lines {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line.first != " ", line.first != "\t" else { return .bad(400) }
        let name = line[..<colon].lowercased()
        guard headers[name] == nil || name != "content-length" else { return .bad(400) }
        headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil else { return .bad(400) }
    var length = 0
    if let raw = headers["content-length"] {
        guard let value = Int(raw), value >= 0, raw.allSatisfy(\.isNumber) else { return .bad(400) }
        length = value
    }
    guard length <= remoteMaxBodyBytes else { return .bad(413) }
    if method == "GET", length != 0 { return .bad(400) }
    let bodyStart = headEnd.upperBound
    let available = data.endIndex - bodyStart
    if available < length { return .incomplete }
    return .ok(HTTPRequest(method: method, path: path, headers: headers, body: data.subdata(in: bodyStart..<(bodyStart + length))))
}

func httpResponse(status: Int, contentType: String = "application/json", body: Data, extraHeaders: [String: String] = [:]) -> Data {
    let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                   409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]
    var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
    var headers = ["Content-Type": contentType, "Content-Length": String(body.count), "Connection": "close",
                   "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
                   "X-Frame-Options": "DENY"]
    for (name, value) in extraHeaders { headers[name] = value }
    for name in headers.keys.sorted() { head += "\(name): \(headers[name]!)\r\n" }
    return Data((head + "\r\n").utf8) + body
}
func jsonResponse(_ status: Int, _ object: [String: Any]) -> Data {
    httpResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
}

// MARK: Signing

func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func dataFromHex(_ text: String) -> Data? {
    guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
    var out = Data(capacity: text.count / 2), index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        out.append(byte); index = next
    }
    return out
}
/// The exact bytes both sides sign. The web page builds the same string.
func signaturePayload(method: String, path: String, time: String, nonce: String, body: Data) -> Data {
    Data("\(method)\n\(path)\n\(time)\n\(nonce)\n".utf8) + body
}
func remoteSignature(secret: Data, method: String, path: String, time: String, nonce: String, body: Data) -> String {
    hex(HMAC<SHA256>.authenticationCode(for: signaturePayload(method: method, path: path, time: time, nonce: nonce, body: body),
                                        using: SymmetricKey(data: secret)))
}

/// Remembers recent nonces so a captured request cannot be sent twice.
struct NonceCache {
    private(set) var seen: [String: Double] = [:]
    mutating func insert(_ nonce: String, now: Double) -> Bool {
        seen = seen.filter { now - $0.value < remoteClockSkew * 2 + 10 && now >= $0.value - 5 }
        guard seen[nonce] == nil, seen.count < 2000 else { return false }
        seen[nonce] = now
        return true
    }
}
/// Slows guessing: too many bad signatures and every request is refused for a while.
struct Lockout {
    private(set) var failures: [Double] = []
    private(set) var lockedUntil = 0.0
    func locked(now: Double) -> Bool { now < lockedUntil }
    mutating func recordFailure(now: Double) {
        failures = failures.filter { now - $0 < 60 && now >= $0 } + [now]
        if failures.count >= 20 { lockedUntil = now + 300; failures = [] }
    }
}
enum RemoteAuth: Equatable { case ok, locked, denied(String) }

func authorize(_ request: HTTPRequest, secret: Data?, now: Double, nonces: inout NonceCache, lockout: inout Lockout) -> RemoteAuth {
    if lockout.locked(now: now) { return .locked }
    guard let secret, secret.count >= 32 else { return .denied("not paired") }
    guard let time = request.headers["x-lr-time"], let nonce = request.headers["x-lr-nonce"], let given = request.headers["x-lr-sign"],
          let stamp = Double(time), time.count <= 12, time.allSatisfy(\.isNumber),
          nonce.count >= 16, nonce.count <= 64, nonce.allSatisfy(\.isHexDigit),
          let givenBytes = dataFromHex(given), givenBytes.count == 32 else {
        lockout.recordFailure(now: now); return .denied("unsigned")
    }
    guard abs(now - stamp) <= remoteClockSkew else { lockout.recordFailure(now: now); return .denied("clock") }
    let payload = signaturePayload(method: request.method, path: request.path, time: time, nonce: nonce, body: request.body)
    // isValidAuthenticationCode compares in constant time.
    guard HMAC<SHA256>.isValidAuthenticationCode(givenBytes, authenticating: payload, using: SymmetricKey(data: secret)) else {
        lockout.recordFailure(now: now); return .denied("signature")
    }
    guard nonces.insert(nonce, now: now) else { return .denied("replay") }
    return .ok
}

// MARK: Who may connect

/// Loopback, private LAN ranges, link-local, and Tailscale (100.64.0.0/10 and its ULA prefix).
/// Public addresses are refused even if a router forwards the port.
func remoteAddressAllowed(_ bytes: [UInt8]) -> Bool {
    if bytes.count == 4 {
        let (a, b) = (bytes[0], bytes[1])
        return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
    }
    guard bytes.count == 16 else { return false }
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return remoteAddressAllowed(Array(bytes[12...])) }
    if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }       // ::1
    if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }                    // fe80::/10 link-local
    return bytes[0] & 0xfe == 0xfc                                                  // fc00::/7 unique local (includes Tailscale)
}

// MARK: Commands

enum RemoteCommand: Equatable {
    case start(hours: Int)
    case stop
    case standby(Bool)
}
/// JSONSerialization bridges numbers and booleans to NSNumber; tell them apart exactly.
func isJSONBool(_ value: Any) -> Bool { CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() }
/// The complete command surface. Anything else is rejected.
func parseRemoteCommand(path: String, body: Data) -> RemoteCommand? {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
    switch path {
    case "/api/session":
        switch object["action"] as? String {
        case "start":
            guard object.count == 2, let raw = object["hours"], !isJSONBool(raw), let hours = raw as? Int, sessionLengths.contains(hours) else { return nil }
            return .start(hours: hours)
        case "stop": return object.count == 1 ? .stop : nil
        default: return nil
        }
    case "/api/standby":
        guard object.count == 1, let raw = object["enabled"], isJSONBool(raw), let enabled = raw as? Bool else { return nil }
        return .standby(enabled)
    default: return nil
    }
}
