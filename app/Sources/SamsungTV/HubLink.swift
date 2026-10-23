import Foundation
import Observation
import Security
import AppKit

/// What the home hub reports at GET /api/hub.
struct HubSnapshot: Decodable, Sendable {
    struct Step: Decodable, Sendable {
        let label: String
        let track: Int
        let status: String
        let detail: String?
    }
    struct Run: Decodable, Sendable {
        let id: String
        let finished: Bool
        let startedAt: Double
        let steps: [Step]
    }
    struct Scenes: Decodable, Sendable {
        let running: Bool
        let current: Run?
        let apps: [String: String]
    }
    struct Event: Decodable, Sendable {
        let at: Double
        let text: String
    }
    struct Automations: Decodable, Sendable {
        let enabled: [String]
        let events: [String: Event]
    }
    struct Voice: Decodable, Sendable {
        let enabled: Bool
        let last: Event?
        let problem: String?
    }
    struct Claim: Decodable, Sendable {
        let start: Double
        let finishedAt: Double?
        let notified: Bool?
    }
    struct Washer: Decodable, Sendable {
        let phase: String
        let reason: String?
        let status: WasherStatus?
        let fetchedAt: Double?
        let claim: Claim?
        let notifyWhenFree: Bool
    }
    /// The hub's saved presets; a slot that doesn't decode reads as empty rather than failing the snapshot.
    struct Presets: Codable, Sendable {
        struct Result: Codable, Sendable {
            let id: String
            let text: String?
            let failed: Bool
        }
        private struct Lossy: Decodable {
            let value: LightPreset?
            init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(LightPreset.self) }
        }
        private enum CodingKeys: String, CodingKey { case slots, busy, result }

        let slots: [LightPreset?]
        let busy: String?
        let result: Result?

        init(slots: [LightPreset?], busy: String? = nil, result: Result? = nil) {
            self.slots = slots
            self.busy = busy
            self.result = result
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slots = (try? c.decode([Lossy].self, forKey: .slots))?.map(\.value) ?? []
            busy = try? c.decodeIfPresent(String.self, forKey: .busy)
            result = try? c.decodeIfPresent(Result.self, forKey: .result)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(slots, forKey: .slots)
            try c.encodeIfPresent(busy, forKey: .busy)
            try c.encodeIfPresent(result, forKey: .result)
        }
    }
    let scenes: Scenes
    let automations: Automations
    let voice: Voice
    let washer: Washer
    let presets: Presets?
}

/// The hub's device cookie, kept in the login keychain rather than a file.
enum HubKeychain {
    private static let service = "com.rodrigocarneiro.samsungtv.hub"
    private static let account = "device-cookie"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// "Use home hub": Alexa triggers, automations, scenes, the washer claim and the saved presets live on the
/// hub (hub/ in this repo) while it answers. After `offlineAfter` seconds of failed checks the Mac takes
/// over until the hub is back. Off (the default), nothing here runs and the app behaves exactly as before.
@MainActor
@Observable
final class HubLink {
    static let shared = HubLink()

    private(set) var enabled: Bool
    private(set) var host: String?
    private(set) var snapshot: HubSnapshot?
    private(set) var problem: String?
    private(set) var phoneCode: String?
    private(set) var busy = false
    /// The hub hasn't answered for `offlineAfter` seconds; the Mac is doing its work meanwhile.
    private(set) var offline = false
    private(set) var cachedPresets: HubSnapshot.Presets?

    static let offlineAfter: TimeInterval = 60

    /// On, reachable and in charge. Callers that run things use this; display can use `enabled`.
    var active: Bool { enabled && !offline }

