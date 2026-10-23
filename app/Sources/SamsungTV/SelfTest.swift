import Foundation
import SwiftUI
import AppKit

/// `SamsungTV --selftest`: checks the unauthenticated network paths and exits. Never reads the token.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let (power, model) = await REST.power()
            print("device info: power=\(power) model=\(model ?? "-")")
            for app in TVApp.all {
                if let s = await REST.status(app.id) {
                    print("app \(app.key): name=\(s.name ?? "-") running=\(s.running ?? false) visible=\(s.visible ?? false)")
                } else {
                    print("app \(app.key): not installed / no answer")
                }
            }
            let session = URLSession(configuration: .ephemeral, delegate: TVTrustDelegate(), delegateQueue: nil)
            do {
                let (_, response) = try await session.data(from: URL(string: "https://\(TVConfig.host):8002/api/v2/")!)
                print("tls 8002 (self-signed accepted): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            } catch {
                print("tls 8002 failed: \(error.localizedDescription)")
            }
            print("wake-on-lan bytes sent: \(WakeOnLAN.send())")
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

/// `SamsungTV --snapshot <dir>`: renders each tab with an offline sample model, into `<dir>/dark` and `<dir>/light`.
enum Snapshot {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let model = TVModel(live: false)
        model.power = .on
        model.hasPolled = true
        model.visibleApp = TVApp.favourites[1]
        model.runningApps = [TVApp.favourites[1].id]
        model.socketState = .ready
        model.smartThings.phase = .ready
        model.smartThings.status = STStatus(
            health: "ONLINE", power: "on", inputSource: "HDMI2",
            inputs: [STOption(id: "dtv", name: "TV"), STOption(id: "HDMI2", name: "HDMI 2")],
            pictureMode: "Eco",
            pictureModes: [("modeGen_393224", "Dynamic"), ("modeGen_393227", "Eco"), ("modeMovieHDR", "Movie"),
                           ("modeStandardHDR", "Standard")].map { STOption(id: $0.0, name: $0.1) },
            soundMode: "Standard",
            soundModes: [("modeAdaptive", "Adaptive Sound"), ("modeAmplify", "Amplify"), ("modeStandard", "Standard")]
                .map { STOption(id: $0.0, name: $0.1) },
            volume: 17, mute: "unmuted", tvChannelName: "")
        WeatherModel.shared.now = WeatherNow(temp: 15, code: 2, isDay: false, high: 20, low: 15, rainChance: 30)
        let kickoff = ISO8601DateFormatter().date(from: "2026-10-18T15:30:00Z")!
        MatchModel.shared.match = Match(kickoff: kickoff, opponent: "Nottm Forest", home: false, neutral: false,
                                        competition: "Premier League", state: .upcoming)
        let helper = HomeHelper(live: false)
        let lights = LightsModel(helper: helper, presets: PresetStore(fileURL: nil))
        lights.presets.save(0, name: "Reading", looks: [
            BulbLook(index: 1, on: true, mode: .white, brightness: 70, temp: 35), BulbLook(index: 2, on: false, mode: .white, brightness: 50, temp: 0),
            BulbLook(index: 3, on: true, mode: .white, brightness: 40, temp: 20), BulbLook(index: 4, on: false, mode: .white, brightness: 50, temp: 0),
        ])
        lights.presets.save(1, name: "Party lights", looks: [1, 2, 3, 4].map { i in
            BulbLook(index: i, on: true, mode: .colour, brightness: 80, temp: 0, colour: ["00c8ff", "ff2d91", "8a2bff", "2bd45a"][i - 1])
        })
        lights.loaded = true
        lights.apply([
            LightRow(name: "Enshine GU10 Smart Bulb", ok: true, index: 1, ip: "192.168.0.24", on: true, mode: "white",
                     brightness: 80, temp: 20, color: nil, error: nil),
            LightRow(name: "Enshine GU10 Smart Bulb 2", ok: true, index: 2, ip: "192.168.0.25", on: true, mode: "colour",
                     brightness: 60, temp: 0, color: "#8a2bff", error: nil),
            LightRow(name: "Enshine GU10 Smart Bulb 3", ok: true, index: 3, ip: "192.168.0.26", on: false, mode: "white",
                     brightness: 100, temp: 70, color: nil, error: nil),
            LightRow(name: "Enshine GU10 Smart Bulb 4", ok: false, index: 4, ip: "192.168.0.27", on: nil, mode: nil,
                     brightness: nil, temp: nil, color: nil, error: "no answer"),
        ])
        let ps5 = PS5Model(helper: helper, usage: nil, live: false)
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
        let suite = "com.rodrigocarneiro.samsungtv.snapshot"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let scenes = SceneRunner(devices: DryRunDevices(), defaults: defaults)
        let automations = AutomationEngine(devices: scenes.devices, runner: scenes, defaults: defaults)
        let voice = VoiceTriggers(source: FakeTriggerSource(), runner: scenes, defaults: defaults)
        let login = LoginItem()
        let washer = WasherModel(source: FakeWasherSource(), alerts: FakeWasherAlerts(), defaults: defaults)
        let looks: [(String, AppearanceModel)] = [("dark", AppearanceModel(fixed: .dark)), ("light", AppearanceModel(fixed: .light))]
        for (folder, _) in looks {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        func panel(_ ps5: PS5Model, _ tab: PanelTab) -> (AppearanceModel) -> PanelView {
            { look in
                PanelView(model: model, lights: lights, ps5: ps5, scenes: scenes, automations: automations, voice: voice,
                          login: login, appearance: look, washer: washer, initialTab: tab, scrolls: false)
            }
        }
        func render(_ view: (AppearanceModel) -> PanelView, _ name: String) {
            for (folder, look) in looks {
                let renderer = ImageRenderer(content: view(look))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(folder).appendingPathComponent("\(name).png"))
                }
            }
        }
        for tab in PanelTab.allCases {
            render(panel(ps5, tab), tab.rawValue)
        }
        let unconnected = PS5Model(helper: helper, usage: nil, live: false)
        unconnected.status = .rest
        unconnected.hasPolled = true
        unconnected.psn = PSNSummary(configured: false, state: "missing", error: nil)
        render(panel(unconnected, .ps5), "ps5-connect")

        let cloud = model.smartThings.status
        model.visibleApp = nil
        model.smartThings.status?.tvChannelName = "IkWsFHtOY9.Stremio"
        render(panel(ps5, .now), "now-stremio-via-smartthings")
        model.smartThings.phase = .unavailable("Couldn't read 'SmartThings OAuth' from 1Password.")
        model.smartThings.status = nil
        render(panel(ps5, .now), "now-smartthings-unavailable")
        render(panel(ps5, .picture), "picture-smartthings-unavailable")
        model.smartThings.phase = .ready
        model.smartThings.status = cloud
        model.smartThings.refused[.picture] = STOption(id: "modeMovieHDR", name: "Movie")
        model.smartThings.refused[.sound] = STOption(id: "modeAmplify", name: "Amplify")
        render(panel(ps5, .picture), "picture-mode-refused")
        model.smartThings.refused = [:]
        model.smartThings.phase = .ready
        model.smartThings.status = cloud
        model.visibleApp = TVApp.favourites[1]

        let upcoming = MatchModel.shared.match
        MatchModel.shared.match = Match(kickoff: Date(), opponent: "Everton", home: true, neutral: false,
                                        competition: "Premier League", state: .live(clock: "63'"), ourScore: "2", theirScore: "1")
        WeatherModel.shared.now = nil
        render(panel(ps5, .picture), "glance-live-no-weather")
        MatchModel.shared.match = upcoming
        WeatherModel.shared.now = WeatherNow(temp: 15, code: 2, isDay: false, high: 20, low: 15, rainChance: 30)
        ps5.powerError = PS5Model.powerMessage("not_paired")
        render(panel(ps5, .ps5), "ps5-power-error")
        ps5.powerError = nil

        let lightRows = lights.bulbs
        lights.apply((1...4).map { i in
            LightRow(name: "Enshine GU10 Smart Bulb \(i)", ok: i != 4, index: i, ip: "192.168.0.\(23 + i)", on: i != 4 ? true : nil,
                     mode: "white", brightness: 45, temp: 15, color: nil, error: i == 4 ? "no answer" : nil)
        }, fresh: true)
        render(panel(ps5, .lights), "lights-preset-active")
        lights.presetResult = PresetResult(id: "relax", text: "Relax: Light 4 didn't respond.", failed: false)
        render(panel(ps5, .lights), "lights-preset-warning")
        lights.presetResult = nil
        lights.pendingEdit = PresetEdit(slot: 2, name: "Preset 3", looks: lights.presets.slots[0]?.looks, missing: ["Light 4"])
        render(panel(ps5, .lights), "lights-preset-naming")
        lights.pendingEdit = nil
        lights.bulbs = lightRows

        let cinema = SceneConfig.scenes[0]
        var run = SceneRun(scene: cinema, steps: scenes.steps(for: cinema))
        run.steps[0].status = .done(nil)
        run.steps[1].status = .done("On after 9 s")
        run.steps[2].status = .running
        scenes.current = run
        automations.set(.tvOnEvening, true)
        voice.last = AutomationEvent(at: Date(), text: "Cinema: Running…")
        render(panel(ps5, .scenes), "scenes-running")
        run.steps[1].status = .failed("The TV didn't wake within 25 s. Check it's plugged in and on the network.")
        run.steps[2].status = .skipped("Skipped: the step before it failed.")
        run.finished = true
        scenes.current = run
        voice.last = AutomationEvent(at: Date(), text: "Gaming: Skipped, another scene was running")
        render(panel(ps5, .scenes), "scenes-failed")
        voice.problem = "Not found in SmartThings: Good Night."
        voice.last = nil
        scenes.current = nil
        render(panel(ps5, .scenes), "scenes-voice-problem")

        let iso = ISO8601DateFormatter()
        let now = Date()
        let running = WasherStatus.sample("running", completion: iso.string(from: now.addingTimeInterval(20 * 60 + 5)))
        washer.status = .done(iso.string(from: now.addingTimeInterval(-3 * 3600)))
        render(panel(ps5, .now), "washer-free")
        washer.status = running
        render(panel(ps5, .now), "washer-busy")
        washer.setNotifyWhenFree(true)
        render(panel(ps5, .now), "washer-busy-notify")
        washer.setNotifyWhenFree(false)
        washer.claimCurrent(now: now)
        render(panel(ps5, .now), "washer-claimed-running")
        washer.status = .sample("paused")
        render(panel(ps5, .now), "washer-claimed-paused")
        washer.status = .done(iso.string(from: now.addingTimeInterval(-12 * 60)))
        washer.claim?.finishedAt = now.addingTimeInterval(-12 * 60)
        render(panel(ps5, .now), "washer-claimed-finished")
        washer.status = nil
        washer.claim = nil
        defaults.removePersistentDomain(forName: suite)
        exit(0)
    }
}
