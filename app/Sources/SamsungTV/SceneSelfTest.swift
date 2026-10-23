import Foundation
import AppKit

/// Offline stand-in for the devices: logs each call and answers from a script. Touches no network.
@MainActor
final class DryRunDevices: SceneDevices {
    var tvIsOn = false
    var tvWakes = true
    var remoteWorks = true
    var smartThingsWorks = true
    var smartThingsConfigured = true
    var ps5Paired = true
    var lightsResponding = 4
    var lightsOn: Bool? = true
    var lastManualLightsChange = Date.distantPast
    private(set) var calls: [(at: Date, what: String)] = []
    private let started = Date()

    private func note(_ what: String) {
        calls.append((Date(), what))
        print(String(format: "    +%.2fs  %@", Date().timeIntervalSince(started), what))
    }

    func lights(_ look: LightLook, manual: Bool) async -> StepStatus {
        note("lights \(look) manual=\(manual)")
        if manual { lastManualLightsChange = Date() }
        try? await Task.sleep(for: .milliseconds(150))
        if lightsResponding == 0 { return .failed("None of the lights responded.") }
        return lightsResponding < 4 ? .warning("\(lightsResponding) of 4 lights responded.") : .done(nil)
    }

    func lightsAnyOn() async -> Bool? { note("lights status"); return lightsOn }

    func tvOn() async -> StepStatus {
        note("tv wake-on-lan")
        if tvIsOn { return .done("Already on") }
        try? await Task.sleep(for: .milliseconds(400))
        guard tvWakes else { return .failed("The TV didn't wake within \(Int(SceneConfig.wakeTimeout)) s. Check it's plugged in and on the network.") }
        tvIsOn = true
        return .done("On after 9 s")
    }

    func tvOff() async -> StepStatus {
        note("tv power off")
        guard tvIsOn else { return .skipped("Already off") }
        guard remoteWorks else { return .failed("The remote didn't connect in time.") }
        tvIsOn = false
        return .done("Power off sent")
    }

    func openApp(_ app: TVApp) async -> StepStatus {
        note("tv launch \(app.key) (\(app.id))")
        return tvIsOn ? .done("\(app.name) is on screen") : .failed("The TV isn't on.")
    }

    func keys(_ keys: [String]) async -> StepStatus {
        note("tv keys \(keys)")
        guard remoteWorks else { return .failed("The remote didn't connect in time.") }
        return .done("Sent \(keys.joined(separator: ", "))")
    }

    func ps5Wake() async -> StepStatus {
        note("ps5 wake")
        try? await Task.sleep(for: .milliseconds(100))
        return ps5Paired ? .done("On after 12 s") : .skipped(PS5Model.powerMessage("not_paired")!)
    }

    func input(_ id: String, fallbackKeys: [String]) async -> StepStatus {
        await InputSwitch.run(id, fallbackKeys: fallbackKeys, name: SceneConfig.ps5InputName, retryDelay: 0.05,
                              canTry: { smartThingsConfigured },
                              unavailable: { smartThingsConfigured ? nil : "SmartThings isn't set up." },
                              cloud: { id in
                                  self.note("st set_input \(id)")
                                  return self.smartThingsWorks ? nil : "device offline"
                              },
                              keys: { await self.keys($0) })
    }
}

/// Scripted SmartThings switches for the voice-trigger checks. Touches no network.
@MainActor
final class FakeTriggerSource: VoiceTriggerSource {
    var switches: [String: (on: Bool, at: Date)] = [:]
    var failing = false
    private(set) var fetches = 0
    private(set) var resets: [String] = []

    func fetch(_ names: [String]) async throws -> VoiceTriggerList {
        fetches += 1
        if failing { throw HomeHelper.Failure.remote("Couldn't reach SmartThings (URLError)", code: "network") }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let found = names.filter { switches[$0] != nil }
        return VoiceTriggerList(triggers: found.map { VoiceTrigger(deviceId: "id-\($0)", name: $0, on: switches[$0]!.on,
                                                                   changedAt: f.string(from: switches[$0]!.at)) },
                                missing: names.filter { switches[$0] == nil })
    }

