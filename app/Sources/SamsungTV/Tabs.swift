import SwiftUI
import AppKit

// MARK: Agora na tela

struct NowTab: View {
    let model: TVModel
    let showApps: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            screen
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(color: model.power == .on ? Theme.accent : Theme.tertiary)
                    SectionLabel(text: "Now on screen")
                }
                Text(model.nowCaption).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VolumeCard(model: model)

            Card {
                CardHeader(icon: "star", title: "Favourites", trailing: "See all", trailingAction: showApps)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(TVApp.favourites) { app in
                        Button { model.launch(app) } label: {
                            AppTile(app: app, label: app.name, running: model.runningApps.contains(app.id))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(app.name) on the TV")
                    }
                }
            }
            .disabled(model.power != .on)

            InputsCard(model: model)
        }
    }

    private var screen: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x0A0B10), Color(hex: 0x14172A)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.bezel, lineWidth: 3)
                if model.power == .on {
                    if let app = model.currentApp {
                        VStack(spacing: 8) {
                            AppTile(app: app, size: 54)
                            Text(app.name).font(.system(size: 16, weight: .semibold))
                        }
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "tv").font(.system(size: 26)).foregroundStyle(Theme.accent)
                            Text("TV on").font(.system(size: 14, weight: .semibold))
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "power").font(.system(size: 22)).foregroundStyle(Theme.tertiary)
                        Button { model.powerOn() } label: {
                            Text(model.waking ? "Turning on…" : "Turn on").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 6)
                        }
                        .buttonStyle(PressableStyle(background: Theme.accentDeep, foreground: .white))
                    }
                }
            }
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.white)
            .frame(height: 170)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Button { model.refreshNow() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: model.refreshing)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh TV status")
                    Text(model.power == .on ? "ON" : (model.waking ? "…" : "OFF"))
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(model.power == .on ? Theme.accent : Theme.tertiary)
                    Toggle("", isOn: Binding(
                        get: { model.power == .on || model.waking },
                        set: { _ in model.togglePower() }
                    ))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accentDeep)
                }
                .padding(10)
                .environment(\.colorScheme, .dark)
                .help(model.power == .on ? "Turn off the TV" : "Turn on the TV (Wake-on-LAN)")
            }
            .shadow(color: Theme.accent.opacity(model.power == .on ? 0.25 : 0), radius: 14, y: 6)
            HStack {
                Rectangle().fill(Theme.bezel).frame(width: 30, height: 2).rotationEffect(.degrees(-18))
                Spacer()
                Rectangle().fill(Theme.bezel).frame(width: 30, height: 2).rotationEffect(.degrees(18))
            }
            .padding(.horizontal, 24).padding(.top, 6)
        }
        .padding(.horizontal, 12)
    }
}

struct InputRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 34, height: 34)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct VolumeCard: View {
    let model: TVModel

    var body: some View {
        Card {
            CardHeader(icon: "speaker.wave.2", title: "TV audio")
            HStack(spacing: 8) {
                RepeatButton(systemName: "speaker.slash", help: "Mute") { model.key("KEY_MUTE") }
                Spacer()
                RepeatButton(systemName: "minus", help: "Volume down (hold to repeat)") { model.key("KEY_VOLDOWN") }
                RepeatButton(systemName: "plus", help: "Volume up (hold to repeat)") { model.key("KEY_VOLUP") }
            }
            Text(volumeNote).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.power != .on)
        .opacity(model.power == .on ? 1 : 0.5)
    }

    private var volumeNote: String {
        let st = model.smartThings
        guard st.usable, let volume = st.status?.volume else {
            return "The TV doesn't report its volume level over the network; each press sends one step."
        }
        let muted = st.status?.mute == "muted" ? ", muted" : ""
        return "Volume \(Int(volume.rounded()))\(muted), from SmartThings (can lag a little). Each press sends one step."
    }
}

// MARK: Controle

struct RemoteTab: View {
    let model: TVModel

