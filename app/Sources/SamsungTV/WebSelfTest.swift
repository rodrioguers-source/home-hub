import Foundation
import Network
import AppKit
import WebKit
import SwiftUI

/// Records the phone's TV and PS5 commands and fakes their effect on offline models. Touches no network.
@MainActor
final class FakeWebControls: WebControls {
    private let tv: TVModel
    private let ps5: PS5Model
    private(set) var calls: [String] = []

    init(tv: TVModel, ps5: PS5Model) {
        self.tv = tv
        self.ps5 = ps5
    }

    func tvPower(on: Bool) {
        calls.append("tv.power \(on)")
        tv.power = on ? .on : .standby
    }

    func tvKey(_ key: String) { calls.append("tv.key \(key)") }

    func tvLaunch(_ app: TVApp) {
        calls.append("tv.launch \(app.key)")
        tv.visibleApp = app
        tv.runningApps.insert(app.id)
    }

    func tvInput(_ id: String) {
        calls.append("tv.input \(id)")
        tv.smartThings.noteChosenInput(id, staleReport: tv.smartThings.status?.inputSource)
    }

    func ps5Power(on: Bool) {
        calls.append("ps5.power \(on)")
        ps5.status = on ? .on : .rest
    }
}

/// Offline models with realistic state behind a `WebAPI`, for the dry run and the phone snapshots.
@MainActor
final class WebFixture {
    let tv = TVModel(live: false)
    let ps5 = PS5Model(helper: HomeHelper(live: false), usage: nil, live: false)
    let bulbs = FakeBulbs()
    let devices = DryRunDevices()
    let washerSource = FakeWasherSource()
    let lights: LightsModel
    let scenes: SceneRunner
    let washer: WasherModel
    let controls: FakeWebControls
    let pairing: PairingStore
    let api: WebAPI
    var dark = true
    private(set) var ps5Refreshes = 0
    private let suite = "com.rodrigocarneiro.samsungtv.web-dryrun"

    init(devicesFile: URL) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        lights = LightsModel(helper: bulbs, presets: PresetStore(fileURL: nil))
        scenes = SceneRunner(devices: devices, defaults: defaults)
        washer = WasherModel(source: washerSource, alerts: FakeWasherAlerts(), defaults: defaults)
        controls = FakeWebControls(tv: tv, ps5: ps5)
        pairing = PairingStore(fileURL: devicesFile)
        var scheme: () -> ColorScheme = { .dark }
        api = WebAPI(tv: tv, ps5: ps5, lights: lights, scenes: scenes, washer: washer, controls: controls, pairing: pairing,
                     scheme: { scheme() })
        scheme = { [unowned self] in self.dark ? .dark : .light }
        api.scheme = scheme
        api.refreshPS5 = { [unowned self] in self.ps5Refreshes += 1 }

