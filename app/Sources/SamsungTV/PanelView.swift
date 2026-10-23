import SwiftUI
import AppKit

/// To add a tab, add a case here and return its view in `PanelView.content`.
enum PanelTab: String, CaseIterable, Identifiable {
    case now, scenes, remote, apps, cast, lights, ps5, activity, picture

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .now: "tv"
        case .scenes: "sparkles"
        case .remote: "dpad"
        case .apps: "square.grid.2x2"
        case .cast: "airplayvideo"
        case .lights: "lightbulb"
        case .ps5: "gamecontroller"
        case .activity: "chart.bar.fill"
        case .picture: "slider.horizontal.3"
        }
    }

    var title: String {
        switch self {
        case .now: "Now on screen"
        case .scenes: "Scenes"
        case .remote: "Remote"
        case .apps: "Apps"
        case .cast: "Cast"
        case .lights: "Lights"
        case .ps5: "PS5"
        case .activity: "Activity"
        case .picture: "Picture"
        }
    }
}

struct PanelView: View {
    @Bindable var model: TVModel
    let lights: LightsModel
    let ps5: PS5Model
    let scenes: SceneRunner
    let automations: AutomationEngine
    let voice: VoiceTriggers
    let login: LoginItem
    let appearance: AppearanceModel
    let washer: WasherModel
    let web: WebAccess?
    @State private var tab: PanelTab

    private let scrolls: Bool

