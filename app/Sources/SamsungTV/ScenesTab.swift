import SwiftUI

struct ScenesTab: View {
    let runner: SceneRunner
    let automations: AutomationEngine
    let voice: VoiceTriggers

    var body: some View {
        VStack(spacing: 12) {
            SectionLabel(text: "Scenes")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(SceneConfig.scenes) { scene in
                    SceneCard(scene: scene, runner: runner)
                }
            }
            if let run = runner.current { SceneProgressCard(run: run, runner: runner) }
            appPickers
            Card(padding: 12) { VoiceTriggerRow(voice: voice) }

            SectionLabel(text: "Automations").padding(.top, 6)
            Card(padding: 12) {
                ForEach(Array(AutomationKind.allCases.enumerated()), id: \.element) { i, kind in
                    if i > 0 { Divider().overlay(Theme.stroke) }
                    AutomationRow(kind: kind, automations: automations)
                }
            }
            Text("Automations only run while this app is open, react to changes rather than every check, and skip if you changed the lights from this app in the last 2 minutes. All start off.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var appPickers: some View {
        ForEach(SceneConfig.scenes.filter { $0.defaultApp != nil }) { scene in
            HStack(spacing: 8) {
                Image(systemName: scene.icon).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Text("\(scene.name) opens").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    ForEach(SceneConfig.appChoices) { app in
                        Button(app.name) { runner.setApp(app, for: scene) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let app = runner.app(for: scene) { AppTile(app: app, size: 16) }
                        Text(runner.app(for: scene)?.name ?? "Choose").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.raised, in: Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(runner.running)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
        }
    }
}

struct SceneCard: View {
    let scene: SceneDef
    let runner: SceneRunner

    private var isCurrent: Bool { runner.current?.scene.id == scene.id }
    private var busy: Bool { runner.running }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { runner.run(scene) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: scene.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.16), in: Circle())
                    Spacer()
                    badge
                }
                Spacer(minLength: 10)
                Text(scene.name).font(.system(size: 14, weight: .bold))
                Text(scene.subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(colors: [Color(hex: scene.colours.0), Color(hex: scene.colours.1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [Color.white.opacity(0.18), .clear], center: .topTrailing,
                                   startRadius: 2, endRadius: 90)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(isCurrent ? 0.5 : 0.1), lineWidth: isCurrent ? 1.5 : 1))
            .shadow(color: Color(hex: scene.colours.0).opacity(0.25), radius: 8, y: 4)
            .saturation(busy && !isCurrent && scheme == .light ? 0.3 : 1)
            .opacity(busy && !isCurrent ? (scheme == .dark ? 0.45 : 0.7) : 1)
        }
        .buttonStyle(PressableStyle(background: .clear, cornerRadius: 14))
        .disabled(busy)
        .help("Run \(scene.name)")
    }

    @ViewBuilder private var badge: some View {
        if isCurrent, let run = runner.current {
            if !run.finished {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: run.failed ? "xmark.circle.fill" : (run.warned ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                    .font(.system(size: 16))
                    .foregroundStyle(run.failed ? Theme.failure : (run.warned ? Theme.standby : .white))
            }
        }
    }
}

struct SceneProgressCard: View {
    let run: SceneRun
    let runner: SceneRunner

    var body: some View {
        Card(padding: 12) {
            CardHeader(icon: run.scene.icon, title: run.scene.name, trailing: run.finished ? "Clear" : run.summary,
                       trailingAction: run.finished ? { runner.dismiss() } : nil)
            if run.finished {
                Text(run.summary).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(run.failed ? Theme.failure : (run.warned ? Theme.standby : Theme.online))
            }
            let tracks = Dictionary(grouping: run.steps, by: \.track).sorted { $0.key < $1.key }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tracks, id: \.key) { _, steps in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(steps) { StepRow(step: $0) }
                    }
                    .padding(.leading, tracks.count > 1 ? 10 : 0)
                    .overlay(alignment: .leading) {
                        if tracks.count > 1 {
                            Capsule().fill(Color(hex: run.scene.colours.0).opacity(0.7)).frame(width: 2)
                        }
                    }
                }
            }
            if tracks.count > 1 {
                Text("Each bar runs at the same time.").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

struct StepRow: View {
    let step: SceneStep

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.label).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(step.status == .pending ? Theme.secondary : Theme.primary)
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(detailColour)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.status {
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(Theme.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.online)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.standby)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.failure)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.tertiary)
        }
    }

    private var detail: String? {
        switch step.status {
        case .pending, .running: nil
        case .done(let text): text
        case .warning(let text), .failed(let text), .skipped(let text): text
        }
    }

    private var detailColour: Color {
        switch step.status {
        case .failed: Theme.failure
        case .warning: Theme.standby
        default: Theme.secondary
        }
    }
}

struct AutomationRow: View {
    let kind: AutomationKind
    let automations: AutomationEngine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.icon).font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(automations.isOn(kind) ? Theme.accent : Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 12, weight: .semibold))
                Text(kind.detail).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let event = automations.events[kind] {
                    Text("\(event.at.formatted(date: .omitted, time: .shortened)) · \(event.text)")
                        .font(.system(size: 10)).foregroundStyle(event.text.hasPrefix("Failed") ? Theme.failure : Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { automations.isOn(kind) }, set: { automations.set(kind, $0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accentDeep)
        }
    }
}

struct VoiceTriggerRow: View {
    let voice: VoiceTriggers

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(voice.enabled ? Theme.accent : Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Alexa voice triggers").font(.system(size: 12, weight: .semibold))
                Text("Say \u{2018}Alexa, turn on Cinema\u{2019}. Needs this Mac awake with the app open.")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if voice.enabled, let problem = voice.problem {
                    Text(problem).font(.system(size: 10)).foregroundStyle(Theme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let event = voice.last {
                    Text("\(event.at.formatted(date: .omitted, time: .shortened)) · \(event.text)")
                        .font(.system(size: 10)).foregroundStyle(event.text.hasSuffix("Didn't finish") ? Theme.failure : Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { voice.enabled }, set: { voice.set($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accentDeep)
        }
    }
}