    func reset(_ deviceID: String) async throws {
        resets.append(deviceID)
        let name = String(deviceID.dropFirst(3))
        if let s = switches[name] { switches[name] = (false, s.at) }
    }

    /// Names the hub switches off between this Mac's fetch and its claim, as in a real race.
    var hubGetsThereFirst: Set<String> = []
    private(set) var claims: [String] = []

    func claim(_ deviceID: String) async throws -> Bool {
        claims.append(deviceID)
        let name = String(deviceID.dropFirst(3))
        if hubGetsThereFirst.contains(name), let s = switches[name] { switches[name] = (false, s.at) }
        guard let s = switches[name], s.on else { return false }
        switches[name] = (false, s.at)
        return true
    }

    func turnOn(_ name: String, at: Date = Date()) { switches[name] = (true, at) }
}

/// An in-memory home hub behind `HubLink.transport`: answers /api/hub and records posts. No sockets.
@MainActor
final class FakeHub {
    var up = true
    var automations = ["ps5Blue"]
    var washerClaim: [String: Any]?
    var washerActive = false
    /// The hub's paired phones as /api/devices lists them; /api/devices/import adds to it.
    var devices: [[String: Any]] = []
    private(set) var imported: [[String: Any]] = []
    private(set) var posts: [String] = []
    private var lastScene: (id: String, at: Double)?

    func link(defaults: UserDefaults) -> HubLink {
        let hub = HubLink(defaults: defaults, testHost: "hub.test", testToken: String(repeating: "t", count: 40))
        hub.transport = { [weak self] req in
            guard let self else { throw URLError(.cannotConnectToHost) }
            return try self.answer(req)
        }
        return hub
    }

    private func answer(_ req: URLRequest) throws -> (Data, URLResponse) {
        guard up else { throw URLError(.cannotConnectToHost) }
        let path = req.url?.path ?? ""
        if req.httpMethod == "POST" {
            posts.append(path)
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if path == "/api/scenes/run" { lastScene = (body["id"] as? String ?? "", Date().timeIntervalSince1970) }
            if path == "/api/washer/claim" { washerClaim = ["start": Date().timeIntervalSince1970 - 600] }
            if path == "/api/devices/import", let rows = body["devices"] as? [[String: Any]] {
                imported += rows
                devices += rows.filter { r in !devices.contains { $0["hash"] as? String == r["hash"] as? String } }
            }
            return reply(["ok": true])
        }
        if path == "/api/devices" { return reply(["devices": devices]) }
        var current: Any = NSNull()
        if let s = lastScene {
            current = ["id": s.id, "finished": true, "started_at": s.at, "steps": [] as [Any]]
        }
        var washer: [String: Any] = ["phase": "ready", "notify_when_free": false, "claim": washerClaim ?? NSNull()]
        washer["status"] = washerActive ? ["found": true, "state": "running", "phase": "wash"] as [String: Any] : NSNull()
        return reply(["version": 1,
                      "scenes": ["running": false, "current": current, "apps": [:] as [String: Any]],
                      "automations": ["enabled": automations, "events": [:] as [String: Any]],
                      "voice": ["enabled": true, "last": NSNull(), "problem": NSNull()],
                      "washer": washer,
                      "presets": ["slots": [NSNull(), NSNull(), NSNull(), NSNull(), NSNull()], "busy": NSNull(), "result": NSNull()]])
    }

