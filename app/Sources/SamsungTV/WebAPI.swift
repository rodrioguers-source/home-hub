import Foundation
import SwiftUI

/// The TV and PS5 commands the phone can send. Lights, scenes and the washer go through their own models,
/// which already take fake transports in the dry runs.
@MainActor
protocol WebControls: AnyObject {
    func tvPower(on: Bool)
    func tvKey(_ key: String)
    func tvLaunch(_ app: TVApp)
    /// Through SmartThings when it's usable; the PS5 input falls back to KEY_HDMI like the panel's button.
    func tvInput(_ id: String)
    func ps5Power(on: Bool)
}

@MainActor
final class LiveWebControls: WebControls {
    private let tv: TVModel
    private let ps5: PS5Model

    init(tv: TVModel, ps5: PS5Model) {
        self.tv = tv
        self.ps5 = ps5
    }

    func tvPower(on: Bool) { if on { tv.powerOn() } else { tv.powerOff() } }
    func tvKey(_ key: String) { tv.key(key) }
    func tvLaunch(_ app: TVApp) { tv.launch(app) }

    func tvInput(_ id: String) {
        let st = tv.smartThings
        let fallback = id == SceneConfig.ps5Input
        guard st.usable else {
            if fallback { tv.key("KEY_HDMI") }
            return
        }
        Task { if await st.setInput(id) != nil, fallback { tv.key("KEY_HDMI") } }
    }

    func ps5Power(on: Bool) { Task { await ps5.setPower(on: on) } }
}

// MARK: State

struct WebState: Encodable {
    struct App: Encodable { let key, name, short, colour: String; let running: Bool }
    struct Input: Encodable { let id, name, label, kind: String }
    struct TV: Encodable {
        let power: String
        let waking: Bool
        let status: String
        let remote: String
        let remoteReady: Bool
        let app: App?
        let caption: String
        let launching: String?
        let apps: [App]
        let favourites: [String]
        let inputs: [Input]
        let input: String?
        let inputBusy: String?
        let smartThings: Bool
        let volume: Int?
        let muted: Bool
        let notice: String?
    }
    struct Bulb: Encodable { let index: Int; let label, subtitle, glow: String; let on, reachable: Bool; let brightness, temp: Int; let colour: String? }
    struct Preset: Encodable { let id, name, summary: String; let active, builtIn: Bool; let swatches: [String?]; let level: Double }
    struct Swatch: Encodable { let name, hex: String }
    struct Result: Encodable { let id: String; let text: String?; let failed: Bool }
    struct Slot: Encodable { let id, name: String }
    struct Lights: Encodable {
        let state: String
        let message: String?
        let anyOn: Bool
        let subtitle: String
        let brightness: Int
        let temp: Int
        let enabled: Bool
        let bulbs: [Bulb]
        let presets: [Preset]
        let busy: String?
        let result: Result?
        let error: String?
        let slots: [Slot?]
        let swatches: [Swatch]
    }
    struct Scene: Encodable { let id, name, subtitle, icon, from, to: String; let app: String? }
    struct Step: Encodable { let label: String; let track: Int; let status: String; let detail: String? }
    struct Run: Encodable { let id, name, summary: String; let finished, failed, warned: Bool; let tracks: Int; let steps: [Step] }
    struct Scenes: Encodable { let running: Bool; let list: [Scene]; let current: Run? }
    struct Title: Encodable { let name, time: String; let fraction: Double; let art: Bool }
    struct PS5: Encodable {
        let status: String
        let polled: Bool
        let busy: Bool
        let error: String?
        let name: String
        let host: String
        let psn: String
        let psnError: String?
        let onlineId: String?
        let playing: String?
        let online: Bool
        let caption: String
        let art: Bool
        let top: [Title]
        let tvOn: Bool
        let switchNote: String
    }
    struct Chip: Encodable { let short, sentence: String; let free, notify: Bool }
    struct Bar: Encodable { let kind, title, trailing: String; let segments: [[Double]]; let note: String? }
    struct Washer: Encodable { let chip: Chip?; let bar: Bar?; let detail: String }
    struct Weather: Encodable { let temp: Int; let summary, emoji, range, place: String }
    struct MatchInfo: Encodable { let headline, detail, title: String; let live: String? }

