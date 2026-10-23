import Foundation
import Observation

// MARK: Config — edit scenes here

enum SceneConfig {
    static let wakeTimeout: Double = 25
    static let playStationBlue = "0050ff"
    /// SmartThings input id the PS5 is plugged into (see the Now tab's input list).
    static let ps5Input = "HDMI2"
    static let ps5InputName = "HDMI 2"

    static let scenes: [SceneDef] = [
        SceneDef(id: "cinema", name: "Cinema", subtitle: "Warm 20% · TV on · open app", icon: "popcorn.fill",
                 colours: (0xFF7A2F, 0x5A160B), defaultApp: "stremio",
                 tracks: [[.lights(.white(brightness: 20, temp: 0), "Lights warm white 20%")],
                          [.tvOn, .openApp]]),
        SceneDef(id: "gaming", name: "Gaming", subtitle: "Blue · TV & PS5 on · HDMI 2", icon: "gamecontroller.fill",
                 colours: (0x0070D1, 0x00072D),
                 tracks: [[.lights(.colour(hex: playStationBlue), "Lights PlayStation blue")],
                          [.tvOn, .input(ps5Input, fallbackKeys: ["KEY_HDMI"], "Switch to \(ps5InputName) (PS5)")],
                          [.ps5Wake]]),
        SceneDef(id: "goodnight", name: "Good night", subtitle: "TV off · lights off", icon: "moon.stars.fill",
                 colours: (0x4B4FB8, 0x0D0E26),
                 tracks: [[.tvOff], [.lights(.off, "Lights off")]]),
        SceneDef(id: "normal", name: "Back to normal", subtitle: "Warm white 100%", icon: "sun.max.fill",
                 colours: (0xE8A93A, 0x5C3A08),
                 tracks: [[.lights(.white(brightness: 100, temp: 0), "Lights warm white 100%")]]),
    ]

    /// Apps a scene can open: everything with a known ID (placeholders without one stay hidden).
    static var appChoices: [TVApp] { TVApp.all }
}

enum SceneAction: Sendable {
    case lights(LightLook, String)
    case tvOn
    case tvOff
    /// Opens the scene's chosen app (`SceneDef.defaultApp`, overridable from the Scenes tab).
    case openApp
    case keys([String], String)
    /// Sets the input through SmartThings; sends the keys instead if SmartThings can't.
    case input(String, fallbackKeys: [String], String)
    /// Skipped, not failed, when the PS5 isn't paired for Remote Play.
    case ps5Wake
}

struct SceneDef: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let icon: String
    let colours: (UInt32, UInt32)
    var defaultApp: String?
    /// Tracks run in parallel; steps inside a track run in order.
    let tracks: [[SceneAction]]
}

// MARK: Run state

enum StepStatus: Equatable, Sendable {
    case pending, running
    case done(String?)
    case warning(String)
    case failed(String)
    case skipped(String)

    var finished: Bool { self != .pending && self != .running }
}

struct SceneStep: Identifiable, Sendable {
    let id: Int
    let track: Int
    let action: SceneAction
    let label: String
    var status: StepStatus = .pending
}

struct SceneRun: Sendable {
    let scene: SceneDef
    var steps: [SceneStep]
    var finished = false
    let startedAt = Date()

    var failed: Bool { steps.contains { if case .failed = $0.status { true } else { false } } }
    var warned: Bool { steps.contains { if case .warning = $0.status { true } else { false } } }
    var summary: String {
        if !finished { return "Running…" }
        if failed { return "Didn't finish" }
        return warned ? "Done, with warnings" : "Done"
    }
}

// MARK: Devices

