import Foundation
import Observation
import CryptoKit
import Network
import SystemConfiguration
import AppKit

enum WebConfig {
    static let port: UInt16 = 8787
    static let portFallbacks = 10
    static let cookie = "stv_device"
}

// MARK: LAN policy

/// Only private, link-local and loopback peers may talk to the phone server. CGNAT (100.64/10, used by
/// tunnels such as Tailscale) and every public address are refused.
enum LANAddress {
    static func isLocal(_ endpoint: NWEndpoint, allowLoopback: Bool = true) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isLocal(v4: [UInt8](address.rawValue), allowLoopback: allowLoopback)
        case .ipv6(let address): return isLocal(v6: [UInt8](address.rawValue), allowLoopback: allowLoopback)
        default: return false
        }
    }

    static func isLocal(_ text: String, allowLoopback: Bool = true) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return isLocal(v4: withUnsafeBytes(of: &v4) { [UInt8]($0) }, allowLoopback: allowLoopback)
        }
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return isLocal(v6: withUnsafeBytes(of: &v6) { [UInt8]($0) }, allowLoopback: allowLoopback)
        }
        return false
    }

    static func isLocal(v4 b: [UInt8], allowLoopback: Bool) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 127 { return allowLoopback }
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }

    static func isLocal(v6 b: [UInt8], allowLoopback: Bool) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return allowLoopback }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            return isLocal(v4: Array(b[12..<16]), allowLoopback: allowLoopback)
        }
        return (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] & 0xFE == 0xFC
    }

    /// The Mac's own private IPv4 addresses, en0 first.
    static func ownAddresses() -> [String] { ownInterfaces().map(\.ip) }

    static func ownInterfaces() -> [(name: String, ip: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [(name: String, ip: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isLocal(ip, allowLoopback: false) { found.append((String(cString: ifa.ifa_name), ip)) }
        }
        return found.sorted { ($0.name == "en0" ? 0 : 1, $0.name) < ($1.name == "en0" ? 0 : 1, $1.name) }
    }

    /// Bonjour name, e.g. "Rodrigos-MacBook-Pro.local".
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }
}

// MARK: Pairing

struct PairedDevice: Codable, Equatable {
    /// SHA-256 of the device token, hex. The token itself only ever lives in the phone's cookie.
    var hash: String
    var label: String
    var pairedAt: Date
    var lastSeen: Date?
    /// Paired here while "Use home hub" was on and the hub was down; sent to the hub once it's back.
    var pendingHub: Bool?
}

/// Six-digit codes shown on the Mac, swapped for a long random device token. Only token hashes are saved.
@MainActor
@Observable
final class PairingStore {
    static let codeLifetime: TimeInterval = 5 * 60
    static let wrongCodesAllowed = 5
    static let attemptsPerAddress = 10
    static let attemptWindow: TimeInterval = 10 * 60
    nonisolated static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SamsungTVRemote/web-devices.json")

    enum Outcome: Equatable {
        case paired(token: String)
        case wrong
        case noCode
        case limited
    }

    private struct File: Codable {
        var version = 1
        var devices: [PairedDevice]
    }

    private(set) var devices: [PairedDevice] = []
    /// The hub's paired phones (hashes only), so a phone paired there also works here while the hub is down.
    private(set) var hubDevices: [PairedDevice] = []
    /// Whether a phone pairing now should be passed on to the hub later.
    @ObservationIgnored var pairingForHub: () -> Bool = { false }
    private(set) var code: String?
    private(set) var codeExpires: Date?
    private(set) var lastPaired: (label: String, at: Date)?
    @ObservationIgnored private var wrongForCode = 0
    @ObservationIgnored private var attempts: [String: [Date]] = [:]
    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored var now: () -> Date = Date.init

    init(fileURL: URL? = PairingStore.defaultURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url = mirrorURL, let data = try? Data(contentsOf: url) {
            hubDevices = (try? decoder.decode(File.self, from: data))?.devices ?? []
        }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        devices = (try? decoder.decode(File.self, from: data))?.devices ?? []
    }

    private var mirrorURL: URL? { fileURL?.deletingLastPathComponent().appendingPathComponent("hub-devices.json") }

    var pendingForHub: [PairedDevice] { devices.filter { $0.pendingHub == true } }