    init(model: TVModel, lights: LightsModel, ps5: PS5Model, scenes: SceneRunner, automations: AutomationEngine,
         voice: VoiceTriggers, login: LoginItem, appearance: AppearanceModel, washer: WasherModel, web: WebAccess? = nil,
         initialTab: PanelTab = .now, scrolls: Bool = true) {
        self.model = model
        self.lights = lights
        self.ps5 = ps5
        self.scenes = scenes
        self.automations = automations
        self.voice = voice
        self.login = login
        self.appearance = appearance
        self.washer = washer
        self.web = web
        self.scrolls = scrolls
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let web { PairingBanner(web: web) }
            GlanceBar(weather: .shared, match: .shared, washer: washer)
            WasherBar(washer: washer)
            HubStatusLine(hub: .shared)
            tabBar.padding(.horizontal, 14).padding(.bottom, 10)
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { paddedContent }.frame(height: 540)
            } else {
                paddedContent
            }
            Divider().overlay(Theme.stroke)
            footer
        }
        .frame(width: 360)
        .background {
            if tab == .ps5 { PS5Backdrop(animating: ps5.animating) } else { Theme.background }
        }
        .background(WindowVisibility { visible in
            lights.panelVisible = visible
            ps5.panelVisible = visible
            if visible {
                login.refresh()
                appearance.update()
            }
        })
        .onChange(of: tab, initial: true) { _, now in
            lights.tabActive = now == .lights
            ps5.tabActive = now == .ps5
        }
        .foregroundStyle(Theme.primary)
        .environment(\.colorScheme, appearance.scheme)
    }

    private var paddedContent: some View {
        content.padding(.horizontal, 14).padding(.bottom, 14)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .now: NowTab(model: model, showApps: { tab = .apps })
        case .scenes: ScenesTab(runner: scenes, automations: automations, voice: voice)
        case .remote: RemoteTab(model: model)
        case .apps: AppsTab(model: model)
        case .cast: CastTab()
        case .lights: LightsTab(lights: lights)
        case .ps5: PS5Tab(ps5: ps5, tv: model)
        case .activity: ActivityTab(model: model)
        case .picture: PictureTab(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accentDeep)
                Image(systemName: "tv").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(TVConfig.room).font(.system(size: 16, weight: .bold))
                Text("Samsung · Tizen").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Menu {
                Button("Turn on (Wake-on-LAN)") { model.powerOn() }
                Button("Turn off") { model.powerOff() }.disabled(model.power != .on)
                Divider()
                Button("Reconnect remote") { model.retryConnection() }
                Button("Open activity data") {
                    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("SamsungTVRemote")
                    NSWorkspace.shared.open(dir)
                }
                Divider()
                Picker("Appearance", selection: Binding(get: { appearance.mode }, set: { appearance.mode = $0 })) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Approve in Login Items…") { login.openSettings() }
                }
                if let error = login.error {
                    Text(error)
                }
                if let web { phoneMenu(web) }
                hubMenu(HubLink.shared)
                Divider()
                Button("Restart app") { model.shutdown(); AppRestart.now() }
                Button("Quit") { model.shutdown(); NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Button { model.togglePower() } label: {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(model.power == .on ? Theme.accent : Theme.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(model.power == .on ? "Turn off the TV" : "Turn on the TV (Wake-on-LAN)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder private func phoneMenu(_ web: WebAccess) -> some View {
        Divider()
        Toggle("Phone access (local network)", isOn: Binding(get: { web.enabled }, set: { web.enabled = $0 }))
        if web.enabled {
            ForEach([web.nameURL, web.ipURL].compactMap { $0 }, id: \.self) { url in
                Button("Copy \(url)") { web.copy(url) }
            }
            Button("Pair a phone…") { web.pairing.startPairing() }
            if let code = web.pairing.activeCode {
                Text("Pairing code \(PairingBanner.spaced(code))")
            }
            Button("Forget paired devices (\(web.pairing.devices.count))") { web.pairing.forgetAll() }
                .disabled(web.pairing.devices.isEmpty)
        }
        if let problem = web.problem {
            Text(problem)
        }
    }

    @ViewBuilder private func hubMenu(_ hub: HubLink) -> some View {
        Divider()
        Toggle(hub.enabled ? "Use home hub at \(hub.host ?? "?")" : "Use home hub…", isOn: Binding(get: { hub.enabled }, set: { on in
            if on {
                hub.showSetup()
            } else {
                hub.turnOff()
            }
        }))
        if hub.enabled {
            Button("Pair a phone with the hub…") { hub.pairPhone() }
            Button("Copy my presets to the hub") { Task { await lights.copyPresetsToHub() } }
            if let code = hub.phoneCode {
                Text("Hub pairing code \(PairingBanner.spaced(code))")
            }
            Button("Forget the hub") { hub.forget() }
        }
        if hub.busy {
            Text("Pairing with the hub…")
        }
        if let problem = hub.problem {
            Text(problem)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { item in
                Button { tab = item } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tab == item ? Theme.accent : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(tab == item ? Theme.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            StatusDot(color: footerColor)
            Text(model.statusText).font(.system(size: 11, weight: .medium))
            if model.socketState == .tokenUnavailable || model.socketState == .unauthorized {
                Text("· \(model.remoteStatusText)").font(.system(size: 11)).foregroundStyle(Theme.standby)
                Button("Try again") { model.retryConnection() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Spacer()
            Text(model.modelName).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var footerColor: Color {
        switch model.power {
        case .on: Theme.online
        case .standby: Theme.standby
        case .unreachable: model.hasPolled ? Theme.tertiary : Theme.standby
        }
    }
}

/// Reports whether the panel window is on screen, so polling and animations stop when it closes.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { onChange(false); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() { onChange(window?.occlusionState.contains(.visible) ?? false) }
    }
}

/// Shown under the header while a pairing code is live, since the menu closes as soon as the code is made.
struct PairingBanner: View {
    let web: WebAccess

    static func spaced(_ code: String) -> String { "\(code.prefix(3)) \(code.suffix(3))" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let code = web.pairing.activeCode, let expires = web.pairing.codeExpires {
                Card(padding: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        CardHeader(icon: "iphone", title: "Pair a phone")
                        Button("Cancel") { web.pairing.cancelPairing() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    HStack(alignment: .center) {
                        Text(Self.spaced(code)).font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent).textSelection(.enabled)
                        Spacer()
                        Text(remaining(expires.timeIntervalSince(context.date))).font(.system(size: 11, weight: .medium))
                            .monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    Text("On your iPhone, on this Wi-Fi, open \(web.nameURL ?? web.ipURL ?? "the phone page") and enter this code.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
            } else if let paired = web.pairing.lastPaired, context.date.timeIntervalSince(paired.at) < 8 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.online)
                    Text("Paired \(paired.label)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private func remaining(_ seconds: Double) -> String {
        let s = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%d:%02d left", s / 60, s % 60)
    }
}

enum AppRestart {
    /// A detached shell waits for this process to exit, then opens the bundle again.
    static func now() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// One quiet line under the glance bar while "Use home hub" is on.
struct HubStatusLine: View {
    let hub: HubLink

    var body: some View {
        if let line = hub.statusLine {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(hub.offline ? Theme.standby : Theme.accent).frame(width: 6, height: 6)
                    Text(line).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                }
                if hub.offline, let note = HomeName.shared.note {
                    Text(note).font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.leading, 12)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 6)
            .help(hub.offline ? "Scenes, Alexa triggers, automations and the washer run on this Mac until the hub answers again."
                  : "Scenes, Alexa triggers, automations, the washer claim and presets run on the hub.")
        }
    }
}