/// What scenes and automations can do. Live wraps the real models; DryRun only logs.
@MainActor
protocol SceneDevices: AnyObject {
    func lights(_ look: LightLook, manual: Bool) async -> StepStatus
    func lightsAnyOn() async -> Bool?
    var lastManualLightsChange: Date { get }
    func tvOn() async -> StepStatus
    func tvOff() async -> StepStatus
    func openApp(_ app: TVApp) async -> StepStatus
    func keys(_ keys: [String]) async -> StepStatus
    func input(_ id: String, fallbackKeys: [String]) async -> StepStatus
    func ps5Wake() async -> StepStatus
}

@MainActor
final class LiveSceneDevices: SceneDevices {
    private let tv: TVModel
    private let lightsModel: LightsModel
    private let ps5: PS5Model

    init(tv: TVModel, lights: LightsModel, ps5: PS5Model) {
        self.tv = tv
        self.lightsModel = lights
        self.ps5 = ps5
    }

    var lastManualLightsChange: Date { lightsModel.lastManualChange }

    func lights(_ look: LightLook, manual: Bool) async -> StepStatus {
        let r = await lightsModel.apply(look, manual: manual)
        if let error = r.error { return .failed(error) }
        if r.total == 0 { return .failed("No lights found.") }
        if r.responded == 0 { return .failed("None of the lights responded.") }
        if r.responded < r.total { return .warning("\(r.responded) of \(r.total) lights responded.") }
        return .done(nil)
    }

    func lightsAnyOn() async -> Bool? { await lightsModel.anyOnNow() }

    func tvOn() async -> StepStatus {
        if tv.power == .on { return .done("Already on") }
        let start = Date()
        var lastPacket = Date.distantPast
        while Date().timeIntervalSince(start) < SceneConfig.wakeTimeout {
            // Magic packets are fire-and-forget UDP, so resend in case one is dropped.
            if Date().timeIntervalSince(lastPacket) >= 5 { tv.powerOn(); lastPacket = Date() }
            try? await Task.sleep(for: .milliseconds(500))
            if tv.power == .on { return .done("On after \(Int(Date().timeIntervalSince(start).rounded())) s") }
        }
        tv.waking = false
        return .failed("The TV didn't wake within \(Int(SceneConfig.wakeTimeout)) s. Check it's plugged in and on the network.")
    }

    func tvOff() async -> StepStatus {
        guard tv.power == .on else { return .skipped("Already off") }
        if let problem = await remoteProblem(timeout: 6) { return .failed(problem) }
        tv.powerOff()
        return .done("Power off sent")
    }

    func openApp(_ app: TVApp) async -> StepStatus {
        guard tv.power == .on else { return .failed("The TV isn't on.") }
        await tv.waitForCloudReady()
        guard let result = await tv.open(app) else {
            return .warning("Couldn't send \(app.name) to the TV: SmartThings and the remote were both unavailable.")
        }
        if !result.confirmed, tv.smartThings.usable {
            // Unconfirmed launches right after waking are often dropped; resending to an open app is harmless.
            try? await Task.sleep(for: .seconds(6))
            _ = await tv.smartThings.launch(app.id)
        }
        return .done(result.confirmed ? "\(app.name) is on screen (\(result.method))" : "Sent to the TV (\(result.method))")
    }

    func keys(_ keys: [String]) async -> StepStatus {
        guard tv.power == .on else { return .failed("The TV isn't on.") }
        if let problem = await remoteProblem(timeout: 12) { return .failed(problem) }
        // A TV that has only just woken tends to drop the first keypress.
        try? await Task.sleep(for: .seconds(1.5))
        for key in keys {
            tv.key(key)
            try? await Task.sleep(for: .milliseconds(600))
        }
        return .done("Sent \(keys.joined(separator: ", "))")
    }

    func input(_ id: String, fallbackKeys: [String]) async -> StepStatus {
        guard tv.power == .on else { return .failed("The TV isn't on.") }
        let st = tv.smartThings
        return await InputSwitch.run(id, fallbackKeys: fallbackKeys, name: st.input(id: id)?.name ?? id,
                                     canTry: { st.worthTrying }, unavailable: { st.unavailableReason },
                                     cloud: { await st.setInput($0) }, keys: { await self.keys($0) })
    }

