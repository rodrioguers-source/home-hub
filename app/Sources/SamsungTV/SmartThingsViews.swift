import SwiftUI

struct InputsCard: View {
    let model: TVModel

    static let consoles = [SceneConfig.ps5Input: "PS5", "HDMI1": "Switch"]

    static func label(_ input: STOption) -> String {
        consoles[input.id].map { "\(input.name) · \($0)" } ?? input.name
    }

    private static func icon(_ input: STOption) -> String {
        if consoles[input.id] != nil { return "gamecontroller" }
        return input.id.lowercased().hasPrefix("hdmi") ? "cable.connector" : "tv"
    }

    var body: some View {
        let st = model.smartThings
        let off = model.power != .on
        Card {
            CardHeader(icon: "cable.connector", title: "Inputs",
                       trailing: model.activeInput.map { "On \($0.name)" })
            if st.usable, let inputs = st.status?.inputs, !inputs.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(inputs) { input in
                        ChoiceChip(title: Self.label(input), icon: Self.icon(input),
                                   selected: model.activeInput?.id == input.id,
                                   busy: st.busy == "input:\(input.id)") {
                            Task { await st.setInput(input.id) }
                        }
                        .help("Switch the TV to \(input.name)")
                    }
                }
                .disabled(off)
                InputRow(icon: "rectangle.on.rectangle", title: "Source menu",
                         subtitle: "Opens the TV input menu") { model.key("KEY_SOURCE") }
                    .disabled(off)
                Text("Active input from SmartThings, checked about every 45 s.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            } else {
                Group {
                    InputRow(icon: "rectangle.on.rectangle", title: "Source",
                             subtitle: "Opens the TV input menu") { model.key("KEY_SOURCE") }
                    InputRow(icon: "gamecontroller", title: "HDMI",
                             subtitle: "Cycles through HDMI inputs (PS5 etc.)") { model.key("KEY_HDMI") }
                }
                .disabled(off)
                SmartThingsNotice(st: st)
            }
        }
    }
}

struct ModeCard: View {
    let icon: String
    let title: String
    let options: [STOption]
    let current: String?
    let busyPrefix: String
    let st: SmartThingsModel
    var refusal: String?
    var remedy: (title: String, action: () -> Void)?
    let choose: (STOption) -> Void

    var body: some View {
        Card {
            CardHeader(icon: icon, title: title, trailing: options.first { $0.matches(current) }?.name ?? current)
            if options.isEmpty {
                Text(st.status == nil ? "Not loaded yet." : "This TV doesn't list any \(title.lowercased())s.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(options) { option in
                        ChoiceChip(title: option.name, selected: option.matches(current),
                                   busy: st.busy == busyPrefix + option.id) { choose(option) }
                    }
                }
            }
            if let refusal {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(refusal).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.standby)
                if let remedy {
                    Button(remedy.title, action: remedy.action)
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct ChoiceChip: View {
    let title: String
    var icon: String?
    let selected: Bool
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(PressableStyle(background: selected ? Theme.accentDeep : Theme.raised,
                                    foreground: selected ? .white : Theme.primary, cornerRadius: 8))
    }
}

/// One dim line on SmartThings' state, with a retry when it has given up.
struct SmartThingsNotice: View {
    let st: SmartThingsModel

    var body: some View {
        if let text = st.notice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !st.worthTrying {
                    Button("Try again") { Task { await st.retry() } }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}