    let theme: String
    let room: String
    let tv: TV
    let lights: Lights
    let scenes: Scenes
    let ps5: PS5
    let washer: Washer?
    let weather: Weather?
    let match: MatchInfo?
}

// MARK: API

@MainActor
final class WebAPI {
    static let keys: Set<String> = [
        "KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT", "KEY_ENTER", "KEY_RETURN", "KEY_HOME", "KEY_MENU", "KEY_EXIT",
        "KEY_VOLUP", "KEY_VOLDOWN", "KEY_MUTE", "KEY_SOURCE", "KEY_HDMI", "KEY_PLAY", "KEY_PAUSE", "KEY_STOP",
        "KEY_REWIND", "KEY_FF", "KEY_CHUP", "KEY_CHDOWN",
    ]

    let tv: TVModel
    let ps5: PS5Model
    let lights: LightsModel
    let scenes: SceneRunner
    let washer: WasherModel
    let weather: WeatherModel
    let match: MatchModel
    let controls: WebControls
    let pairing: PairingStore
    var scheme: () -> ColorScheme
    /// Fresh PS5 status and PSN for a phone on the PS5 tab. The dry run swaps it so nothing probes the console.
    lazy var refreshPS5: @MainActor () async -> Void = { [weak self] in
        await self?.ps5.probe()
        await self?.ps5.refreshPSN()
    }

    private var lightsAskedAt = Date.distantPast
    private var ps5AskedAt = Date.distantPast
    private var art: [String: (data: Data, type: String)] = [:]
    private var icons: [Int: Data] = [:]

    init(tv: TVModel, ps5: PS5Model, lights: LightsModel, scenes: SceneRunner, washer: WasherModel,
         weather: WeatherModel = .shared, match: MatchModel = .shared, controls: WebControls, pairing: PairingStore,
         scheme: @escaping () -> ColorScheme) {
        self.tv = tv
        self.ps5 = ps5
        self.lights = lights
        self.scenes = scenes
        self.washer = washer
        self.weather = weather
        self.match = match
        self.controls = controls
        self.pairing = pairing
        self.scheme = scheme
    }

