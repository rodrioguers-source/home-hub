import Foundation
import Darwin

enum TVConfig {
    // The router hands the TV a new address now and then, so the last one found is remembered and rediscovered by MAC.
    nonisolated(unsafe) static var host = UserDefaults.standard.string(forKey: "tvHost") ?? "192.168.0.97" {
        didSet { UserDefaults.standard.set(host, forKey: "tvHost") }
    }
    static let mac = "28:07:08:A8:9D:06"
    static let remoteName = "Rodrigo Mac"
    static let opItem = "Samsung TV"
    static let room = "Living Room"
}

struct TVApp: Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let name: String
    let short: String
    let color: UInt32

    static let favourites: [TVApp] = [
        TVApp(id: "3201907018807", key: "netflix", name: "Netflix", short: "N", color: 0xE50914),
        TVApp(id: "111299001912", key: "youtube", name: "YouTube", short: "▶", color: 0xFF0033),
        TVApp(id: "3201910019365", key: "prime", name: "Prime Video", short: "prime", color: 0x00A8E1),
        TVApp(id: "3201901017640", key: "disney", name: "Disney+", short: "D+", color: 0x0E3B6E),
        TVApp(id: "3201606009684", key: "spotify", name: "Spotify", short: "♫", color: 0x1DB954),
        TVApp(id: "3201807016597", key: "appletv", name: "Apple TV", short: "tv", color: 0x2A2A2D),
    ]

    // Probed on this TV via REST; app_list() over the WebSocket never answers on this model.
    static let others: [TVApp] = [
        TVApp(id: "3201601007670", key: "iplayer", name: "BBC iPlayer", short: "BBC", color: 0xF54997),
        TVApp(id: "121299000089", key: "itvx", name: "ITVX", short: "ITVX", color: 0x1C1E3C),
        TVApp(id: "3201603008746", key: "now", name: "NOW", short: "NOW", color: 0x00C9A7),
        TVApp(id: "3202010022079", key: "browser", name: "Browser", short: "www", color: 0x3B5BDB),
    ] + placeholders.compactMap { p in
        p.id.map { TVApp(id: $0, key: p.key, name: p.name, short: p.short, color: p.color) }
    }

    /// Apps whose ID on this TV isn't known yet. Each stays hidden everywhere (Apps tab, scene picker)
    /// until its `id` is filled in here.
    static let placeholders: [(key: String, name: String, short: String, color: UInt32, id: String?)] = [
        (key: "stremio", name: "Stremio", short: "S", color: 0x7B5BF5, id: "IkWsFHtOY9.Stremio"),
    ]

    static let all = favourites + others

    static func byKey(_ key: String) -> TVApp? { all.first { $0.key == key } }
}

struct AppStatus: Decodable, Sendable {
    let name: String?
    let running: Bool?
    let visible: Bool?
}

enum PowerState: Sendable { case on, standby, unreachable }

enum REST {
    static func url(_ path: String) -> URL {
        URL(string: "http://\(TVConfig.host):8001/api/v2/\(path)")!
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        return URLSession(configuration: config)
    }()

    static func power() async -> (PowerState, String?) {
        do {
            let (data, _) = try await session.data(from: url(""))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let device = json?["device"] as? [String: Any]
            let model = device?["modelName"] as? String
            let state = (device?["PowerState"] as? String)?.lowercased()
            return (state == nil || state == "on" ? .on : .standby, model)
        } catch {
            return (.unreachable, nil)
        }
    }

    /// Scans the /24 for a Samsung REST API whose Wi-Fi MAC is the TV's.
    static func discover() async -> String? {
        let prefix = TVConfig.host.split(separator: ".").prefix(3).joined(separator: ".")
        let probe = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 1.5; return c }())
        return await withTaskGroup(of: String?.self) { group in
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                group.addTask {
                    guard let url = URL(string: "http://\(ip):8001/api/v2/"),
                          let (data, _) = try? await probe.data(from: url),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let mac = (json["device"] as? [String: Any])?["wifiMac"] as? String,
                          mac.caseInsensitiveCompare(TVConfig.mac) == .orderedSame else { return nil }
                    return ip
                }
            }
            for await ip in group { if let ip { group.cancelAll(); return ip } }
            return nil
        }
    }

    /// nil means not installed. Some apps (Stremio) answer 200 with an empty body: installed, state unknown.
    static func status(_ appID: String) async -> AppStatus? {
        guard let (data, response) = try? await session.data(from: url("applications/\(appID)")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(AppStatus.self, from: data)) ?? AppStatus(name: nil, running: nil, visible: nil)
    }

    static func launch(_ appID: String) async {
        var request = URLRequest(url: url("applications/\(appID)"))
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }
}

enum WakeOnLAN {
    @discardableResult
    static func send(mac: String = TVConfig.mac) -> Int {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return 0 }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var sent = 0
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        for target in ["255.255.255.255", "192.168.0.255"] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, target, &addr.sin_addr)
            let n = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            sent += max(n, 0)
        }
        return sent
    }
}

