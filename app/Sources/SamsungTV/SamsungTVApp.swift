import SwiftUI

@main
struct SamsungTVApp: App {
    @State private var model: TVModel
    @State private var lights: LightsModel
    @State private var ps5: PS5Model
    @State private var scenes: SceneRunner
    @State private var automations: AutomationEngine
    @State private var voice: VoiceTriggers
    @State private var washer: WasherModel
    @State private var login = LoginItem()
    @State private var appearance: AppearanceModel
    @State private var web: WebAccess

    init() {
        SelfTest.runIfRequested()
        Snapshot.runIfRequested()
        SceneSelfTest.runIfRequested()
        PresetSelfTest.runIfRequested()
        WasherSelfTest.runIfRequested()
        WebSelfTest.runIfRequested()
        HomeNameSelfTest.runIfRequested()
        let helper = HomeHelper()
        let hub = HubLink.shared
        helper.hub = hub
        let tv = TVModel(helper: helper)
        let lights = LightsModel(helper: helper)
        lights.presets.remote = hub
        hub.onRefresh = { [weak lights] in
            Task { await lights?.copyPresetsToHubOnce(host: hub.host) }
        }
        let ps5 = PS5Model(helper: helper, usage: tv.usage)
        let runner = SceneRunner(devices: LiveSceneDevices(tv: tv, lights: lights, ps5: ps5))
        runner.hub = hub
        let automations = AutomationEngine(devices: runner.devices, runner: runner)
        automations.hub = hub
        automations.start(tv: tv, ps5: ps5)
        let voice = VoiceTriggers(source: HelperTriggerSource(helper: helper), runner: runner)
        voice.hub = hub
        voice.start()
        let washer = WasherModel(source: HelperWasherSource(helper: helper), alerts: LiveWasherAlerts())
        washer.hub = hub
        washer.smartThingsOK = { [weak tv] in tv?.smartThings.phase == .ready ? tv?.smartThings.fetchedAt : nil }
        washer.start()
        WeatherModel.shared.start()
        MatchModel.shared.start()
        let appearance = AppearanceModel()
        let pairing = PairingStore()
        pairing.pairingForHub = { hub.enabled && hub.offline }
        hub.pairing = pairing
        let api = WebAPI(tv: tv, ps5: ps5, lights: lights, scenes: runner, washer: washer,
                         controls: LiveWebControls(tv: tv, ps5: ps5), pairing: pairing,
                         scheme: { appearance.resolved() })
        let web = WebAccess(api: api)
        hub.log = { AppLog.write("hub: \($0)") }
        automations.log = { AppLog.write($0) }
        HomeName.shared.log = { AppLog.write("name: \($0)") }
        HomeName.shared.configure(hub: hub, port: { [weak web] in web?.port })
        hub.onPoll = { HomeName.shared.update() }
        _appearance = State(initialValue: appearance)
        _web = State(initialValue: web)
        _model = State(initialValue: tv)
        _lights = State(initialValue: lights)
        _ps5 = State(initialValue: ps5)
        _scenes = State(initialValue: runner)
        _automations = State(initialValue: automations)
        _voice = State(initialValue: voice)
        _washer = State(initialValue: washer)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model, lights: lights, ps5: ps5, scenes: scenes, automations: automations, voice: voice,
                      login: login, appearance: appearance, washer: washer, web: web)
        } label: {
            Image(systemName: model.power == .on ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)
    }
}