    func ps5Wake() async -> StepStatus {
        await ps5.probe()
        if ps5.status == .on { return .done("Already on") }
        if ps5.status == .off { return .warning("The PS5 isn't answering on the network (fully off?).") }
        switch await ps5.setPower(on: true) {
        case .done(let text): return .done(text)
        case .failed(let text, let code): return code == "not_paired" ? .skipped(text) : .failed(text)
        }
    }

    /// Waits for the remote WebSocket; returns a reason if it isn't usable.
    private func remoteProblem(timeout: Double) async -> String? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            switch tv.socket.state {
            case .ready: return nil
            case .tokenUnavailable: return "The remote couldn't get its token from 1Password."
            case .unauthorized: return "The TV rejected the remote's token."
            default: tv.socket.connectIfNeeded()
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return "The remote didn't connect in time."
    }
}

/// Shared by the live devices and the dry run, so the fallback path is what gets tested.
enum InputSwitch {
    @MainActor static func run(_ id: String, fallbackKeys: [String], name: String, attempts: Int = 3, retryDelay: Double = 3,
                               canTry: () -> Bool, unavailable: () -> String?,
                               cloud: (String) async -> String?, keys: ([String]) async -> StepStatus) async -> StepStatus {
        var reason = unavailable() ?? "SmartThings unavailable"
        // Just after Wake-on-LAN the cloud may still see the TV as offline, so allow a few tries.
        for attempt in 0..<attempts {
            guard canTry() else { reason = unavailable() ?? reason; break }
            if attempt > 0 { try? await Task.sleep(for: .seconds(retryDelay)) }
            guard let error = await cloud(id) else { return .done("\(name) via SmartThings") }
            reason = error
        }
        let fallback = await keys(fallbackKeys)
        if case .done = fallback {
            let why = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return .warning("Sent \(fallbackKeys.joined(separator: ", ")) instead: SmartThings didn't switch (\(why)).")
        }
        return fallback
    }
}

// MARK: Runner

@MainActor
@Observable
final class SceneRunner {
    var current: SceneRun?
    var running: Bool { current.map { !$0.finished } ?? false }
    private(set) var chosenApps: [String: String] = [:]

    @ObservationIgnored let devices: SceneDevices
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    /// With "Use home hub" on, scenes run on the hub and this shows its progress; while it's offline they run here.
    @ObservationIgnored var hub: HubLink?

    init(devices: SceneDevices, defaults: UserDefaults = .standard) {
        self.devices = devices
        self.defaults = defaults
        for scene in SceneConfig.scenes {
            if let key = defaults.string(forKey: "scene.\(scene.id).app") { chosenApps[scene.id] = key }
        }
    }

    func app(for scene: SceneDef) -> TVApp? {
        guard let fallback = scene.defaultApp else { return nil }
        if let hub, hub.enabled, let key = hub.snapshot?.scenes.apps[scene.id], let app = TVApp.byKey(key) { return app }
        return TVApp.byKey(chosenApps[scene.id] ?? fallback) ?? TVApp.byKey(fallback)
    }

    func setApp(_ app: TVApp, for scene: SceneDef) {
        chosenApps[scene.id] = app.key
        defaults.set(app.key, forKey: "scene.\(scene.id).app")
        if let hub, hub.active { hub.post("/api/scenes/app", ["scene": scene.id, "app": app.key]) }
    }

    func steps(for scene: SceneDef) -> [SceneStep] {
        var out: [SceneStep] = []
        for (t, track) in scene.tracks.enumerated() {
            for action in track {
                out.append(SceneStep(id: out.count, track: t, action: action, label: label(action, scene)))
            }
        }
        return out
    }