enum TokenStore {
    enum Failure: Error { case opMissing, opFailed }

    /// Reads the pairing token from 1Password. Returned value lives only in memory.
    static func read() async throws -> String {
        let candidates = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.opMissing
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["item", "get", TVConfig.opItem, "--fields", "credential", "--reveal"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !token.isEmpty else { throw Failure.opFailed }
            return token
        }.value
    }
}

/// Accepts the TV's self-signed certificate, and only for the TV's host.
final class TVTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == TVConfig.host, let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
final class RemoteSocket {
    enum State: Equatable { case idle, fetchingToken, connecting, ready, unauthorized, tokenUnavailable }

    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?

    private var token: String?
    private var task: URLSessionWebSocketTask?
    private var pending: [(at: Date, text: String)] = []
    /// Set by the model from REST power state, so a TV in standby isn't hammered with reconnects.
    var allowed = false
    private var retryDelay: TimeInterval = 2
    private var retryScheduled = false
    private var pingTask: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral, delegate: TVTrustDelegate(), delegateQueue: nil)

    var isReady: Bool { state == .ready }

    /// Safe to call often: no-op while connecting or connected, and never re-prompts 1Password after a failure.
    func connectIfNeeded() {
        guard state == .idle, allowed else { return }
        Task { await connect() }
    }

    /// User-initiated retry, allowed to ask 1Password again.
    func retry() {
        if state == .tokenUnavailable || state == .unauthorized { token = nil; state = .idle }
        connectIfNeeded()
    }

    func disconnect() {
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pending.removeAll()
        if state == .ready || state == .connecting { state = .idle }
    }

    private func connect() async {
        if token == nil {
            state = .fetchingToken
            do { token = try await TokenStore.read() } catch {
                state = .tokenUnavailable
                return
            }
        }
        state = .connecting
        let name = Data(TVConfig.remoteName.utf8).base64EncodedString()
        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = TVConfig.host
        comps.port = 8002
        comps.path = "/api/v2/channels/samsung.remote.control"
        comps.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in self?.handle(result, from: task) }
        }
    }

    private func handle(_ result: Result<URLSessionWebSocketTask.Message, Error>, from task: URLSessionWebSocketTask) {
        guard task === self.task else { return }
        switch result {
        case .failure:
            failed()
        case .success(let message):
            var text: String?
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8)
            @unknown default: break
            }
            if let text, let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let event = json["event"] as? String {
                switch event {
                case "ms.channel.connect":
                    if let fresh = (json["data"] as? [String: Any])?["token"] as? String, !fresh.isEmpty { token = fresh }
                    state = .ready
                    retryDelay = 2
                    flush()
                    startPings(task)
                case "ms.channel.unauthorized":
                    self.task?.cancel(with: .normalClosure, reason: nil)
                    self.task = nil
                    state = .unauthorized
                    return
                default: break
                }
            }
            receive(on: task)
        }
    }

    private func startPings(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                task.sendPing { error in
                    if error != nil { Task { @MainActor in if task === self?.task { self?.failed() } } }
                }
            }
        }
    }

    private func failed() {
        pingTask?.cancel()
        task?.cancel()
        task = nil
        guard state != .unauthorized && state != .tokenUnavailable else { return }
        state = .idle
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            retryScheduled = false
            connectIfNeeded()
        }
    }

    private func flush() {
        guard let task else { return }
        let queued = pending.filter { $0.at.timeIntervalSinceNow > -8 }
        pending.removeAll()
        for item in queued {
            task.send(.string(item.text)) { [weak self] error in
                if error != nil { Task { @MainActor in self?.failed() } }
            }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        guard allowed, state != .unauthorized, state != .tokenUnavailable else { return }
        pending.append((Date(), text))
        if pending.count > 20 { pending.removeFirst(pending.count - 20) }
        if state == .ready { flush() } else { connectIfNeeded() }
    }

    func key(_ key: String) {
        send(["method": "ms.remote.control",
              "params": ["Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    func moveCursor(dx: Int, dy: Int) {
        guard state == .ready else { return }
        send(["method": "ms.remote.control",
              "params": ["Cmd": "Move", "Position": ["x": dx, "y": dy, "Time": "0"], "TypeOfRemote": "ProcessMouseDevice"]])
    }

    func leftClick() {
        send(["method": "ms.remote.control", "params": ["Cmd": "LeftClick", "TypeOfRemote": "ProcessMouseDevice"]])
    }

    /// DEEP_LINK suits web apps; native Tizen apps can silently ignore it and need NATIVE_LAUNCH.
    func launch(_ appID: String, native: Bool = false) {
        send(["method": "ms.channel.emit",
              "params": ["event": "ed.apps.launch", "to": "host",
                         "data": ["action_type": native ? "NATIVE_LAUNCH" : "DEEP_LINK", "appId": appID, "metaTag": ""]]])
    }
}