        tv.power = .on
        tv.hasPolled = true
        tv.visibleApp = TVApp.favourites[1]
        tv.runningApps = [TVApp.favourites[1].id, TVApp.favourites[0].id]
        tv.socketState = .ready
        tv.smartThings.phase = .ready
        tv.smartThings.status = STStatus(
            health: "ONLINE", power: "on", inputSource: "dtv",
            inputs: [STOption(id: "dtv", name: "TV"), STOption(id: "HDMI1", name: "HDMI 1"), STOption(id: "HDMI2", name: "HDMI 2")],
            pictureMode: "Eco", pictureModes: [STOption(id: "modeGen_393227", name: "Eco")],
            soundMode: "Standard", soundModes: [STOption(id: "modeStandard", name: "Standard")],
            volume: 17, mute: "unmuted", tvChannelName: "")
        ps5.status = .on
        ps5.hasPolled = true
        ps5.psnFetchedAt = Date()
        ps5.psn = PSNSummary(configured: true, state: "ready", error: nil, onlineId: "sample_player",
                             presence: PSNPresence(availability: "availableToPlay", onlineStatus: "online", platform: "PS5",
                                                   title: "Sample Game", titleId: nil, icon: nil),
                             mostPlayed: [("Sample Game", 412_000), ("Another Title", 251_000), ("Racing Thing", 98_000),
                                          ("Puzzle Box", 31_000), ("Short One", 2_400)].map {
                                 PSNTitle(titleId: $0.0, name: $0.0, image: nil, seconds: $0.1, plays: nil, platform: "PS5")
                             })
        washer.status = .sample("running", completion: ISO8601DateFormatter().string(from: Date().addingTimeInterval(38 * 60)))
        WeatherModel.shared.now = WeatherNow(temp: 14, code: 2, isDay: true, high: 17, low: 9, rainChance: 30)
        MatchModel.shared.match = Match(kickoff: ISO8601DateFormatter().date(from: "2026-10-18T15:30:00Z")!, opponent: "Nottm Forest",
                                        home: false, neutral: false, competition: "Premier League", state: .upcoming)
    }

    func prepare() async {
        bulbs.bulbs[2]?.mode = "colour"
        bulbs.bulbs[2]?.color = "#8a2bff"
        bulbs.bulbs[3]?.on = false
        bulbs.dead = [1]
        await lights.refresh()
        lights.presets.save(0, name: "Reading", looks: [
            BulbLook(index: 1, on: true, mode: .white, brightness: 70, temp: 35), BulbLook(index: 2, on: false, mode: .white, brightness: 50, temp: 0),
            BulbLook(index: 3, on: true, mode: .white, brightness: 40, temp: 20), BulbLook(index: 4, on: true, mode: .colour, brightness: 80, temp: 0, colour: "00c8ff"),
        ])
        bulbs.dead = []
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

/// Raw HTTP over loopback, so tests can send any Host, Origin or body size.
enum RawHTTP {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
        var done = false
    }

    @MainActor static func send(_ request: Data, port: UInt16) async -> Reply? {
        await withCheckedContinuation { (cont: CheckedContinuation<Reply?, Never>) in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let box = Box()
            @Sendable func finish() {
                guard !box.done else { return }
                box.done = true
                connection.cancel()
                cont.resume(returning: parse(box.data))
            }
            @Sendable func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data { box.data.append(data) }
                    if complete || error != nil { finish() } else { read() }
                }
            }
            connection.stateUpdateHandler = { state in
                if case .failed = state { finish() }
                if case .waiting = state { finish() }
            }
            connection.start(queue: .main)
            connection.send(content: request, completion: .contentProcessed { _ in })
            read()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish() }
        }
    }

    @MainActor static func request(_ method: String, _ path: String, port: UInt16, host: String? = nil, cookie: String? = nil,
                                   json: Any? = nil, type: String = "application/json", origin: String? = nil,
                                   extra: [String] = []) async -> Reply? {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nUser-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1\r\n"
        if let cookie { head += "Cookie: \(WebConfig.cookie)=\(cookie)\r\n" }
        if let origin { head += "Origin: \(origin)\r\n" }
        if json != nil { head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n" }
        for line in extra { head += line + "\r\n" }
        return await send(Data((head + "\r\n").utf8) + body, port: port)
    }

    static func parse(_ data: Data) -> Reply? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Reply(status: status, headers: headers, body: data[end.upperBound...])
    }
}