    /// Replaces the mirror with the hub's current list. Phones the hub now knows stop being pending.
    func mirror(_ list: [PairedDevice]) {
        let hashes = Set(list.map(\.hash))
        var changed = false
        for i in devices.indices where devices[i].pendingHub == true && hashes.contains(devices[i].hash) {
            devices[i].pendingHub = nil
            changed = true
        }
        if changed { persist() }
        guard list.map(\.hash) != hubDevices.map(\.hash) else { return }
        hubDevices = list
        write(list, to: mirrorURL)
        AppLog.write("web: hub phones now \(list.map { String($0.hash.prefix(8)) }.joined(separator: ", "))")
    }

    var activeCode: String? {
        guard let code, let codeExpires, now() < codeExpires else { return nil }
        return code
    }

    @discardableResult
    func startPairing() -> String {
        var rng = SystemRandomNumberGenerator()
        let next = String(format: "%06d", Int.random(in: 0..<1_000_000, using: &rng))
        code = next
        codeExpires = now().addingTimeInterval(Self.codeLifetime)
        wrongForCode = 0
        return next
    }

    func cancelPairing() {
        code = nil
        codeExpires = nil
        wrongForCode = 0
    }

    /// A wrong code counts against both the code (5 tries, then it's void) and the caller's address.
    func pair(code attempt: String, label: String, from address: String) -> Outcome {
        let t = now()
        var recent = (attempts[address] ?? []).filter { t.timeIntervalSince($0) < Self.attemptWindow }
        guard recent.count < Self.attemptsPerAddress else { return .limited }
        recent.append(t)
        attempts[address] = recent
        guard let expected = activeCode else { return .noCode }
        guard Self.same(attempt, expected) else {
            wrongForCode += 1
            if wrongForCode >= Self.wrongCodesAllowed { cancelPairing() }
            return .wrong
        }
        cancelPairing()
        let token = Self.newToken()
        let name = String(label.filter { !$0.isNewline }.prefix(60))
        devices.append(PairedDevice(hash: Self.hash(token), label: name.isEmpty ? "Phone" : name, pairedAt: t, lastSeen: t,
                                    pendingHub: pairingForHub() ? true : nil))
        lastPaired = (devices.last!.label, t)
        persist()
        AppLog.write("web: paired \(devices.last!.label) as \(devices.last!.hash.prefix(8))\(pairingForHub() ? ", pending for the hub" : "")")
        return .paired(token: token)
    }

    func isAuthorised(_ token: String?) -> Bool {
        guard let token, token.count >= 40, token.count <= 64 else { return false }
        let hash = Self.hash(token)
        guard let i = devices.firstIndex(where: { Self.same($0.hash, hash) }) else {
            return hubDevices.contains { Self.same($0.hash, hash) }
        }
        if devices[i].lastSeen.map({ now().timeIntervalSince($0) > 3600 }) ?? true {
            devices[i].lastSeen = now()
            persist()
        }
        return true
    }

    func forgetAll() {
        devices = []
        lastPaired = nil
        persist()
    }

    nonisolated static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func newToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func persist() { write(devices, to: fileURL) }

    private func write(_ list: [PairedDevice], to url: URL?) {
        guard let fileURL = url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(devices: list)).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {}
    }
}

// MARK: Menu-facing model

/// The "Phone access (local network)" switch: owns the server and the pairing store.
@MainActor
@Observable
final class WebAccess {
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.key)
            apply()
        }
    }
    private(set) var port: UInt16?
    private(set) var problem: String?
    let pairing: PairingStore

    @ObservationIgnored private let server: WebServer
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "web.enabled"

    init(api: WebAPI, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pairing = api.pairing
        server = WebServer(handler: { await api.handle($0) })
        enabled = defaults.object(forKey: Self.key) as? Bool ?? true
        server.onState = { [weak self] port, problem in
            self?.port = port
            self?.problem = problem
        }
        apply()
    }

    private func apply() {
        if enabled {
            server.start(preferred: WebConfig.port, fallbacks: WebConfig.portFallbacks)
        } else {
            server.stop()
            pairing.cancelPairing()
            port = nil
            problem = nil
        }
    }

    var nameURL: String? { port.flatMap { p in LANAddress.localHostName.map { "http://\($0.lowercased()):\(p)" } } }
    var ipURL: String? { port.flatMap { p in LANAddress.ownAddresses().first.map { "http://\($0):\(p)" } } }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