    private func reply(_ obj: Any) -> (Data, URLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return (data, HTTPURLResponse(url: URL(string: "http://hub.test/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// `SamsungTV --scenes-dryrun`: prints every scene's plan, runs scenes and automations against
/// `DryRunDevices`, checks the expected outcomes, and exits non-zero on any failure.
enum SceneSelfTest {
    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains("--scenes-dryrun") else { return }
        var done = false
        var failures = 0
        Task { @MainActor in
            failures = await run()
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func run() async -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        let suite = "com.rodrigocarneiro.samsungtv.dryrun"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        print("== Config")
        check(TVApp.byKey("stremio")?.id == "IkWsFHtOY9.Stremio", "Stremio has its confirmed id and appears in TVApp.all")
        check(SceneConfig.appChoices.contains { $0.key == "stremio" }, "Stremio offered in the scene app picker")
        check(SceneConfig.scenes.first { $0.id == "cinema" }?.defaultApp == "stremio", "Cinema defaults to Stremio")
        check(TVApp.placeholders.allSatisfy { $0.id == nil || TVApp.byKey($0.key) != nil }, "Placeholders with an id are listed")

        print("\n== Plans")
        let planner = SceneRunner(devices: DryRunDevices(), defaults: defaults)
        for scene in SceneConfig.scenes {
            print("  \(scene.name):")
            for (t, steps) in Dictionary(grouping: planner.steps(for: scene), by: \.track).sorted(by: { $0.key < $1.key }) {
                print("    track \(t): " + steps.map(\.label).joined(separator: " → "))
            }
        }

        func runScene(_ id: String, _ setup: (DryRunDevices) -> Void = { _ in }) async -> (SceneRun, DryRunDevices) {
            let devices = DryRunDevices()
            setup(devices)
            let runner = SceneRunner(devices: devices, defaults: defaults)
            let scene = SceneConfig.scenes.first { $0.id == id }!
            print("\n== Run \(scene.name)")
            await runner.runAndWait(scene)
            let run = runner.current!
            for step in run.steps { print("    [\(step.track)] \(step.label): \(step.status)") }
            print("    → \(run.summary)")
            return (run, devices)
        }

        var (run, dev) = await runScene("cinema")
        check(!run.failed && !run.warned, "Cinema succeeds when the TV wakes")
        check(dev.calls.map(\.what) == ["lights white(brightness: 20, temp: 0) manual=true", "tv wake-on-lan", "tv launch stremio (IkWsFHtOY9.Stremio)"],
              "Cinema: warm 20%, wake, then Stremio")
        let lightAt = dev.calls[0].at, wakeAt = dev.calls[1].at
        check(abs(lightAt.timeIntervalSince(wakeAt)) < 0.1, "Lights and TV wake start in parallel")
        check(dev.calls[2].at.timeIntervalSince(wakeAt) >= 0.35, "App opens only after the TV is on")

        (run, dev) = await runScene("cinema") { $0.tvWakes = false }
        check(run.failed, "Cinema reports failure when the TV doesn't wake")
        check(run.steps.first { if case .tvOn = $0.action { true } else { false } }?.status.failedText?.contains("didn't wake") == true,
              "Failure message says the TV didn't wake")
        check(run.steps.first { if case .openApp = $0.action { true } else { false } }.map { if case .skipped = $0.status { true } else { false } } == true,
              "Open app is skipped after the wake failure")
        check(run.steps.first { if case .lights = $0.action { true } else { false } }?.status == .done(nil),
              "Lights still applied when the TV fails")

        let pickDefaults = UserDefaults(suiteName: suite)!
        let picker = SceneRunner(devices: DryRunDevices(), defaults: pickDefaults)
        let cinema = SceneConfig.scenes.first { $0.id == "cinema" }!
        picker.setApp(TVApp.byKey("youtube")!, for: cinema)
        check(SceneRunner(devices: DryRunDevices(), defaults: pickDefaults).app(for: cinema)?.key == "youtube",
              "Cinema app choice persists")
        pickDefaults.removeObject(forKey: "scene.cinema.app")

        let blue = "lights colour(hex: \"\(SceneConfig.playStationBlue)\") manual=true"
        func tvSide(_ d: DryRunDevices) -> [String] { d.calls.map(\.what).filter { $0 != "ps5 wake" } }
        (run, dev) = await runScene("gaming")
        check(dev.calls.filter { $0.what == "ps5 wake" }.count == 1, "Gaming wakes the PS5 once")
        if let ps5At = dev.calls.first(where: { $0.what == "ps5 wake" })?.at, let tvAt = dev.calls.first(where: { $0.what == "tv wake-on-lan" })?.at {
            check(abs(ps5At.timeIntervalSince(tvAt)) < 0.1, "PS5 wake runs in parallel with the TV")
        }
        check(tvSide(dev) == [blue, "tv wake-on-lan", "st set_input \(SceneConfig.ps5Input)"],
              "Gaming: blue, wake, then SmartThings input \(SceneConfig.ps5Input) (no key presses)")
        check(!run.failed && !run.warned, "Gaming via SmartThings: done, no warnings")

        (run, dev) = await runScene("gaming") { $0.smartThingsConfigured = false }
        check(tvSide(dev) == [blue, "tv wake-on-lan", "tv keys [\"KEY_HDMI\"]"],
              "Gaming without SmartThings: falls straight back to KEY_HDMI, no cloud call")
        check(run.warned && !run.failed, "Fallback is a warning, not a failure")

        (run, dev) = await runScene("gaming") { $0.smartThingsWorks = false }
        check(tvSide(dev) == [blue, "tv wake-on-lan", "st set_input HDMI2", "st set_input HDMI2", "st set_input HDMI2", "tv keys [\"KEY_HDMI\"]"],
              "Gaming when SmartThings errors: 3 tries, then KEY_HDMI")
        check(run.warned && run.steps.first { if case .input = $0.action { true } else { false } }?.status.warningText?.contains("device offline") == true,
              "Warning explains why it fell back")

        (run, dev) = await runScene("gaming") { $0.ps5Paired = false }
        check(!run.failed && run.steps.contains { $0.status == .skipped("Not paired yet. Run ps5_pair.py.") },
              "PS5 not paired: wake step skipped, scene still succeeds")

        (run, dev) = await runScene("gaming") { $0.smartThingsConfigured = false; $0.remoteWorks = false; $0.tvIsOn = true }
        check(run.failed, "Gaming fails when neither SmartThings nor the remote works")

        print("\n== App launch chain")
        var tried: [String] = []
        func method(_ name: String, usable: Bool = true) -> LaunchMethod {
            LaunchMethod(name: name, window: 0) { tried.append(name); return usable }
        }
        let chain = [method("SmartThings"), method("remote"), method("remote (native)", usable: false), method("local network")]
        var worked = await LaunchChain.run(chain) { _ in false }
        check(worked == LaunchResult(method: "SmartThings", confirmed: false) && tried == ["SmartThings"],
              "An accepted send stops the chain even when it can't be seen on screen: \(tried)")
        tried = []
        worked = await LaunchChain.run(chain) { _ in true }
        check(worked == LaunchResult(method: "SmartThings", confirmed: true) && tried == ["SmartThings"], "Confirmed on screen is reported")
        tried = []
        let failing = [method("SmartThings", usable: false), method("remote", usable: false), method("remote (native)"), method("local network")]
        worked = await LaunchChain.run(failing) { _ in false }
        check(worked?.method == "remote (native)" && tried == ["SmartThings", "remote", "remote (native)"],
              "Falls through only past methods that errored: \(tried)")
        tried = []
        worked = await LaunchChain.run(chain.map { m in method(m.name, usable: false) }) { _ in true }
        check(worked == nil && tried.count == 4, "Reports nil when every method errored")

        print("\n== Inputs")
        let tv = TVModel(live: false)
        tv.power = .on
        let st = tv.smartThings
        st.phase = .ready
        let inputs = ["dtv": "TV", "HDMI1": "HDMI 1", "HDMI2": "HDMI 2"].sorted { $0.key < $1.key }.map { STOption(id: $0.key, name: $0.value) }
        func report(_ source: String, channel: String = "", name: String = "") {
            st.absorb(STStatus(health: "ONLINE", power: "on", inputSource: source, inputs: inputs,
                               tvChannelName: name, tvChannel: channel))
        }
        report("HDMI2")
        check(tv.activeInput?.id == "HDMI2", "HDMI 2 reported with nothing else on screen: HDMI 2")
        st.noteChosenInput("dtv", staleReport: "HDMI2")
        report("HDMI2")
        check(tv.activeInput?.id == "dtv", "Chosen TV survives SmartThings repeating the stale HDMI 2")
        report("HDMI1")
        check(tv.activeInput?.id == "HDMI1", "A different report from SmartThings wins over the choice")
        report("HDMI2", name: "IkWsFHtOY9.Stremio")
        check(tv.activeInput == nil, "Stale HDMI 2 with an app in the foreground: nothing highlighted")
        report("HDMI2", channel: "7-1", name: "BBC One")
        check(tv.activeInput?.id == "dtv", "Stale HDMI 2 with a TV channel in the foreground: TV")
        st.noteChosenInput("HDMI2", staleReport: "HDMI2")
        report("HDMI2", name: "IkWsFHtOY9.Stremio")
        check(tv.activeInput?.id == "HDMI2", "A just-picked HDMI input beats lagging foreground info")

        (run, dev) = await runScene("goodnight") { $0.tvIsOn = true }
        check(!run.failed && dev.calls.count == 2, "Good night: TV off and lights off")
        check(abs(dev.calls[0].at.timeIntervalSince(dev.calls[1].at)) < 0.1, "Good night steps run in parallel")

        (run, dev) = await runScene("goodnight") { $0.tvIsOn = false }
        check(!run.failed && run.steps.contains { $0.status == .skipped("Already off") }, "Good night with TV already off: skipped, not failed")

        (run, dev) = await runScene("normal") { $0.lightsResponding = 3 }
        check(run.warned && !run.failed, "Back to normal warns when one light doesn't respond")

        (run, dev) = await runScene("normal") { $0.lightsResponding = 0 }
        check(run.failed, "Back to normal fails when no light responds")

        print("\n== Automation logic")
        let all = Set(AutomationKind.allCases)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute, second: second))!
        }
        func feed(_ logic: inout AutomationLogic, tv: Bool?, ps5: Bool?, from: Date, seconds: Int,
                  enabled: Set<AutomationKind> = all, manual: Date = .distantPast) -> [AutomationDecision] {
            var out: [AutomationDecision] = []
            for s in 0..<seconds {
                out += logic.step(tvOn: tv, ps5On: ps5, now: from.addingTimeInterval(Double(s)), enabled: enabled,
                                  lastManual: manual, sceneRunning: false, calendar: cal)
            }
            return out
        }

        var logic = AutomationLogic()
        check(feed(&logic, tv: true, ps5: true, from: at(20), seconds: 30).isEmpty, "Baseline at launch never fires")

        logic = AutomationLogic()
        _ = feed(&logic, tv: false, ps5: false, from: at(20), seconds: 5)
        var d = feed(&logic, tv: true, ps5: false, from: at(20, 1), seconds: 60)
        check(d == [.fire(.tvOnEvening)], "TV on at 20:01 → warm 40%, once (not every poll): \(d)")

        logic = AutomationLogic()
        _ = feed(&logic, tv: false, ps5: false, from: at(14), seconds: 5)
        d = feed(&logic, tv: true, ps5: false, from: at(14, 1), seconds: 30)
        check(d.isEmpty, "TV on at 14:01 → nothing")

        logic = AutomationLogic()
        _ = feed(&logic, tv: true, ps5: false, from: at(21), seconds: 5)
        d = feed(&logic, tv: false, ps5: false, from: at(21, 0, 5), seconds: 5)
        d += feed(&logic, tv: true, ps5: false, from: at(21, 0, 10), seconds: 20)
        check(d.isEmpty, "A 5 s TV blip (missed poll) is debounced away: \(d)")
        d = feed(&logic, tv: false, ps5: false, from: at(21, 1), seconds: 30)
        check(d == [.fire(.tvOffNormal)], "TV off held for 12 s → back to normal, once: \(d)")

        logic = AutomationLogic()
        _ = feed(&logic, tv: false, ps5: false, from: at(22), seconds: 5)
        d = feed(&logic, tv: false, ps5: true, from: at(22, 1), seconds: 5)
        check(d == [.fire(.ps5Blue)], "PS5 comes online → blue: \(d)")
        d = feed(&logic, tv: false, ps5: false, from: at(22, 2), seconds: 31)
        d += feed(&logic, tv: false, ps5: true, from: at(22, 2, 31), seconds: 30)
        check(d.isEmpty, "A missed PS5 probe (30 s of 'off') doesn't re-trigger: \(d)")
        d = feed(&logic, tv: true, ps5: true, from: at(22, 5), seconds: 10)
        check(d == [.skip(.tvOnEvening, "the PS5 is on, keeping the gaming lights")], "TV on while PS5 is on keeps blue: \(d)")

        logic = AutomationLogic()
        _ = feed(&logic, tv: false, ps5: false, from: at(20), seconds: 5)
        d = feed(&logic, tv: true, ps5: false, from: at(20, 1), seconds: 10, manual: at(20, 0, 30))
        check(d == [.skip(.tvOnEvening, "you changed the lights in the last 2 min")], "Manual change in last 2 min → skip: \(d)")

        logic = AutomationLogic()
        _ = feed(&logic, tv: false, ps5: false, from: at(20), seconds: 5)
        d = feed(&logic, tv: true, ps5: true, from: at(20, 1), seconds: 10, enabled: [])
        check(d.isEmpty, "Disabled automations never fire")

        print("\n== Automation engine (dry devices)")
        let devices = DryRunDevices()
        let runner = SceneRunner(devices: devices, defaults: defaults)
        let engine = AutomationEngine(devices: devices, runner: runner, defaults: defaults)
        check(engine.enabled.isEmpty, "All automations default to off")
        engine.set(.tvOffNormal, true)
        check(AutomationEngine(devices: devices, runner: runner, defaults: defaults).isOn(.tvOffNormal), "Toggle persists")
        devices.lightsOn = false
        await engine.fire(.tvOffNormal)
        check(engine.events[.tvOffNormal]?.text == "Skipped: the lights were off", "TV off with lights off → no change")
        devices.lightsOn = true
        await engine.fire(.tvOffNormal)
        check(engine.events[.tvOffNormal]?.text == "Ran" && devices.calls.last?.what == "lights white(brightness: 100, temp: 0) manual=false",
              "TV off with lights on → warm white 100%, not marked as manual")

        print("\n== Alexa voice triggers (fake switches)")
        let allOff = Dictionary(uniqueKeysWithValues: VoiceTriggerConfig.names.map { ($0, (on: false, at: Date.distantPast)) })
        func voiceSetup() -> (VoiceTriggers, FakeTriggerSource, DryRunDevices, SceneRunner) {
            let src = FakeTriggerSource()
            src.switches = allOff
            let dev = DryRunDevices()
            let runner = SceneRunner(devices: dev, defaults: defaults)
            return (VoiceTriggers(source: src, runner: runner, defaults: defaults), src, dev, runner)
        }
        check(SceneConfig.scenes.allSatisfy { VoiceTriggerConfig.switches[$0.id] != nil }, "Every scene has an Alexa switch")
        var (voice, src, vdev, vrunner) = voiceSetup()
        check(voice.enabled, "Voice triggers default to on")
        var delay = await voice.tick()
        check(delay == VoiceTriggerConfig.interval && src.resets.isEmpty && vdev.calls.isEmpty, "All off: nothing reset, nothing run, 4 s")
        src.turnOn("Cinema")
        delay = await voice.tick()
        await voice.waitForRun()
        check(src.resets == ["id-Cinema"], "Cinema on: switched back off")
        check(vrunner.current?.scene.id == "cinema" && vrunner.current?.finished == true && vdev.calls.count == 3,
              "Cinema on: the Cinema scene ran once (\(vdev.calls.count) device calls)")
        check(voice.last?.text == "Cinema: Done", "Last trigger shows the result: \(voice.last?.text ?? "-")")
        delay = await voice.tick()
        check(vdev.calls.count == 3 && src.resets.count == 1, "Next poll (switch off): no second run")
        src.turnOn("Gaming", at: Date().addingTimeInterval(-10))
        let gamingAt = src.switches["Gaming"]!.at
        let resetsBefore = src.resets.count
        _ = await voice.tick()
        await voice.waitForRun()
        let gamingCalls = vdev.calls.count
        src.switches["Gaming"] = (true, gamingAt)
        _ = await voice.tick()
        await voice.waitForRun()
        check(vdev.calls.count == gamingCalls && src.resets.count == resetsBefore + 2,
              "A reset that didn't stick (same timestamp) is reset again but not re-run")

        (voice, src, vdev, vrunner) = voiceSetup()
        src.turnOn("Good Night", at: Date().addingTimeInterval(-600))
        delay = await voice.tick()
        await voice.waitForRun()
        check(src.resets == ["id-Good Night"] && vdev.calls.isEmpty && vrunner.current == nil,
              "Stale on at start (10 min old): reset, not run")
        check(voice.last?.text == "Good night: Ignored, switched on more than 2 min ago", "Stale is reported: \(voice.last?.text ?? "-")")

        (voice, src, vdev, vrunner) = voiceSetup()
        let manual = Task { await vrunner.runAndWait(SceneConfig.scenes.first { $0.id == "cinema" }!) }
        while !vrunner.running { await Task.yield() }
        src.turnOn("Back to Normal")
        _ = await voice.tick()
        check(src.resets == ["id-Back to Normal"] && vrunner.current?.scene.id == "cinema", "Busy: reset, Back to normal skipped")
        check(voice.last?.text == "Back to normal: Skipped, another scene was running", "Busy is reported: \(voice.last?.text ?? "-")")
        await manual.value
        check(!vdev.calls.contains { $0.what == "lights white(brightness: 100, temp: 0) manual=true" }, "Skipped scene never touched the lights")

        (voice, src, vdev, vrunner) = voiceSetup()
        src.turnOn("Cinema", at: Date().addingTimeInterval(-1))
        src.turnOn("Gaming")
        _ = await voice.tick()
        await voice.waitForRun()
        check(src.resets.count == 2 && vrunner.current?.scene.id == "gaming" && !vdev.calls.contains { $0.what.contains("stremio") },
              "Two on at once: both reset, only the newest (Gaming) runs")

        (voice, src, vdev, vrunner) = voiceSetup()
        src.failing = true
        delay = await voice.tick()
        check(delay == VoiceTriggerConfig.backoff && voice.problem?.contains("Couldn't reach") == true, "Error: backs off to 30 s and says why")
        src.failing = false
        src.turnOn("Cinema", at: Date().addingTimeInterval(-5))
        delay = await voice.tick()
        await voice.waitForRun()
        check(delay == VoiceTriggerConfig.interval && voice.problem == nil && vrunner.current?.scene.id == "cinema",
              "Recovers: back to 4 s and runs a recent trigger")

        (voice, src, vdev, vrunner) = voiceSetup()
        src.switches["Gaming"] = nil
        _ = await voice.tick()
        check(voice.problem == "Not found in SmartThings: Gaming.", "Missing switch is reported")
        voice.set(false)
        src.turnOn("Cinema")
        let fetches = src.fetches
        _ = await voice.tick()
        check(src.fetches == fetches && src.resets.isEmpty && vdev.calls.isEmpty, "Off: no SmartThings calls at all")
        check(!VoiceTriggers(source: src, runner: vrunner, defaults: defaults).enabled, "Toggle persists")

        await hubFallback(defaults: defaults, check: check)

        print("\n== Launch at login (read-only)")
        print("  SMAppService.mainApp.status = \(LoginItem.statusDescription), bundle = \(Bundle.main.bundlePath)")
        return failures
    }
}

extension SceneSelfTest {
    /// The Mac stands in for the hub only after 60 s without an answer, and hands back on the first answer.
    @MainActor static func hubFallback(defaults: UserDefaults, check: (Bool, String) -> Void) async {
        print("\n== Home hub up, down and flapping (in-memory hub)")
        let fake = FakeHub()
        let hub = fake.link(defaults: defaults)
        var clock = Date()
        hub.now = { clock }
        await hub.refresh()
        check(hub.active && hub.statusLine == "Home hub: connected", "Up: hub in charge, \"\(hub.statusLine ?? "-")\"")

        let src = FakeTriggerSource()
        src.switches = Dictionary(uniqueKeysWithValues: VoiceTriggerConfig.names.map { ($0, (on: false, at: Date.distantPast)) })
        let dev = DryRunDevices()
        let runner = SceneRunner(devices: dev, defaults: defaults)
        runner.hub = hub
        let voice = VoiceTriggers(source: src, runner: runner, defaults: defaults)
        voice.hub = hub
        src.turnOn("Cinema")
        _ = await voice.tick()
        check(src.fetches == 0 && src.claims.isEmpty && dev.calls.isEmpty, "Up: the Mac doesn't poll Alexa or run anything")

        await runner.runAndWait(SceneConfig.scenes.first { $0.id == "normal" }!)
        check(fake.posts.last == "/api/scenes/run" && dev.calls.isEmpty, "Up: a scene tapped on the Mac runs on the hub")

        fake.up = false
        await hub.refresh()
        clock += 30
        await hub.refresh()
        _ = await voice.tick()
        check(hub.active && !hub.offline && src.fetches == 0, "Down for 30 s: still the hub's job, no takeover yet")

        print("  flapping: up and down every 20 s for 3 min")
        var everOffline = false
        for i in 0..<9 {
            clock += 20
            fake.up = i % 2 == 0
            await hub.refresh()
            everOffline = everOffline || hub.offline
            _ = await voice.tick()
        }
        check(!everOffline && src.fetches == 0 && dev.calls.isEmpty, "Flapping never counts as offline, and the Mac never polls")

        fake.up = false
        await hub.refresh()
        clock += 61
        await hub.refresh()
        check(hub.offline && !hub.active && hub.statusLine == "Home hub offline, running on this Mac",
              "Down for over 60 s: \"\(hub.statusLine ?? "-")\"")

        src.switches["Cinema"] = (true, Date())
        _ = await voice.tick()
        await voice.waitForRun()
        check(src.claims == ["id-Cinema"] && runner.current?.scene.id == "cinema" && runner.current?.finished == true && !dev.calls.isEmpty,
              "Offline: the Mac polls Alexa, claims Cinema and runs it here")
        let calls = dev.calls.count
        _ = await voice.tick()
        check(dev.calls.count == calls, "…once")

        src.turnOn("Gaming")
        src.hubGetsThereFirst = ["Gaming"]
        _ = await voice.tick()
        await voice.waitForRun()
        check(dev.calls.count == calls && voice.last?.text == "Gaming: Already handled by the home hub",
              "Race: the hub switched Gaming off first, so the Mac doesn't run it")

        src.turnOn("Good Night")
        fake.up = true
        let claimsBefore = src.claims.count
        _ = await voice.tick()
        await voice.waitForRun()
        check(src.claims.count == claimsBefore && dev.calls.count == calls && hub.active && !voice.standingIn,
              "Hub answers again just before the Mac acts: it leaves Good Night to the hub")
        let fetches = src.fetches
        _ = await voice.tick()
        check(src.fetches == fetches, "…and stops polling Alexa on the next tick")

        print("  automations and the washer while offline")
        let engine = AutomationEngine(devices: dev, runner: runner, defaults: defaults)
        engine.hub = hub
        engine.sample(tvOn: false, ps5On: false)
        check(engine.enabled == [.ps5Blue] && !engine.standingIn, "Up: automations mirror the hub's toggles")
        fake.up = false
        await hub.refresh()
        clock += 61
        await hub.refresh()
        engine.sample(tvOn: false, ps5On: false)
        check(engine.standingIn && engine.enabled == [.ps5Blue], "Offline: they run here with the hub's toggles")
        await runner.runAndWait(SceneConfig.scenes.first { $0.id == "normal" }!)
        check(dev.calls.count > calls && fake.posts.filter { $0 == "/api/scenes/run" }.count == 1, "Offline: a tapped scene runs on the Mac")

        let wsrc = FakeWasherSource()
        wsrc.next = .success(.sample("running"))
        let washer = WasherModel(source: wsrc, alerts: FakeWasherAlerts(), defaults: defaults)
        washer.hub = hub
        await washer.tick()
        check(wsrc.fetches == 1 && washer.status?.active == true, "Offline: the Mac polls the washer itself")
        washer.claimCurrent()
        check(washer.claim != nil && !fake.posts.contains("/api/washer/claim"), "Offline: the claim is kept on the Mac")
        fake.up = true
        fake.washerActive = true
        await hub.refresh()
        await washer.tick()
        try? await Task.sleep(for: .milliseconds(100))
        check(fake.posts.contains("/api/washer/claim") && washer.claim != nil, "Back: the Mac's claim goes to the hub")
        await hub.refresh()
        await washer.tick()
        check(washer.claim != nil && wsrc.fetches == 1, "…and the Mac mirrors it again instead of polling")
        engine.sample(tvOn: false, ps5On: false)
        check(!engine.standingIn, "Back: automations hand back too")
        washer.unclaim()
        defaults.removeObject(forKey: "washer.claim")
    }
}

extension StepStatus {
    var failedText: String? { if case .failed(let t) = self { t } else { nil } }
    var warningText: String? { if case .warning(let t) = self { t } else { nil } }
}