    func handle(_ r: HTTPRequest) async -> HTTPResponse {
        guard hostAllowed(r.headers["host"]) else { return .text(421, "Unknown host.") }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            let dark = scheme() == .dark
            let page = WebUI.page.replacingOccurrences(of: "{{THEME}}", with: dark ? "dark" : "light")
                .replacingOccurrences(of: "{{BAR}}", with: dark ? "#111215" : "#1428A0")
                .replacingOccurrences(of: "{{ROOM}}", with: TVConfig.room)
            return .text(200, page, type: "text/html; charset=utf-8")
        case ("GET", "/manifest.webmanifest"):
            return .json(WebUI.manifest(room: TVConfig.room))
                .with(type: "application/manifest+json")
        case ("GET", "/icon-180.png"), ("GET", "/apple-touch-icon.png"):
            return icon(180)
        case ("GET", "/icon-512.png"):
            return icon(512)
        case ("POST", "/api/pair"):
            if let refused = postRefusal(r) { return refused }
            return pair(r)
        default:
            break
        }
        guard r.path.hasPrefix("/api/") else { return .text(404, "Not found.") }
        let token = r.cookie(WebConfig.cookie)
        guard pairing.isAuthorised(token) else {
            let seen = token.map { "cookie \(PairingStore.hash($0).prefix(8)) (\($0.count) chars)" } ?? "no cookie"
            AppLog.write("web: unpaired \(r.method) \(r.path) from \(r.remote) host \(r.headers["host"] ?? "-"): \(seen); "
                         + "\(pairing.devices.count) here, \(pairing.hubDevices.count) mirrored from the hub")
            return .error(401, "This device isn't paired.", code: "unpaired")
        }
        if r.method == "GET" {
            if r.path == "/api/state" { return state(focus: r.query["focus"]) }
            if r.path.hasPrefix("/api/art/") { return await artwork(String(r.path.dropFirst("/api/art/".count))) }
            return .text(404, "Not found.")
        }
        guard r.method == "POST" else { return .error(405, "Method not allowed.") }
        if let refused = postRefusal(r) { return refused }
        if r.path.hasPrefix("/api/presets/") { return await presetAction(r.path, r.json() ?? [:]) }
        return act(r.path, r.json() ?? [:])
    }

    /// Save, rename and clear for the custom slots. With "Use home hub" on these go to the hub, which keeps the list.
    private func presetAction(_ path: String, _ b: [String: Any]) async -> HTTPResponse {
        guard ["/api/presets/save", "/api/presets/rename", "/api/presets/clear"].contains(path) else { return .text(404, "Not found.") }
        guard let slot = b["slot"] as? Int, (0..<PresetStore.slotCount).contains(slot) else {
            return .error(400, "Pick a slot from 1 to 5.")
        }
        if b["name"] != nil, !(b["name"] is String) { return .error(400, "The name must be text.") }
        let store = lights.presets
        if !store.editable { return .error(503, PresetStore.offlineNote, code: "hub_offline") }
        if store.onHub, let remote = store.remote {
            do {
                return .json(try await remote.presetRequest(path, b))
            } catch HomeHelper.Failure.remote(let message, let code) {
                return .error(code == "busy" ? 409 : 502, message, code: code)
            } catch {
                return .error(502, error.localizedDescription)
            }
        }
        let name = store.cleanName(b["name"] as? String, slot: slot)
        switch path {
        case "/api/presets/save":
            guard lights.presetBusy == nil else { return .error(409, "A preset is already being applied.", code: "busy") }
            lights.presetBusy = PresetStore.slotID(slot)
            defer { lights.presetBusy = nil }
            do {
                let (looks, missing) = try await lights.captureLooks()
                store.save(slot, name: name, looks: looks)
                var out: [String: Any] = ["ok": true, "id": store.slots[slot]?.id ?? "", "name": name]
                if !missing.isEmpty { out["note"] = "Saved without \(LightsModel.list(missing)) (didn't respond)." }
                return .json(out)
            } catch {
                return .error(502, "Couldn't read the lights: \(HubLink.describe(error))")
            }
        case "/api/presets/rename":
            guard store.slots[slot] != nil else { return .error(409, "That slot is empty.", code: "empty") }
            store.rename(slot, to: name)
            return .json(["ok": true, "name": name])
        default:
            store.delete(slot)
            return .json(["ok": true])
        }
    }

    // MARK: Checks

    /// Guards against DNS rebinding: only names this Mac actually answers to.
    private func hostAllowed(_ header: String?) -> Bool {
        guard let header else { return false }
        var host = header.lowercased()
        if host.hasPrefix("[") { return false }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        var allowed: Set<String> = ["localhost", "127.0.0.1"]
        allowed.formUnion(LANAddress.ownAddresses())
        if let name = LANAddress.localHostName?.lowercased() { allowed.insert(name) }
        allowed.insert(HomeName.host)
        return allowed.contains(host)
    }

    /// JSON-only bodies and same-origin requests, so another page on the LAN can't post a form at the server.
    private func postRefusal(_ r: HTTPRequest) -> HTTPResponse? {
        guard r.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .error(415, "Send JSON.")
        }
        if let origin = r.headers["origin"], origin != "http://\(r.headers["host"] ?? "")" {
            return .error(403, "Cross-origin requests aren't allowed.")
        }
        return nil
    }

    // MARK: Pairing

    private func pair(_ r: HTTPRequest) -> HTTPResponse {
        let code = (r.json()?["code"] as? String ?? "").filter(\.isNumber)
        switch pairing.pair(code: code, label: Self.label(userAgent: r.headers["user-agent"]), from: r.remote) {
        case .paired(let token):
            return HTTPResponse.json(["ok": true]).adding("Set-Cookie",
                "\(WebConfig.cookie)=\(token); Path=/; Max-Age=34560000; HttpOnly; SameSite=Strict")
        case .wrong: return .error(401, "That code isn't right. Check the Mac and try again.", code: "wrong")
        case .noCode: return .error(403, "No pairing code is active. On the Mac, choose Pair a phone… first.", code: "no_code")
        case .limited: return .error(429, "Too many tries. Wait a few minutes.", code: "limited")
        }
    }

    static func label(userAgent: String?) -> String {
        let ua = userAgent ?? ""
        let device = ua.contains("iPhone") ? "iPhone" : ua.contains("iPad") ? "iPad" : ua.contains("Android") ? "Android"
            : ua.contains("Macintosh") ? "Mac" : "Browser"
        return device + (ua.contains("CriOS") || ua.contains("Chrome") ? " · Chrome" : ua.contains("Safari") ? " · Safari" : "")
    }

    // MARK: Actions

    private func act(_ path: String, _ b: [String: Any]) -> HTTPResponse {
        let ok = HTTPResponse.json(["ok": true])
        let tvOff = HTTPResponse.error(409, "The TV isn't on.", code: "tv_off")
        switch path {
        case "/api/tv/power":
            guard let on = b["on"] as? Bool else { return .error(400, "Say on or off.") }
            controls.tvPower(on: on)
        case "/api/tv/key":
            guard let key = b["key"] as? String, Self.keys.contains(key) else { return .error(400, "Unknown key.") }
            guard tv.power == .on else { return tvOff }
            controls.tvKey(key)
        case "/api/tv/app":
            guard let app = (b["app"] as? String).flatMap(TVApp.byKey) else { return .error(400, "Unknown app.") }
            guard tv.power == .on else { return tvOff }
            controls.tvLaunch(app)
        case "/api/tv/input":
            let known = (tv.smartThings.status?.inputs ?? []).map(\.id) + [SceneConfig.ps5Input]
            guard let id = b["id"] as? String, known.contains(id) else { return .error(400, "Unknown input.") }
            guard tv.power == .on else { return tvOff }
            controls.tvInput(id)
        case "/api/lights/power", "/api/lights/brightness", "/api/lights/temp", "/api/lights/colour":
            return lightsAction(path, b)
        case "/api/lights/preset":
            let all = PresetConfig.builtIns + lights.presets.slots.compactMap { $0 }
            guard let preset = all.first(where: { $0.id == b["id"] as? String }) else { return .error(400, "Unknown preset.") }
            guard lights.presetBusy == nil else { return .error(409, "A preset is already being applied.", code: "busy") }
            Task { await lights.runPreset(preset) }
        case "/api/scenes/run":
            guard let scene = SceneConfig.scenes.first(where: { $0.id == b["id"] as? String }) else { return .error(400, "Unknown scene.") }
            guard !scenes.running else { return .error(409, "Another scene is running.", code: "busy") }
            scenes.run(scene)
        case "/api/scenes/clear":
            scenes.dismiss()
        case "/api/ps5/power":
            guard let on = b["on"] as? Bool else { return .error(400, "Say on or off.") }
            guard !ps5.powerBusy else { return .error(409, "Already changing power.", code: "busy") }
            controls.ps5Power(on: on)
        case "/api/washer/claim":
            guard washer.status?.active == true else { return .error(409, "The washer isn't running.", code: "idle") }
            washer.claimCurrent()
        case "/api/washer/unclaim":
            washer.unclaim()
        case "/api/washer/notify-free":
            guard let on = b["on"] as? Bool else { return .error(400, "Say on or off.") }
            washer.setNotifyWhenFree(on)
        default:
            return .text(404, "Not found.")
        }
        return ok
    }

    private func lightsAction(_ path: String, _ b: [String: Any]) -> HTTPResponse {
        var index: Int?
        if let raw = b["index"], !(raw is NSNull) {
            guard let i = raw as? Int, lights.bulbs.contains(where: { $0.id == i }) else { return .error(400, "Unknown light.") }
            index = i
        }
        func pct() -> Double? { (b["pct"] as? NSNumber).map { min(max($0.doubleValue, 0), 100) } }
        switch path {
        case "/api/lights/power":
            guard let on = b["on"] as? Bool else { return .error(400, "Say on or off.") }
            lights.setPower(index, on: on)
        case "/api/lights/brightness":
            guard let p = pct() else { return .error(400, "Give a percentage.") }
            lights.setBrightness(index, max(p, 1))
        case "/api/lights/temp":
            guard let p = pct() else { return .error(400, "Give a percentage.") }
            lights.setTemp(index, p)
        default:
            guard let hex = (b["hex"] as? String)?.lowercased().replacingOccurrences(of: "#", with: ""),
                  hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return .error(400, "Give a colour as six hex digits.") }
            lights.setColour(index, hex: hex)
        }
        return .json(["ok": true])
    }

    // MARK: State

    /// The lights and PSN only poll while their Mac tab is open, so a phone looking at them asks for fresh reads.
    private func refresh(for focus: String?) {
        let now = Date()
        if focus == "lights" || !lights.loaded, now.timeIntervalSince(lightsAskedAt) > LightsConfig.pollInterval, !lights.refreshing {
            lightsAskedAt = now
            Task { await lights.refresh() }
        }
        if focus == "ps5", now.timeIntervalSince(ps5AskedAt) > PS5Config.visiblePoll {
            ps5AskedAt = now
            Task { await refreshPS5() }
        }
    }

    func snapshot() -> WebState {
        WebState(theme: scheme() == .dark ? "dark" : "light", room: TVConfig.room, tv: tvState(), lights: lightsState(),
                 scenes: scenesState(), ps5: ps5State(), washer: washerState(), weather: weatherState(), match: matchState())
    }

    private func state(focus: String?) -> HTTPResponse {
        refresh(for: focus)
        return .encoded(snapshot())
    }

    private func appRef(_ app: TVApp) -> WebState.App {
        WebState.App(key: app.key, name: app.name, short: app.short, colour: String(format: "%06x", app.color),
                     running: tv.runningApps.contains(app.id))
    }

    private func tvState() -> WebState.TV {
        let st = tv.smartThings
        let apps = tv.installed.isEmpty ? TVApp.all : TVApp.all.filter { tv.installed[$0] != nil }
        let inputs = st.usable ? (st.status?.inputs ?? []) : []
        let kind: (STOption) -> String = { $0.id == SceneConfig.ps5Input ? "ps5" : InputsCard.consoles[$0.id] != nil ? "console" : $0.id.lowercased().hasPrefix("hdmi") ? "hdmi" : "tv" }
        let power = switch tv.power { case .on: "on"; case .standby: "standby"; case .unreachable: "unreachable" }
        return WebState.TV(power: power, waking: tv.waking, status: tv.statusText, remote: tv.remoteStatusText,
                           remoteReady: tv.socketState == .ready, app: tv.currentApp.map(appRef), caption: tv.nowCaption,
                           launching: tv.launching?.key, apps: apps.map(appRef), favourites: TVApp.favourites.map(\.key),
                           inputs: inputs.map { WebState.Input(id: $0.id, name: $0.name, label: InputsCard.label($0), kind: kind($0)) },
                           input: tv.activeInput?.id, inputBusy: st.busy.flatMap { $0.hasPrefix("input:") ? String($0.dropFirst(6)) : nil },
                           smartThings: st.usable, volume: st.usable ? st.status?.volume.map { Int($0.rounded()) } : nil,
                           muted: st.usable && st.status?.mute == "muted", notice: st.notice)
    }

    private func lightsState() -> WebState.Lights {
        let state = lights.unavailable != nil ? "unavailable" : (!lights.loaded && lights.bulbs.isEmpty) ? "loading"
            : lights.bulbs.isEmpty ? "empty" : "ok"
        let labels = Dictionary(uniqueKeysWithValues: lights.bulbs.map { ($0.id, $0.label) })
        let presets = (PresetConfig.builtIns + lights.presets.slots.compactMap { $0 }).map { p in
            let level = p.looks.isEmpty ? 1 : Double(p.looks.map { $0.on ? $0.brightness : 0 }.reduce(0, +)) / Double(p.looks.count) / 100
            return WebState.Preset(id: p.id, name: p.name, summary: p.summary(labels: labels), active: p.isActive(on: lights.bulbs),
                                   builtIn: p.isBuiltIn, swatches: p.looks.map(\.hex), level: level)
        }
        let bulbs = lights.bulbs.map { b in
            WebState.Bulb(index: b.id, label: b.label, subtitle: b.subtitle,
                          glow: b.colour.map { String($0.dropFirst()) } ?? LightColour.whiteHex(temp: b.temp),
                          on: b.on, reachable: b.reachable, brightness: Int(b.brightness.rounded()), temp: Int(b.temp.rounded()),
                          colour: b.colour.map { String($0.dropFirst()) })
        }
        return WebState.Lights(state: state, message: lights.unavailable, anyOn: lights.anyOn, subtitle: lights.masterSubtitle,
                               brightness: Int(lights.masterBrightness.rounded()), temp: Int(lights.masterTemp.rounded()),
                               enabled: !lights.reachable.isEmpty, bulbs: bulbs, presets: presets, busy: lights.presetBusy,
                               result: lights.presetResult.map { WebState.Result(id: $0.id, text: $0.text, failed: $0.failed) },
                               error: lights.lastError, slots: lights.presets.slots.map { $0.map { WebState.Slot(id: $0.id, name: $0.name) } },
                               swatches: LightsConfig.swatches.map { WebState.Swatch(name: $0.name, hex: $0.hex) })
    }

    private func scenesState() -> WebState.Scenes {
        let icons = ["popcorn.fill": "film", "gamecontroller.fill": "gamepad", "moon.stars.fill": "moon", "sun.max.fill": "sun"]
        let list = SceneConfig.scenes.map { s in
            WebState.Scene(id: s.id, name: s.name, subtitle: s.subtitle, icon: icons[s.icon] ?? "sparkles",
                           from: String(format: "%06x", s.colours.0), to: String(format: "%06x", s.colours.1), app: scenes.app(for: s)?.name)
        }
        let current = scenes.current.map { run in
            WebState.Run(id: run.scene.id, name: run.scene.name, summary: run.summary, finished: run.finished, failed: run.failed,
                         warned: run.warned, tracks: Set(run.steps.map(\.track)).count,
                         steps: run.steps.map { step in
                             let (status, detail): (String, String?) = switch step.status {
                             case .pending: ("pending", nil)
                             case .running: ("running", nil)
                             case .done(let t): ("done", t)
                             case .warning(let t): ("warning", t)
                             case .failed(let t): ("failed", t)
                             case .skipped(let t): ("skipped", t)
                             }
                             return WebState.Step(label: step.label, track: step.track, status: status, detail: detail)
                         })
        }
        return WebState.Scenes(running: scenes.running, list: list, current: current)
    }

    private func ps5State() -> WebState.PS5 {
        let status = switch ps5.status { case .on: "on"; case .rest: "rest"; case .off: "off" }
        let summary = ps5.psn
        let psn: String, psnError: String?
        if let summary, !summary.configured { (psn, psnError) = ("connect", nil) }
        else if let summary, summary.state != "ready" && summary.mostPlayed == nil { (psn, psnError) = ("error", summary.error ?? "PSN isn't available right now.") }
        else if let summary { (psn, psnError) = ("ready", summary.error) }
        else if let error = ps5.psnHelperError { (psn, psnError) = ("error", error) }
        else { (psn, psnError) = ("loading", nil) }
        let titles = summary?.mostPlayed ?? []
        let top = Double(max(titles.first?.seconds ?? 1, 1))
        let st = tv.smartThings
        return WebState.PS5(status: status, polled: ps5.hasPolled, busy: ps5.powerBusy, error: ps5.powerError,
                            name: PS5Config.name, host: PS5Config.host, psn: psn, psnError: psnError, onlineId: summary?.onlineId,
                            playing: summary?.presence?.title, online: summary?.presence?.onlineStatus == "online",
                            caption: ps5.playingCaption, art: summary?.presence?.icon != nil,
                            top: titles.prefix(5).map { WebState.Title(name: $0.name ?? "Unknown title", time: PS5Model.hours($0.seconds),
                                                                      fraction: Double($0.seconds) / top, art: $0.image != nil) },
                            tvOn: tv.power == .on,
                            switchNote: tv.power != .on ? "The TV needs to be on"
                                : st.usable ? "Sets the \(TVConfig.room) TV to \(SceneConfig.ps5InputName)" : "Sends HDMI to the \(TVConfig.room) TV")
    }

    private func washerState() -> WebState.Washer? {
        guard let s = washer.status else { return nil }
        let now = Date()
        let display = washer.display(now: now)
        var bar: WebState.Bar?
        switch display {
        case .hidden: break
        case .running(let phase, let progress, _, _), .paused(let phase, let progress, _):
            let paused = if case .paused = display { true } else { false }
            bar = WebState.Bar(kind: paused ? "paused" : "running", title: WasherText.title(display), trailing: WasherText.trailing(display),
                               segments: WasherProgress.fills(s.phases ?? [], progress: progress, current: phase).map { [$0.weight, $0.fill] },
                               note: nil)
        case .finished(let at):
            bar = WebState.Bar(kind: "finished", title: WasherText.title(display), trailing: WasherText.trailing(display), segments: [],
                               note: "Unload me · \(formatDuration(max(now.timeIntervalSince(at), 60))) ago")
        }
        let chip = washer.availability(now: now).map { a in
            let text = WasherText.chip(a)
            return WebState.Chip(short: text.short, sentence: text.sentence, free: a == .free, notify: washer.notifyWhenFree)
        }
        return WebState.Washer(chip: chip, bar: bar, detail: WasherText.detail(s, fetchedAt: washer.fetchedAt))
    }

    private func weatherState() -> WebState.Weather? {
        guard let w = weather.now else { return nil }
        var parts: [String] = []
        if let h = w.high, let l = w.low { parts.append("\(Int(h.rounded()))° / \(Int(l.rounded()))°") }
        if let r = w.rainChance, r >= 10 { parts.append("☂ \(r)%") }
        return WebState.Weather(temp: Int(w.temp.rounded()), summary: w.summary, emoji: WeatherCode.emoji(w.code, day: w.isDay),
                                range: parts.joined(separator: " · "), place: GlanceConfig.place)
    }

    private func matchState() -> WebState.MatchInfo? {
        guard let m = match.match else { return nil }
        let live: String? = if case .live(let clock) = m.state { clock.isEmpty ? "LIVE" : "LIVE \(clock)" } else { nil }
        return WebState.MatchInfo(headline: m.headline, detail: m.detail, title: "Arsenal \(m.fixture) · \(m.competition) · \(m.when) (UK time)",
                                  live: live)
    }

    // MARK: Files

    private func icon(_ size: Int) -> HTTPResponse {
        if icons[size] == nil { icons[size] = WebUI.icon(size: size) }
        return HTTPResponse(status: 200, type: "image/png", body: icons[size] ?? Data())
    }

    /// Only the PSN images in the current state, fetched by the Mac, so the phone never talks to Sony.
    private func artwork(_ which: String) async -> HTTPResponse {
        let summary = ps5.psn
        let raw: String? = which == "now" ? summary?.presence?.icon
            : which.hasPrefix("top/") ? Int(which.dropFirst(4)).flatMap { i in summary?.mostPlayed.flatMap { $0.indices.contains(i) ? $0[i].image : nil } }
            : nil
        guard let raw, let url = URL(string: raw), url.scheme == "https" else { return .text(404, "No artwork.") }
        if let hit = art[raw] { return HTTPResponse(status: 200, type: hit.type, body: hit.data) }
        guard let (data, response) = try? await GlanceConfig.session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let type = http.value(forHTTPHeaderField: "Content-Type"), type.hasPrefix("image/"), data.count < 4_000_000 else {
            return .text(502, "Artwork unavailable.")
        }
        if art.count > 16 { art.removeAll() }
        art[raw] = (data, type)
        return HTTPResponse(status: 200, type: type, body: data)
    }
}

extension HTTPResponse {
    func adding(_ name: String, _ value: String) -> HTTPResponse {
        var copy = self
        copy.headers.append((name, value))
        return copy
    }

    func with(type: String) -> HTTPResponse {
        var copy = self
        copy.type = type
        return copy
    }
}

extension BulbLook {
    var hex: String? {
        guard on else { return nil }
        if mode == .colour, let colour { return colour }
        return LightColour.whiteHex(temp: Double(temp))
    }
}

extension WeatherCode {
    static func emoji(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "☀️" : "🌙"
        case 1, 2: day ? "⛅️" : "☁️"
        case 3: "☁️"
        case 45, 48: "🌫️"
        case 51...57: "🌦️"
        case 61...67, 80...82: "🌧️"
        case 71...77, 85, 86: "🌨️"
        case 95...99: "⛈️"
        default: "☁️"
        }
    }
}