    var statusLine: String? {
        guard enabled else { return nil }
        return offline ? "Home hub offline, running on this Mac" : "Home hub: connected"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let session: URLSession
    /// Called after each good snapshot; the app uses it to copy presets over on first link.
    @ObservationIgnored var onRefresh: (() -> Void)?
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var failingSince: Date?
    @ObservationIgnored private let useKeychain: Bool
    @ObservationIgnored private let cacheURL: URL?
    /// Mirrors the hub's paired phones here and passes on phones paired here while it was down.
    @ObservationIgnored weak var pairing: PairingStore?
    @ObservationIgnored private var devicesSyncedAt: Date?
    static let devicesEvery: TimeInterval = 60
    /// Called after every poll and when hub mode goes off; the homehub.local stand-in follows it.
    @ObservationIgnored var onPoll: (() -> Void)?
    /// The dry runs answer requests in memory instead of over the network.
    @ObservationIgnored var transport: ((URLRequest) async throws -> (Data, URLResponse))?

    private static let enabledKey = "hub.enabled"
    private static let hostKey = "hub.host"

    nonisolated static let defaultCacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SamsungTVRemote/hub-presets-cache.json")

    /// `testHost` is for the dry runs: a loopback fake hub, a given cookie, no keychain and no cache file.
    init(defaults: UserDefaults = .standard, testHost: String? = nil, testToken: String? = nil) {
        self.defaults = defaults
        useKeychain = testHost == nil
        cacheURL = testHost == nil ? Self.defaultCacheURL : nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        if let testHost {
            host = testHost
            token = testToken
            enabled = true
            return
        }
        let saved = defaults.string(forKey: Self.hostKey)
        host = saved
        enabled = defaults.bool(forKey: Self.enabledKey) && saved != nil
        if let url = cacheURL, let data = try? Data(contentsOf: url) {
            cachedPresets = try? JSONDecoder().decode(HubSnapshot.Presets.self, from: data)
        }
        if enabled { start() }
    }

    private func url(_ path: String, host: String? = nil) -> URL? {
        guard let h = host ?? self.host, !h.isEmpty else { return nil }
        let withPort = h.contains(":") && !h.hasPrefix("[") ? h : "\(h):\(WebConfig.port)"
        return URL(string: "http://\(withPort)\(path)")
    }

    enum Failure: Error, LocalizedError {
        case unreachable(String), refused(String, code: String?)

        var errorDescription: String? {
            switch self {
            case .unreachable(let message), .refused(let message, _): message
            }
        }
    }

    /// One call to the hub. Errors become HomeHelper.Failure.remote, so callers handle them like the helper's.
    func request(_ path: String, _ body: [String: Any]? = nil, timeout: Double = 20, host: String? = nil,
                 withCookie: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard let url = url(path, host: host) else { throw HomeHelper.Failure.remote("No home hub address set.", code: "hub_unset") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if withCookie {
            if token == nil, useKeychain { token = HubKeychain.read() }
            guard let token else { throw HomeHelper.Failure.remote("The Mac isn't paired with the home hub.", code: "unpaired") }
            req.setValue("\(WebConfig.cookie)=\(token)", forHTTPHeaderField: "Cookie")
        }
        let data: Data, response: URLResponse
        do {
            if let transport {
                (data, response) = try await transport(req)
            } else {
                (data, response) = try await session.data(for: req)
            }
        } catch {
            throw HomeHelper.Failure.remote("Can't reach the home hub at \(host ?? self.host ?? "?").", code: "hub_unreachable")
        }
        guard let http = response as? HTTPURLResponse else {
            throw HomeHelper.Failure.remote("The home hub gave no answer.", code: "hub_unreachable")
        }
        if !(200..<300).contains(http.statusCode) {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["code"] as? String ?? (http.statusCode == 401 ? "unpaired" : nil)
            let message = json?["error"] as? String ?? "The home hub refused that (\(http.statusCode))."
            throw HomeHelper.Failure.remote(message, code: code)
        }
        return (data, http)
    }

    /// Methods the hub runs on the Mac's behalf; handover and owner always stay with the local helper.
    func routes(_ method: String) -> Bool {
        active && method.hasPrefix("st.") && !["st.handover", "st.owner", "st.chain", "st.claim_trigger"].contains(method)
    }

    func rpc(_ method: String, _ params: [String: Any], timeout: Double) async throws -> Data {
        let (data, _) = try await request("/api/rpc", ["method": method, "params": params], timeout: timeout)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HomeHelper.Failure.remote("The home hub's answer wasn't readable.", code: nil)
        }
        if json["ok"] as? Bool == true {
            return try JSONSerialization.data(withJSONObject: json["result"] ?? NSNull(), options: [.fragmentsAllowed])
        }
        throw HomeHelper.Failure.remote(json["error"] as? String ?? "The home hub couldn't do that.", code: json["code"] as? String)
    }

    /// Fire-and-forget POST for toggles; a failure only shows as the link's problem.
    func post(_ path: String, _ body: [String: Any]) {
        Task {
            do {
                _ = try await request(path, body)
                await refresh()
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    // MARK: state

    private func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func refresh() async {
        guard enabled, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let (data, _) = try await request("/api/hub", timeout: 10)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            snapshot = try decoder.decode(HubSnapshot.self, from: data)
            problem = nil
            answered()
            onPoll?()
            onRefresh?()
            if devicesSyncedAt.map({ now().timeIntervalSince($0) >= Self.devicesEvery }) ?? true { await syncDevices() }
        } catch {
            if await rediscover() { return await refreshAgain() }
            problem = Self.describe(error)
            missed()
            onPoll?()
        }
    }

    private func refreshAgain() async {
        refreshing = false
        await refresh()
    }

    @ObservationIgnored private var lastScan: Date?

    nonisolated private static func probe(_ ips: [String], cookie: String, port: Int) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        return await withTaskGroup(of: String?.self) { group in
            for ip in ips {
                group.addTask {
                    guard let url = URL(string: "http://\(ip):\(port)/api/hub") else { return nil }
                    var req = URLRequest(url: url, timeoutInterval: 2)
                    req.setValue(cookie, forHTTPHeaderField: "Cookie")
                    guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
                          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
                    return ip
                }
            }
            for await ip in group { if let ip { group.cancelAll(); return ip } }
            return nil
        }
    }

    /// The router can move the laptop to a new address. Only the real hub accepts this Mac's cookie on /api/hub,
    /// so the scan can't latch onto another 8787 server (or this Mac's own).
    private func rediscover() async -> Bool {
        guard transport == nil, let current = host, current.split(separator: ".").count == 4,
              let since = failingSince, now().timeIntervalSince(since) > 15,
              now().timeIntervalSince(lastScan ?? .distantPast) > 60 else { return false }
        lastScan = now()
        let prefix = current.split(separator: ".").prefix(3).joined(separator: ".")
        let own = Set(LANAddress.ownAddresses())
        if token == nil, useKeychain { token = HubKeychain.read() }
        guard let cookie = token.map({ "\(WebConfig.cookie)=\($0)" }) else { return false }
        let candidates = (1...254).map { "\(prefix).\($0)" }.filter { $0 != current && !own.contains($0) }
        let found = await Self.probe(candidates, cookie: cookie, port: Int(WebConfig.port))
        guard let found else { return false }
        log?("home hub moved from \(current) to \(found)")
        host = found
        defaults.set(found, forKey: Self.hostKey)
        return true
    }

    private struct HubDevice: Decodable {
        let hash: String
        let label: String?
        let pairedAt: String?
    }

    /// Hashes only, both ways. A hub without these routes (older code) just leaves the mirror as it was.
    func syncDevices() async {
        guard let pairing else { return }
        devicesSyncedAt = now()
        let iso = ISO8601DateFormatter()
        let pending = pairing.pendingForHub
        if !pending.isEmpty {
            let rows: [[String: Any]] = pending.map { ["hash": $0.hash, "label": $0.label, "pairedAt": iso.string(from: $0.pairedAt)] }
            do {
                _ = try await request("/api/devices/import", ["devices": rows])
                log?("passed \(pending.count) phone(s) paired while the hub was down on to the hub")
            } catch {
                devicesSyncedAt = nil
            }
        }
        guard let (data, _) = try? await request("/api/devices"),
              let list = try? JSONDecoder().decode([String: [HubDevice]].self, from: data)["devices"] else { return }
        let valid = list.filter { $0.hash.count == 64 && $0.hash.allSatisfy { "0123456789abcdef".contains($0) } }
        pairing.mirror(valid.map {
            PairedDevice(hash: $0.hash, label: $0.label ?? "Phone", pairedAt: $0.pairedAt.flatMap(iso.date(from:)) ?? now(), lastSeen: nil)
        })
    }

    /// A fresh check, even while the 4 s poll is in flight. Used right before the Mac acts on a voice trigger.
    func reachableNow() async -> Bool {
        guard enabled else { return false }
        do {
            _ = try await request("/api/hub", timeout: 4)
            answered()
            return true
        } catch {
            missed()
            return false
        }
    }

    private func answered() {
        failingSince = nil
        if offline {
            offline = false
            devicesSyncedAt = nil
            log?("home hub is back; handing over to it")
        }
        if let presets = snapshot?.presets, presets.slots != cachedPresets?.slots {
            cachedPresets = HubSnapshot.Presets(slots: presets.slots)
            if let cacheURL, let data = try? JSONEncoder().encode(cachedPresets) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
    }

    private func missed() {
        let t = now()
        let since = failingSince ?? t
        failingSince = since
        if !offline, t.timeIntervalSince(since) > Self.offlineAfter {
            offline = true
            log?("home hub unreachable for over \(Int(Self.offlineAfter)) s; running on this Mac")
        }
    }

    // MARK: setup

    /// Pairs with the hub using a code from `python -m hub.pair`. SmartThings refresh moves separately, with
    /// `python -m hub.send_secrets`, because the hub keeps its own copy of the token.
    func pair(host rawHost: String, code: String) async -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = code.filter(\.isNumber)
        guard !host.isEmpty, digits.count == 6 else { return "Enter the hub's address and the 6-digit code." }
        busy = true
        defer { busy = false }
        let token: String
        do {
            let (_, http) = try await request("/api/pair", ["code": digits], host: host, withCookie: false)
            let header = http.value(forHTTPHeaderField: "Set-Cookie") ?? ""
            guard let pair = header.split(separator: ";").first, pair.hasPrefix("\(WebConfig.cookie)="),
                  case let value = String(pair.dropFirst(WebConfig.cookie.count + 1)), value.count >= 32 else {
                return "The hub paired but sent no device cookie."
            }
            token = value
        } catch {
            return Self.describe(error)
        }
        guard HubKeychain.save(token) else { return "Couldn't save the hub's cookie in the keychain." }
        self.token = token
        self.host = host
        defaults.set(host, forKey: Self.hostKey)
        setEnabled(true)
        return nil
    }

    func turnOff() {
        setEnabled(false)
        problem = "If the hub refreshes SmartThings, bring it back with: .venv/bin/python -m hub.send_secrets --back"
    }

    func forget() {
        HubKeychain.delete()
        token = nil
        setEnabled(false)
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            start()
        } else {
            loop?.cancel()
            snapshot = nil
            problem = nil
            phoneCode = nil
            offline = false
            failingSince = nil
            onPoll?()
        }
    }

    func pairPhone() {
        Task {
            do {
                let (data, _) = try await request("/api/pairing/start", [:])
                phoneCode = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
                let code = phoneCode
                try? await Task.sleep(for: .seconds(300))
                if phoneCode == code { phoneCode = nil }
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    /// The setup dialogue behind the "Use home hub" switch.
    func showSetup() {
        let alert = NSAlert()
        alert.messageText = "Use home hub"
        alert.informativeText = "On the hub laptop, run python -m hub.pair and enter the code it shows. "
            + "SmartThings, Alexa triggers, automations, scenes and the washer will then run on the hub. "
            + "Send the secrets first (hub.send_secrets) so the hub has SmartThings."
        let hostField = NSTextField(string: host ?? "")
        hostField.placeholderString = "Hub address, e.g. 192.168.0.50"
        let codeField = NSTextField(string: "")
        codeField.placeholderString = "6-digit code"
        let stack = NSStackView(views: [hostField, codeField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        // Without explicit widths the stack shrinks the fields to slivers inside the alert.
        for field in [hostField, codeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = hostField.stringValue.isEmpty ? hostField : codeField
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let h = hostField.stringValue, c = codeField.stringValue
        Task {
            if let note = await pair(host: h, code: c) { problem = note }
        }
    }

    static func describe(_ error: Error) -> String {
        if case HomeHelper.Failure.remote(let message, _) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? "The home hub didn't answer."
    }
}

extension HubLink: PresetRemote {
    var presetsActive: Bool { enabled }
    var presetsEditable: Bool { active }
    var remotePresets: HubSnapshot.Presets? { snapshot?.presets ?? cachedPresets }

    func presetRequest(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let (data, _) = try await request(path, body)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func refreshPresets() async {
        await refresh()
    }
}