/// `SamsungTV --web-dryrun`: runs the phone server against fake devices on a random port, checks pairing,
/// auth, LAN and host rules, the state JSON and every action route, then exits non-zero on any failure.
/// `--web-dryrun serve` instead keeps it up (2 min) with a pairing code, for poking at with curl.
/// `SamsungTV --web-snapshot <dir>` renders the phone page at iPhone width in both looks.
enum WebSelfTest {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--web-snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            spin { await snapshot(dir: dir) ? 0 : 1 }
        }
        guard let flag = args.firstIndex(of: "--web-dryrun") else { return }
        let serve = args.indices.contains(flag + 1) && args[flag + 1] == "serve"
        spin { serve ? await self.serve() : await run() }
    }

    @MainActor private static func spin(_ body: @escaping @MainActor () async -> Int) -> Never {
        var done = false
        var failures = 0
        Task { @MainActor in
            failures = await body()
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("web-dryrun-\(UUID().uuidString.prefix(6))/web-devices.json")
    }

    @MainActor private static func serve() async -> Int {
        let file = tempFile()
        let fixture = WebFixture(devicesFile: file)
        await fixture.prepare()
        let server = WebServer(handler: { await fixture.api.handle($0) })
        server.start(preferred: 0)
        guard let port = await server.waitReady() else { print("server didn't start"); return 1 }
        print("PORT \(port)")
        print("CODE \(fixture.pairing.startPairing())")
        print("DEVICES \(file.path)")
        fflush(stdout)
        let start = Date()
        var seen = 0
        while Date().timeIntervalSince(start) < 120 {
            try? await Task.sleep(for: .milliseconds(200))
            for call in fixture.controls.calls.dropFirst(seen) { print("fake \(call)") }
            seen = fixture.controls.calls.count
            fflush(stdout)
        }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        return 0
    }

    @MainActor private static func run() async -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fixture = WebFixture(devicesFile: file)
        await fixture.prepare()
        let pairing = fixture.pairing

        print("== LAN policy")
        for (address, local) in [("192.168.0.31", true), ("10.1.2.3", true), ("172.16.0.9", true), ("172.31.255.1", true),
                                 ("169.254.10.10", true), ("127.0.0.1", true), ("fe80::1c2a:3bff:fe4d:1", true), ("fd12:3456::1", true),
                                 ("::1", true), ("::ffff:192.168.0.31", true),
                                 ("8.8.8.8", false), ("172.32.0.1", false), ("100.101.102.103", false), ("192.169.0.1", false),
                                 ("2a00:23c6::1", false), ("::ffff:8.8.8.8", false), ("not an address", false)] {
            check(LANAddress.isLocal(address) == local, "\(address) is \(local ? "allowed" : "refused")")
        }
        check(!LANAddress.isLocal("127.0.0.1", allowLoopback: false), "Loopback can be refused too (used below)")
        check(LANAddress.ownAddresses().allSatisfy { LANAddress.isLocal($0, allowLoopback: false) }, "The Mac's own addresses are private: \(LANAddress.ownAddresses())")

        let server = WebServer(handler: { await fixture.api.handle($0) })
        server.start(preferred: 0)
        guard let port = await server.waitReady() else { check(false, "Server starts on a random port"); return failures }
        check(true, "Server listening on 127.0.0.1:\(port)")

        print("\n== Port fallback and refusal")
        let second = WebServer(handler: { _ in .text(200, "second") })
        second.start(preferred: port, fallbacks: 3)
        let secondPort = await second.waitReady()
        check(secondPort == port + 1, "Port \(port) busy: falls back to \(secondPort.map(String.init) ?? "nothing")")
        second.stop()
        let strict = WebServer(handler: { _ in .text(200, "should not answer") }, isAllowed: { LANAddress.isLocal($0, allowLoopback: false) })
        strict.start(preferred: 0, fallbacks: 3)
        if let strictPort = await strict.waitReady() {
            let r = await RawHTTP.request("GET", "/", port: strictPort)
            check(r?.status == 403 && r?.text == "Local network only.", "A peer outside the allowed ranges gets 403 before anything is read")
        } else {
            check(false, "Strict server starts")
        }
        strict.stop()

        print("\n== Without pairing")
        let page = await RawHTTP.request("GET", "/", port: port)
        check(page?.status == 200 && page?.text.contains("Pair this device") == true, "GET / serves the app shell with the pairing screen")
        check(page?.text.contains("apple-mobile-web-app-capable") == true && page?.text.contains("viewport-fit=cover") == true,
              "Has the Home Screen and safe-area metas")
        check(page?.text.contains("http://") == false && page?.text.contains("https://") == false, "No external URLs in the page")
        check(page?.text.contains("data-theme=\"dark\"") == true, "Theme from the app's appearance is baked in")
        check(page?.headers["content-security-policy"]?.contains("default-src 'self'") == true && page?.headers["x-frame-options"] == "DENY",
              "Security headers set")
        let unauth = await RawHTTP.request("GET", "/api/state", port: port)
        check(unauth?.status == 401 && unauth?.json?["code"] as? String == "unpaired", "GET /api/state without a token: 401")
        let unauthPost = await RawHTTP.request("POST", "/api/tv/key", port: port, json: ["key": "KEY_UP"])
        check(unauthPost?.status == 401 && fixture.controls.calls.isEmpty, "POST without a token: 401, nothing sent")
        let bogus = await RawHTTP.request("GET", "/api/state", port: port, cookie: String(repeating: "A", count: 43))
        check(bogus?.status == 401, "Made-up token: 401")
        let manifest = await RawHTTP.request("GET", "/manifest.webmanifest", port: port)
        check(manifest?.status == 200 && manifest?.json?["display"] as? String == "standalone", "Manifest is public and standalone")
        let icon = await RawHTTP.request("GET", "/apple-touch-icon.png", port: port)
        check(icon?.status == 200 && icon?.body.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) && (icon?.body.count ?? 0) > 1000, "Home Screen icon is a PNG")
        let evil = await RawHTTP.request("GET", "/", port: port, host: "evil.example:\(port)")
        check(evil?.status == 421, "Unknown Host header (DNS rebinding): 421")
        let shared = await RawHTTP.request("GET", "/", port: port, host: "homehub.local:\(port)")
        check(shared?.status == 200, "homehub.local is an allowed Host (the phone's one address)")
        let sharedPost = await RawHTTP.request("POST", "/api/pair", port: port, host: "homehub.local:\(port)", json: ["code": "000000"],
                                               origin: "http://homehub.local:\(port)")
        check(sharedPost?.status == 403 && sharedPost?.json?["code"] as? String == "no_code",
              "Same-origin POST on homehub.local passes the origin check")
        let missing = await RawHTTP.request("GET", "/nope", port: port)
        check(missing?.status == 404, "Unknown path: 404")

        print("\n== Pairing")
        let noCode = await RawHTTP.request("POST", "/api/pair", port: port, json: ["code": "123456"])
        check(noCode?.status == 403 && noCode?.json?["code"] as? String == "no_code", "No code active: refused")
        let code = pairing.startPairing()
        check(code.count == 6 && code.allSatisfy(\.isNumber) && pairing.codeExpires.map { abs($0.timeIntervalSinceNow - 300) < 2 } == true,
              "Code is 6 digits, valid 5 min")
        let plain = await RawHTTP.request("POST", "/api/pair", port: port, json: ["code": code], type: "text/plain")
        check(plain?.status == 415, "Pairing as text/plain (form-style CSRF): 415")
        let cross = await RawHTTP.request("POST", "/api/pair", port: port, json: ["code": code], origin: "http://evil.example")
        check(cross?.status == 403, "Pairing from another origin: 403")
        let wrongCode = code == "000000" ? "000001" : "000000"
        let wrong = await RawHTTP.request("POST", "/api/pair", port: port, json: ["code": wrongCode])
        check(wrong?.status == 401 && wrong?.json?["code"] as? String == "wrong", "Wrong code: 401")
        let good = await RawHTTP.request("POST", "/api/pair", port: port, json: ["code": code], origin: "http://127.0.0.1:\(port)")
        let setCookie = good?.headers["set-cookie"] ?? ""
        check(good?.status == 200, "Right code (same origin): 200")
        check(setCookie.contains("HttpOnly") && setCookie.contains("SameSite=Strict") && setCookie.contains("Path=/"),
              "Cookie is HttpOnly, SameSite=Strict: \(setCookie.replacingOccurrences(of: #"=[A-Za-z0-9_-]{43}"#, with: "=<token>", options: .regularExpression))")
        let token = setCookie.split(separator: ";").first.map { String($0.dropFirst(WebConfig.cookie.count + 1)) } ?? ""
        check(token.count == 43, "Token is 256 random bits (43 base64url chars)")
        let again = await RawHTTP.request("POST", "/api/pair", port: port, json: ["code": code])
        check(again?.status == 403, "Codes are single-use")
        let saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(saved.contains(PairingStore.hash(token)) && !saved.contains(token), "Only the SHA-256 of the token is saved")
        check(saved.contains("\"label\" : \"iPhone · Safari\""), "Saved with a label and date")
        let perms = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o600, "web-devices.json is readable by this user only (\(String(perms, radix: 8)))")
        check(PairingStore(fileURL: file).isAuthorised(token), "Pairing survives a relaunch")

        print("\n== State")
        let stateReply = await RawHTTP.request("GET", "/api/state?focus=now", port: port, cookie: token)
        let state = stateReply?.json ?? [:]
        check(stateReply?.status == 200, "Paired: GET /api/state 200")
        let tv = state["tv"] as? [String: Any] ?? [:]
        let lightsJSON = state["lights"] as? [String: Any] ?? [:]
        let scenesJSON = state["scenes"] as? [String: Any] ?? [:]
        let ps5JSON = state["ps5"] as? [String: Any] ?? [:]
        check(Set(state.keys).isSuperset(of: ["theme", "room", "tv", "lights", "scenes", "ps5", "washer", "weather", "match"]),
              "Top level: \(state.keys.sorted())")
        check(tv["power"] as? String == "on" && (tv["app"] as? [String: Any])?["key"] as? String == "youtube" && tv["volume"] as? Int == 17,
              "TV: power, app on screen, volume")
        check((tv["apps"] as? [[String: Any]])?.count == TVApp.all.count && (tv["inputs"] as? [[String: Any]])?.count == 3,
              "TV: \(TVApp.all.count) apps, 3 inputs")
        check((lightsJSON["bulbs"] as? [[String: Any]])?.count == 4 && (lightsJSON["presets"] as? [[String: Any]])?.count == 6,
              "Lights: 4 bulbs, 5 built-in presets + 1 saved")
        check((scenesJSON["list"] as? [[String: Any]])?.count == SceneConfig.scenes.count && scenesJSON["running"] as? Bool == false,
              "Scenes: \(SceneConfig.scenes.count), none running")
        check(ps5JSON["status"] as? String == "on" && ps5JSON["playing"] as? String == "Sample Game" && (ps5JSON["top"] as? [Any])?.count == 5,
              "PS5: status, now playing, most played")
        check(((state["washer"] as? [String: Any])?["chip"] as? [String: Any])?["free"] as? Bool == false, "Washer: busy chip")
        check((state["weather"] as? [String: Any])?["temp"] as? Int == 14 && (state["match"] as? [String: Any])?["headline"] != nil,
              "Weather and Arsenal")
        let raw = stateReply?.text.lowercased() ?? ""
        check(!["token", "npsso", "secret", "password", "local_key", "1password"].contains { raw.contains($0) }
              && !raw.contains(token.lowercased()), "No credentials or tokens in the state JSON")
        _ = await RawHTTP.request("GET", "/api/state?focus=ps5", port: port, cookie: token)
        try? await Task.sleep(for: .milliseconds(50))
        check(fixture.ps5Refreshes == 1, "Looking at the PS5 tab asks for a fresh PS5 read")
        let lightsReads = fixture.bulbs.calls.filter { $0.method == "lights.status" }.count
        _ = await RawHTTP.request("GET", "/api/state?focus=lights", port: port, cookie: token)
        try? await Task.sleep(for: .milliseconds(200))
        check(fixture.bulbs.calls.filter { $0.method == "lights.status" }.count == lightsReads + 1, "Looking at the Lights tab reads the bulbs")
        fixture.dark = false
        let light = await RawHTTP.request("GET", "/api/state", port: port, cookie: token)
        check(light?.json?["theme"] as? String == "light", "Theme follows the app's appearance")
        fixture.dark = true

        print("\n== Actions")
        func post(_ path: String, _ body: [String: Any] = [:]) async -> RawHTTP.Reply? {
            let r = await RawHTTP.request("POST", path, port: port, cookie: token, json: body)
            try? await Task.sleep(for: .milliseconds(30))
            return r
        }
        var r = await post("/api/tv/key", ["key": "KEY_UP"])
        check(r?.status == 200 && fixture.controls.calls.last == "tv.key KEY_UP", "tv/key KEY_UP")
        r = await post("/api/tv/key", ["key": "KEY_FACTORY"])
        check(r?.status == 400 && fixture.controls.calls.count == 1, "tv/key outside the allowlist: 400")
        r = await post("/api/tv/app", ["app": "netflix"])
        check(r?.status == 200 && fixture.controls.calls.last == "tv.launch netflix", "tv/app netflix")
        r = await post("/api/tv/app", ["app": "../../etc"])
        check(r?.status == 400, "tv/app unknown: 400")
        r = await post("/api/tv/input", ["id": "HDMI2"])
        let afterInput = await RawHTTP.request("GET", "/api/state", port: port, cookie: token)
        check(r?.status == 200 && fixture.controls.calls.last == "tv.input HDMI2"
              && (afterInput?.json?["tv"] as? [String: Any])?["input"] as? String == "HDMI2", "tv/input HDMI2, and the state shows it")
        r = await post("/api/tv/input", ["id": "HDMI9"])
        check(r?.status == 400, "tv/input unknown: 400")
        r = await post("/api/tv/power", ["on": false])
        check(r?.status == 200 && fixture.controls.calls.last == "tv.power false" && fixture.tv.power == .standby, "tv/power off")
        r = await post("/api/tv/key", ["key": "KEY_UP"])
        check(r?.status == 409, "Keys while the TV is off: 409, like the panel's disabled remote")
        r = await post("/api/tv/power", ["on": true])
        check(r?.status == 200 && fixture.controls.calls.last == "tv.power true", "tv/power on")
        r = await post("/api/tv/power")
        check(r?.status == 400, "tv/power without on/off: 400")

        r = await post("/api/lights/power", ["on": false])
        try? await Task.sleep(for: .milliseconds(150))
        check(r?.status == 200 && fixture.bulbs.calls.last?.method == "lights.off" && fixture.bulbs.calls.last?.params["target"] as? String == "all"
              && fixture.bulbs.bulbs.values.allSatisfy { !$0.on }, "lights/power off, all lights")
        r = await post("/api/lights/power", ["on": true, "index": 3])
        try? await Task.sleep(for: .milliseconds(150))
        check(r?.status == 200 && fixture.bulbs.bulbs[3]?.on == true && fixture.bulbs.bulbs[1]?.on == false, "lights/power on, one light")
        r = await post("/api/lights/brightness", ["pct": 40])
        try? await Task.sleep(for: .milliseconds(450))
        check(r?.status == 200 && fixture.bulbs.calls.last?.method == "lights.brightness" && fixture.bulbs.calls.last?.params["pct"] as? Int == 40,
              "lights/brightness 40% (debounced like the slider)")
        r = await post("/api/lights/temp", ["pct": 250, "index": 2])
        try? await Task.sleep(for: .milliseconds(450))
        check(r?.status == 200 && fixture.bulbs.calls.last?.params["pct"] as? Int == 100 && fixture.bulbs.bulbs[2]?.temp == 100,
              "lights/temp clamps to 100")
        r = await post("/api/lights/colour", ["hex": "#1F4DFF"])
        try? await Task.sleep(for: .milliseconds(450))
        check(r?.status == 200 && fixture.bulbs.calls.last?.params["value"] as? String == "1f4dff", "lights/colour")
        r = await post("/api/lights/colour", ["hex": "javascript:"])
        check(r?.status == 400, "lights/colour bad hex: 400")
        r = await post("/api/lights/power", ["on": true, "index": 99])
        check(r?.status == 400, "lights unknown index: 400")
        let applies = fixture.bulbs.applyCalls.count
        r = await post("/api/lights/preset", ["id": "relax"])
        try? await Task.sleep(for: .milliseconds(250))
        check(r?.status == 200 && fixture.bulbs.applyCalls.count == applies + 1 && fixture.bulbs.bulbs.values.allSatisfy { $0.brightness == 45 },
              "lights/preset Relax applies to every bulb")
        let saved0 = fixture.lights.presets.slots[0]!
        r = await post("/api/lights/preset", ["id": saved0.id])
        try? await Task.sleep(for: .milliseconds(250))
        check(r?.status == 200 && fixture.bulbs.applyCalls.count == applies + 2 && fixture.bulbs.bulbs[2]?.on == false, "lights/preset saved one")
        r = await post("/api/lights/preset", ["id": "nope"])
        check(r?.status == 400, "lights/preset unknown: 400")
        let slotsJSON = lightsJSON["slots"] as? [Any] ?? []
        check(slotsJSON.count == PresetStore.slotCount && (slotsJSON[0] as? [String: Any])?["name"] as? String == "Reading"
              && slotsJSON[1] is NSNull, "State lists the 5 slots by name")
        try? await Task.sleep(for: .milliseconds(300))
        r = await post("/api/presets/save", ["slot": 3, "name": "  Sofa   time "])
        check(r?.status == 200 && fixture.lights.presets.slots[3]?.name == "Sofa time" && fixture.lights.presets.slots[3]?.looks.count == 4,
              "presets/save captures the bulbs into slot 4, name tidied")
        r = await post("/api/presets/rename", ["slot": 3, "name": "Reading nook"])
        check(r?.status == 200 && fixture.lights.presets.slots[3]?.name == "Reading nook", "presets/rename")
        r = await post("/api/presets/rename", ["slot": 4, "name": "x"])
        check(r?.status == 409, "Renaming an empty slot: 409")
        for bad: [String: Any] in [["slot": 5], ["slot": -1], ["slot": "1"], ["slot": 1, "name": 7], [:]] {
            r = await post("/api/presets/rename", bad)
            check(r?.status == 400, "presets refuse \(bad)")
        }
        r = await post("/api/presets/import", ["slots": []])
        check(r?.status == 404, "The Mac's server has no import route (that's the hub's)")
        let crossClear = await RawHTTP.request("POST", "/api/presets/clear", port: port, cookie: token, json: ["slot": 3], origin: "http://evil.example")
        check(crossClear?.status == 403 && fixture.lights.presets.slots[3] != nil, "presets/clear from another Origin: 403")
        let unpairedClear = await RawHTTP.request("POST", "/api/presets/clear", port: port, json: ["slot": 3])
        check(unpairedClear?.status == 401 && fixture.lights.presets.slots[3] != nil, "presets/clear unpaired: 401")
        r = await post("/api/presets/clear", ["slot": 3])
        check(r?.status == 200 && fixture.lights.presets.slots[3] == nil, "presets/clear")
        fixture.bulbs.dead = [1, 2, 3, 4]
        r = await post("/api/presets/save", ["slot": 4, "name": "x"])
        check(r?.status == 502 && fixture.lights.presets.slots[4] == nil && fixture.lights.presetBusy == nil,
              "presets/save with no bulbs answering: 502, slot stays empty")
        fixture.bulbs.dead = []

        let before = fixture.devices.calls.count
        r = await post("/api/scenes/run", ["id": "normal"])
        let busy = await post("/api/scenes/run", ["id": "goodnight"])
        while fixture.scenes.running { try? await Task.sleep(for: .milliseconds(50)) }
        check(r?.status == 200 && fixture.devices.calls.dropFirst(before).contains { $0.what.hasPrefix("lights white(brightness: 100") },
              "scenes/run Back to normal reaches the dry-run devices")
        check(busy?.status == 409, "A second scene while one runs: 409")
        let finished = await RawHTTP.request("GET", "/api/state", port: port, cookie: token)
        check(((finished?.json?["scenes"] as? [String: Any])?["current"] as? [String: Any])?["summary"] as? String == "Done", "Scene run shows as Done")
        r = await post("/api/scenes/clear")
        check(r?.status == 200 && fixture.scenes.current == nil, "scenes/clear")
        r = await post("/api/scenes/run", ["id": "party"])
        check(r?.status == 400, "scenes/run unknown: 400")

        r = await post("/api/ps5/power", ["on": false])
        check(r?.status == 200 && fixture.controls.calls.last == "ps5.power false" && fixture.ps5.status == .rest, "ps5/power rest mode")
        r = await post("/api/ps5/power", ["on": true])
        check(r?.status == 200 && fixture.controls.calls.last == "ps5.power true", "ps5/power on")

        r = await post("/api/washer/notify-free", ["on": true])
        check(r?.status == 200 && fixture.washer.notifyWhenFree, "washer/notify-free on")
        r = await post("/api/washer/claim")
        check(r?.status == 200 && fixture.washer.claim != nil && !fixture.washer.notifyWhenFree, "washer/claim")
        let claimed = await RawHTTP.request("GET", "/api/state", port: port, cookie: token)
        check(((claimed?.json?["washer"] as? [String: Any])?["bar"] as? [String: Any])?["kind"] as? String == "running", "Claimed cycle shows as a bar")
        r = await post("/api/washer/unclaim")
        check(r?.status == 200 && fixture.washer.claim == nil, "washer/unclaim")
        fixture.washer.status = .done("2026-10-16T10:00:00Z")
        r = await post("/api/washer/claim")
        check(r?.status == 409, "washer/claim when it's free: 409")

        print("\n== Page script")
        switch jsSyntax(WebUI.page) {
        case nil: print("  skip jsc not found, script not parsed")
        case let errors?: check(errors.isEmpty, "The page's script parses (jsc checkSyntax)\(errors.isEmpty ? "" : ": \(errors)")")
        }
        if let errors = jsSyntax("<script>const a = 'it's';</script>") {
            check(errors.count == 1, "…and the check catches an apostrophe in a single-quoted string")
        }

        print("\n== Request limits")
        let crossPost = await RawHTTP.request("POST", "/api/tv/key", port: port, cookie: token, json: ["key": "KEY_UP"], origin: "http://evil.example")
        check(crossPost?.status == 403, "Paired cookie but another Origin: 403")
        let formPost = await RawHTTP.request("POST", "/api/tv/key", port: port, cookie: token, json: ["key": "KEY_UP"], type: "application/x-www-form-urlencoded")
        check(formPost?.status == 415, "Form-encoded POST: 415")
        let huge = await RawHTTP.request("POST", "/api/tv/key", port: port, cookie: token, extra: ["Content-Type: application/json", "Content-Length: 900000"])
        check(huge?.status == 413, "Oversized body: 413")
        let get = await RawHTTP.request("PUT", "/api/tv/key", port: port, cookie: token, json: [:])
        check(get?.status == 405, "Other methods: 405")

        print("\n== Rate limits")
        let attempt = pairing.startPairing()
        let wrongAttempt = attempt == "999999" ? "999998" : "999999"
        pairing.now = { Date().addingTimeInterval(3600) }
        for _ in 0..<PairingStore.wrongCodesAllowed { _ = pairing.pair(code: wrongAttempt, label: "t", from: "192.168.0.50") }
        check(pairing.activeCode == nil && pairing.pair(code: attempt, label: "t", from: "192.168.0.51") == .noCode,
              "5 wrong codes void the code, even the right one after")
        _ = pairing.startPairing()
        for _ in 0..<PairingStore.attemptsPerAddress { _ = pairing.pair(code: "1", label: "t", from: "192.168.0.60") }
        check(pairing.pair(code: "1", label: "t", from: "192.168.0.60") == .limited, "10 tries per address per 10 min, then 429")
        pairing.now = { Date().addingTimeInterval(3600 + 5 * 60 + 1) }
        check(pairing.activeCode == nil, "Codes expire after 5 min")
        pairing.now = Date.init
        pairing.cancelPairing()

        print("\n== Forget")
        pairing.forgetAll()
        let forgotten = await RawHTTP.request("GET", "/api/state", port: port, cookie: token)
        check(forgotten?.status == 401, "Forget paired devices: the old cookie stops working")
        check(PairingStore(fileURL: file).devices.isEmpty, "…and the file is emptied")

        server.stop()
        return failures
    }

    /// Parses the page's inline scripts with macOS's jsc. Nil when jsc isn't installed.
    static func jsSyntax(_ page: String) -> [String]? {
        let jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
        guard FileManager.default.isExecutableFile(atPath: jsc),
              let re = try? NSRegularExpression(pattern: "<script(?![^>]*\\bsrc=)[^>]*>(.*?)</script>", options: [.dotMatchesLineSeparators])
        else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("web-dryrun-js-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var errors: [String] = []
        let ns = page as NSString
        for (i, m) in re.matches(in: page, range: NSRange(location: 0, length: ns.length)).enumerated() {
            let file = dir.appendingPathComponent("script-\(i).js")
            guard (try? ns.substring(with: m.range(at: 1)).write(to: file, atomically: true, encoding: .utf8)) != nil else {
                errors.append("script \(i): couldn't write it out")
                continue
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: jsc)
            p.arguments = ["-e", "checkSyntax('\(file.path)')"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationStatus != 0 { errors.append("script \(i): \(text.prefix(300))") }
        }
        return errors
    }

    // MARK: Snapshots

    @MainActor private static func snapshot(dir: URL) async -> Bool {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let fixture = WebFixture(devicesFile: file)
        await fixture.prepare()
        fixture.scenes.current = {
            var run = SceneRun(scene: SceneConfig.scenes[1], steps: fixture.scenes.steps(for: SceneConfig.scenes[1]))
            run.steps[0].status = .done(nil)
            run.steps[1].status = .done("On after 9 s")
            run.steps[2].status = .running
            run.steps[3].status = .warning("The PS5 isn't answering on the network (fully off?).")
            return run
        }()
        let server = WebServer(handler: { await fixture.api.handle($0) })
        server.start(preferred: 0)
        guard let port = await server.waitReady() else { return false }
        _ = fixture.pairing.startPairing()
        guard case .paired(let token) = fixture.pairing.pair(code: fixture.pairing.activeCode ?? "", label: "Snapshot", from: "127.0.0.1") else { return false }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = true
        for dark in [true, false] {
            fixture.dark = dark
            for tab in ["now", "apps", "scenes", "lights", "ps5", "pair"] {
                let name = "\(dark ? "dark" : "light")-\(tab).png"
                let shot = await WebShot.capture(url: URL(string: "http://127.0.0.1:\(port)/#\(tab)")!,
                                                 cookie: tab == "pair" ? nil : (WebConfig.cookie, token, port))
                if let shot {
                    try? shot.write(to: dir.appendingPathComponent(name))
                    print("  wrote \(name)")
                } else {
                    print("  FAIL \(name)")
                    ok = false
                }
            }
        }
        server.stop()
        return ok
    }
}

/// Loads a page in an offscreen WKWebView at iPhone width (390 pt) and returns a full-height PNG at 2×.
@MainActor
final class WebShot: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Never>?

    static func capture(url: URL, cookie: (name: String, value: String, port: UInt16)?) async -> Data? {
        let shot = WebShot()
        return await shot.run(url: url, cookie: cookie)
    }

    private func run(url: URL, cookie: (name: String, value: String, port: UInt16)?) async -> Data? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // An offscreen window reports the page as hidden, which pauses polling.
        config.userContentController.addUserScript(WKUserScript(source: """
            Object.defineProperty(document, 'hidden', {get: () => false});
            window.__errors = [];
            addEventListener('error', e => __errors.push(e.message + ' @' + e.lineno));
            addEventListener('unhandledrejection', e => __errors.push('rejection: ' + e.reason));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let cookie, let c = HTTPCookie(properties: [.name: cookie.name, .value: cookie.value, .domain: "127.0.0.1", .path: "/"]) {
            await config.websiteDataStore.httpCookieStore.setCookie(c)
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 390, height: 844), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        web.navigationDelegate = self
        await withCheckedContinuation { cont in
            loaded = cont
            web.load(URLRequest(url: url))
        }
        try? await Task.sleep(for: .milliseconds(1200))
        if let errors = try? await web.evaluateJavaScript("__errors.concat(['app hidden ' + $('#app').hidden, 'pair hidden ' + $('#pair').hidden]).join(' | ')") as? String {
            print("    page: \(errors)")
        }
        let height = (try? await web.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, 844)") as? Double) ?? 844
        let full = min(height, 4000)
        window.setContentSize(NSSize(width: 390, height: full))
        web.frame = NSRect(x: 0, y: 0, width: 390, height: full)
        try? await Task.sleep(for: .milliseconds(500))
        let configShot = WKSnapshotConfiguration()
        configShot.rect = NSRect(x: 0, y: 0, width: 390, height: full)
        guard let image = try? await web.takeSnapshot(configuration: configShot),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { window.close(); return nil }
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }
}