    private func label(_ action: SceneAction, _ scene: SceneDef) -> String {
        switch action {
        case .lights(_, let label), .keys(_, let label), .input(_, _, let label): label
        case .tvOn: "Turn the TV on"
        case .tvOff: "Turn the TV off"
        case .openApp: "Open \(app(for: scene)?.name ?? "app")"
        case .ps5Wake: "Wake the PS5"
        }
    }

    func run(_ scene: SceneDef) {
        guard !running else { return }
        Task { await runAndWait(scene) }
    }

    func runAndWait(_ scene: SceneDef) async {
        guard !running else { return }
        if let hub, hub.active { return await runOnHub(scene, hub) }
        current = SceneRun(scene: scene, steps: steps(for: scene))
        log?("scene \(scene.id) start")
        let tracks = scene.tracks.indices.map { t in Task { await self.runTrack(t) } }
        for track in tracks { await track.value }
        current?.finished = true
        log?("scene \(scene.id) end: \(current?.summary ?? "-")")
    }

    private func runOnHub(_ scene: SceneDef, _ hub: HubLink) async {
        current = SceneRun(scene: scene, steps: steps(for: scene))
        log?("scene \(scene.id) start on the home hub")
        let asked = Date().timeIntervalSince1970
        do {
            _ = try await hub.request("/api/scenes/run", ["id": scene.id])
        } catch {
            let why = HubLink.describe(error)
            for id in current?.steps.indices ?? 0..<0 { set(id, id == 0 ? .failed(why) : .skipped("Skipped: the hub didn't start the scene.")) }
            current?.finished = true
            return
        }
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(700))
            await hub.refresh()
            guard let run = hub.snapshot?.scenes.current, run.id == scene.id, run.startedAt >= asked - 5 else { continue }
            for (i, step) in run.steps.enumerated() where current?.steps.indices.contains(i) == true {
                current?.steps[i].status = Self.status(step.status, step.detail)
            }
            if run.finished { break }
        }
        if current?.steps.contains(where: { !$0.status.finished }) == true {
            for id in current!.steps.indices where !current!.steps[id].status.finished {
                set(id, .warning("The hub stopped reporting this step."))
            }
        }
        current?.finished = true
        log?("scene \(scene.id) end on the home hub: \(current?.summary ?? "-")")
    }

    private static func status(_ kind: String, _ detail: String?) -> StepStatus {
        switch kind {
        case "running": .running
        case "done": .done(detail)
        case "warning": .warning(detail ?? "")
        case "failed": .failed(detail ?? "Failed")
        case "skipped": .skipped(detail ?? "Skipped")
        default: .pending
        }
    }

    private func runTrack(_ track: Int) async {
        guard let ids = current?.steps.filter({ $0.track == track }).map(\.id) else { return }
        var blocked: String?
        for id in ids {
            if let blocked {
                set(id, .skipped(blocked))
                continue
            }
            set(id, .running)
            guard let step = current?.steps[id] else { return }
            let result = await perform(step.action)
            set(id, result)
            if case .failed = result { blocked = "Skipped: the step before it failed." }
        }
    }

    private func perform(_ action: SceneAction) async -> StepStatus {
        switch action {
        case .lights(let look, _): return await devices.lights(look, manual: true)
        case .tvOn: return await devices.tvOn()
        case .tvOff: return await devices.tvOff()
        case .keys(let keys, _): return await devices.keys(keys)
        case .input(let id, let fallback, _): return await devices.input(id, fallbackKeys: fallback)
        case .ps5Wake: return await devices.ps5Wake()
        case .openApp:
            guard let scene = current?.scene, let app = app(for: scene) else { return .failed("No app set for this scene.") }
            return await devices.openApp(app)
        }
    }

    private func set(_ id: Int, _ status: StepStatus) {
        guard current != nil, current!.steps.indices.contains(id) else { return }
        current!.steps[id].status = status
        log?("  [track \(current!.steps[id].track)] \(current!.steps[id].label): \(status)")
    }

    func dismiss() {
        if !running { current = nil }
    }
}