    var body: some View {
        VStack(spacing: 12) {
            SectionLabel(text: "Remote")
            Card {
                HStack {
                    Text(model.currentApp?.name ?? "TV").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    StatusDot(color: model.socketState == .ready ? Theme.online : Theme.standby)
                    Text(model.remoteStatusText).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                HStack(alignment: .center) {
                    VStack(spacing: 14) {
                        IconButton(systemName: "house", help: "Home") { model.key("KEY_HOME") }
                        IconButton(systemName: "arrow.uturn.backward", help: "Back") { model.key("KEY_RETURN") }
                    }
                    Spacer()
                    DPad(model: model)
                    Spacer()
                    VStack(spacing: 14) {
                        IconButton(systemName: "gearshape", help: "Menu / settings") { model.key("KEY_MENU") }
                        IconButton(systemName: "xmark", help: "Exit") { model.key("KEY_EXIT") }
                    }
                }
                .padding(.vertical, 6)
                HStack(spacing: 6) {
                    ForEach([("backward.fill", "KEY_REWIND", "Rewind"), ("play.fill", "KEY_PLAY", "Play"),
                             ("pause.fill", "KEY_PAUSE", "Pause"), ("stop.fill", "KEY_STOP", "Stop"),
                             ("forward.fill", "KEY_FF", "Fast forward")], id: \.1) { icon, key, help in
                        Button { model.key(key) } label: {
                            Image(systemName: icon).font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 32)
                        }
                        .buttonStyle(PressableStyle())
                        .help(help)
                    }
                }
            }

            Card {
                CardHeader(icon: "cursorarrow", title: "TV cursor", trailing: "Drag · tap to click")
                Touchpad(model: model)
                Text("The cursor only appears on screens that accept a pointer, such as the TV browser.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button { model.key("KEY_CHDOWN") } label: {
                    Label("Channel −", systemImage: "chevron.down").font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(PressableStyle(background: Theme.card))
                Button { model.key("KEY_CHUP") } label: {
                    Label("Channel +", systemImage: "chevron.up").font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(PressableStyle(background: Theme.card))
            }

            VolumeCard(model: model)
        }
        .disabled(model.power != .on)
    }
}

struct DPad: View {
    let model: TVModel

    var body: some View {
        ZStack {
            Circle().fill(Theme.raised)
            Circle().stroke(Theme.stroke)
            VStack {
                arrow("chevron.up", "KEY_UP")
                Spacer()
                arrow("chevron.down", "KEY_DOWN")
            }
            .padding(.vertical, 6)
            HStack {
                arrow("chevron.left", "KEY_LEFT")
                Spacer()
                arrow("chevron.right", "KEY_RIGHT")
            }
            .padding(.horizontal, 6)
            Button { model.key("KEY_ENTER") } label: {
                Text("OK").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                    .frame(width: 54, height: 54)
                    .background(Theme.accent.opacity(0.2), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 140, height: 140)
    }

    private func arrow(_ icon: String, _ key: String) -> some View {
        Button { model.key(key) } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Touchpad: View {
    let model: TVModel
    @State private var last: CGPoint?
    @State private var start: Date?
    @State private var travelled: CGFloat = 0
    @State private var pending = CGSize.zero
    @State private var lastSend = Date.distantPast
    @State private var active = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.accent.opacity(active ? 0.16 : 0.08))
            .overlay(Image(systemName: "hand.point.up.left").font(.system(size: 22)).foregroundStyle(Theme.accent.opacity(0.8)))
            .frame(height: 110)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        active = true
                        if last == nil { start = Date(); travelled = 0 }
                        let prev = last ?? value.location
                        let dx = value.location.x - prev.x, dy = value.location.y - prev.y
                        travelled += abs(dx) + abs(dy)
                        last = value.location
                        // Moves are batched to ~30 per second; scaled up so a short drag crosses the TV screen.
                        pending.width += dx * 3
                        pending.height += dy * 3
                        if Date().timeIntervalSince(lastSend) > 0.033, pending != .zero {
                            model.socket.moveCursor(dx: Int(pending.width), dy: Int(pending.height))
                            pending = .zero
                            lastSend = Date()
                        }
                    }
                    .onEnded { _ in
                        if travelled < 4, let start, Date().timeIntervalSince(start) < 0.35 {
                            model.socket.leftClick()
                        }
                        last = nil
                        pending = .zero
                        active = false
                    }
            )
    }
}

// MARK: Apps

struct AppsTab: View {
    let model: TVModel

    private var apps: [TVApp] {
        model.installed.isEmpty ? TVApp.all : TVApp.all.filter { model.installed[$0] != nil }
    }

    var body: some View {
        VStack(spacing: 12) {
            SectionLabel(text: "Apps")
            Card {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
                    ForEach(apps) { app in
                        Button { model.launch(app) } label: {
                            AppTile(app: app, label: app.name, running: model.runningApps.contains(app.id))
                        }
                        .buttonStyle(.plain)
                        .help(model.installed[app] ?? app.name)
                    }
                }
            }
            .disabled(model.power != .on)
            Text("Apps checked on the TV over the local network. A green dot means the app is open, on screen or in the background. The TV doesn't share its full app list, so only apps this app knows about appear.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: Transmitir

struct CastTab: View {
    var body: some View {
        VStack(spacing: 12) {
            SectionLabel(text: "Cast")
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "airplayvideo").font(.system(size: 22)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Mac, on the big screen").font(.system(size: 14, weight: .semibold))
                        Text("Mirroring with AirPlay").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
                Text("In Control Centre on your Mac, open Screen Mirroring and choose the \(TVConfig.room) TV. You can also use the TV as a second display in Displays settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Displays settings", systemImage: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "play.rectangle").foregroundStyle(Theme.secondary)
                    Text("Send a file").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Coming soon").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                }
                Text("Play a video, song or photo from your Mac straight on the TV. Coming in a future version.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

// MARK: Atividade

struct ActivityTab: View {
    let model: TVModel
    @State private var period = 1

    private let periods = [(1, "Today"), (7, "7 days"), (30, "30 days")]

    var body: some View {
        let _ = model.usageRevision
        let totals = model.usage.totals(lastDays: period)
        let tvTime = totals[UsageStore.tvKey] ?? 0
        let ps5Time = totals[UsageStore.ps5Key] ?? 0
        let rows = totals.filter { $0.key != UsageStore.tvKey && $0.key != UsageStore.ps5Key && $0.value >= 1 }
            .sorted { $0.value > $1.value }

        VStack(spacing: 12) {
            SectionLabel(text: "Activity")
            HStack(spacing: 6) {
                Text("Period").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                ForEach(periods, id: \.0) { days, title in
                    Button { period = days } label: {
                        Text(title).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                    }
                    .buttonStyle(PressableStyle(background: period == days ? Theme.accentDeep : Theme.card,
                                                foreground: period == days ? .white : Theme.primary, cornerRadius: 7))
                }
                Spacer()
            }

            Card(padding: 16) {
                SectionLabel(text: "Screen time")
                Text(formatDuration(tvTime)).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.accent)
                Text("TV on time, as seen by this Mac").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }

            Card {
                if rows.isEmpty {
                    Text("Nothing recorded for this period yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ForEach(rows, id: \.key) { key, seconds in
                    UsageRow(key: key, seconds: seconds, fraction: tvTime > 0 ? seconds / tvTime : 0)
                }
            }
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 11)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(PSTheme.blue, in: RoundedRectangle(cornerRadius: 6))
                    Text("PS5").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(ps5Time >= 1 ? formatDuration(ps5Time) : "Nothing recorded")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Text("Console on time (not rest mode), checked every ~30 s, whether or not the TV is on.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Only counts while this app is open and the Mac is awake, every ~5 s. \"Other\" is the TV on without a known app on screen (home screen, live TV or HDMI, such as the PS5).")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }
}

struct UsageRow: View {
    let key: String
    let seconds: Double
    let fraction: Double

    var body: some View {
        let app = TVApp.byKey(key)
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if let app {
                    AppTile(app: app, size: 24)
                } else {
                    Image(systemName: "tv").font(.system(size: 12)).frame(width: 24, height: 24)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                }
                Text(app?.name ?? "Other").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(formatDuration(seconds)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(app.map { Color(hex: $0.color) } ?? Theme.accent)
                        .frame(width: max(3, geo.size.width * min(fraction, 1)))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Imagem

struct PictureTab: View {
    let model: TVModel

    var body: some View {
        let st = model.smartThings
        VStack(spacing: 12) {
            SectionLabel(text: "Picture")
            Group {
                ModeCard(icon: "sun.max", title: "Picture mode", options: st.status?.pictureModes ?? [],
                         current: st.status?.pictureMode, busyPrefix: "picture:", st: st,
                         refusal: refused(.picture).map { "The TV refused \($0.name). It may be locked on this input (Game Mode or HDR)." },
                         remedy: pictureRemedy) { option in
                    Task { await st.setPictureMode(option) }
                }
                ModeCard(icon: "waveform", title: "Sound mode", options: st.status?.soundModes ?? [],
                         current: st.status?.soundMode, busyPrefix: "sound:", st: st,
                         refusal: refused(.sound).map { "The TV refused \($0.name). It may not be available with the current input or audio output." }) { option in
                    Task { await st.setSoundMode(option) }
                }
            }
            .disabled(model.power != .on || !st.usable)
            .opacity(model.power == .on && st.usable ? 1 : 0.5)
            SmartThingsNotice(st: st)
            Text("Brightness, contrast, sharpness and colour aren't exposed by SmartThings on this TV, so those stay on the TV remote. Modes take a few seconds to apply, and each change is checked against the TV afterwards.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hidden once the TV reports the refused mode after all, such as after the remote key.
    private func refused(_ kind: STModeKind) -> STOption? {
        let st = model.smartThings
        guard let option = st.refused[kind] else { return nil }
        return option.matches(kind == .picture ? st.status?.pictureMode : st.status?.soundMode) ? nil : option
    }

    private var pictureRemedy: (title: String, action: () -> Void)? {
        guard let option = refused(.picture), let key = SmartThingsModel.remoteKey(forPictureMode: option.name) else { return nil }
        let st = model.smartThings
        return ("Try the remote's \(option.name) key instead", {
            model.key(key)
            Task {
                try? await Task.sleep(for: .seconds(3))
                await st.fetch(refresh: true)
            }
        })
    }
}
