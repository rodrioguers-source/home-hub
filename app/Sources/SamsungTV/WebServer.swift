import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Lower-cased names.
    var headers: [String: String]
    var body: Data
    var remote: String

    func cookie(_ name: String) -> String? {
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == name { return pair[1] }
        }
        return nil
    }

    func json() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var type: String
    var body: Data
    var headers: [(String, String)] = []

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, type: "application/json; charset=utf-8",
                     body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    static func encoded<T: Encodable>(_ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return HTTPResponse(status: 200, type: "application/json; charset=utf-8", body: (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ message: String, code: String? = nil) -> HTTPResponse {
        var body: [String: Any] = ["ok": false, "error": message]
        if let code { body["code"] = code }
        return json(body, status: status)
    }

    static func text(_ status: Int, _ text: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, type: type, body: Data(text.utf8))
    }

    var serialised: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        let fixed: [(String, String)] = [
            ("Content-Type", type), ("Content-Length", "\(body.count)"), ("Connection", "close"),
            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("X-Frame-Options", "DENY"),
            ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
                + "script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
        ]
        for (name, value) in fixed + headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
         404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 415: "Unsupported Media Type",
         421: "Misdirected Request", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
         500: "Internal Server Error", 502: "Bad Gateway"][status] ?? "Status"
    }
}

/// A small HTTP/1.1 server on NWListener: IPv4 only, one request per connection, everything on the main queue.
/// Peers that aren't on the local network are dropped before anything is read.
@MainActor
final class WebServer {
    nonisolated static let maxHeader = 16 * 1024
    nonisolated static let maxBody = 64 * 1024

    let handler: @MainActor (HTTPRequest) async -> HTTPResponse
    let isAllowed: (NWEndpoint) -> Bool
    var onState: ((UInt16?, String?) -> Void)?
    private(set) var port: UInt16?
    private var listener: NWListener?
    private var generation = 0

    init(handler: @escaping @MainActor (HTTPRequest) async -> HTTPResponse,
         isAllowed: @escaping (NWEndpoint) -> Bool = { LANAddress.isLocal($0) }) {
        self.handler = handler
        self.isAllowed = isAllowed
    }

    /// Tries `preferred`, then the next `fallbacks` ports if it's taken. Port 0 picks a free one.
    func start(preferred: UInt16, fallbacks: Int = 0) {
        stop()
        generation += 1
        listen(on: preferred, triesLeft: fallbacks, generation: generation)
    }

    func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// Waits until the listener is ready (or failed) — for the dry run.
    func waitReady(timeout: Double = 5) async -> UInt16? {
        let start = Date()
        while port == nil, listener != nil, Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return port
    }

    private func listen(on port: UInt16, triesLeft: Int, generation: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // IPv4 only: an iPhone that reaches the Mac over a global IPv6 address would be refused, and v4 always works on the LAN.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: params, on: nwPort) else {
            onState?(nil, "Couldn't open port \(port).")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.onState?(self.port, nil)
                case .failed(let error):
                    listener.cancel()
                    if self.listener === listener { self.listener = nil }
                    if case .posix(let code) = error, code == .EADDRINUSE, triesLeft > 0 {
                        self.listen(on: port == 0 ? 0 : port + 1, triesLeft: triesLeft - 1, generation: generation)
                    } else {
                        self.port = nil
                        self.onState?(nil, "Phone access couldn't start: \(error.localizedDescription)")
                    }
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        guard isAllowed(connection.endpoint) else {
            connection.start(queue: .main)
            send(.text(403, "Local network only."), on: connection)
            return
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch Self.parse(buffer, remote: Self.describe(connection.endpoint)) {
                case .incomplete:
                    if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                case .invalid(let response):
                    self.send(response, on: connection)
                case .request(let request):
                    Task { @MainActor in
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialised, completion: .contentProcessed { _ in connection.cancel() })
    }

    enum Parsed {
        case incomplete
        case invalid(HTTPResponse)
        case request(HTTPRequest)
    }

    nonisolated static func parse(_ buffer: Data, remote: String) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeader ? .invalid(.text(431, "Headers too large.")) : .incomplete
        }
        guard end.lowerBound <= maxHeader else { return .invalid(.text(431, "Headers too large.")) }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid(.text(400, "Bad request.")) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(.text(400, "Bad Content-Length.")) }
        guard length <= maxBody else { return .invalid(.text(413, "Body too large.")) }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let target = String(start[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for item in parts[1].split(separator: "&") {
                let kv = item.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[kv[0]] = kv.count == 2 ? kv[1] : ""
            }
        }
        return .request(HTTPRequest(method: String(start[0]), path: String(parts.first ?? "/"), query: query, headers: headers,
                                    body: buffer.subdata(in: bodyStart..<(bodyStart + length)), remote: remote))
    }

    nonisolated static func describe(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}
