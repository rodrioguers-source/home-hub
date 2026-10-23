import SwiftUI
import Observation

// MARK: Config — edit the built-in presets here

enum PresetConfig {
    /// Built-ins have no bulb index: their looks go to the bulbs in display order (Light 1, 2…), repeating if short.
    static let builtIns: [LightPreset] = [
        LightPreset(id: "bright", name: "Bright", looks: [.white(100, temp: 70)]),
        LightPreset(id: "focus", name: "Focus", looks: [.white(80, temp: 45)]),
        LightPreset(id: "relax", name: "Relax", looks: [.white(45, temp: 15)]),
        LightPreset(id: "movie", name: "Movie night", looks: [.white(12, temp: 0)]),
        LightPreset(id: "sunset", name: "Sunset", looks: [
            .colour("ff5a00", 60), .colour("ff2d6f", 45), .colour("ffa000", 55), .colour("8a2bff", 40),
        ]),
    ]
}

struct BulbLook: Codable, Sendable, Equatable {
    enum Mode: String, Codable, Sendable { case white, colour }

    /// Helper index (1-based, luzes order). Nil in built-ins.
    var index: Int?
    var on: Bool
    var mode: Mode
    /// 1–100. In colour mode it's the colour's level.
    var brightness: Int
    /// 0 warmest … 100 coolest.
    var temp: Int
    /// Hex at full level, no "#".
    var colour: String?

    static func white(_ brightness: Int, temp: Int) -> BulbLook {
        BulbLook(on: true, mode: .white, brightness: brightness, temp: temp)
    }

    static func colour(_ hex: String, _ brightness: Int) -> BulbLook {
        BulbLook(on: true, mode: .colour, brightness: brightness, temp: 0, colour: hex)
    }

    init(index: Int? = nil, on: Bool, mode: Mode, brightness: Int, temp: Int, colour: String? = nil) {
        self.index = index
        self.on = on
        self.mode = mode
        self.brightness = brightness
        self.temp = temp
        self.colour = colour
    }

    init?(row: LightRow) {
        guard row.ok, let index = row.index else { return nil }
        if row.mode == "colour", let raw = row.color, let split = LightColour.split(hex: raw) {
            self.init(index: index, on: row.on ?? false, mode: .colour, brightness: split.brightness,
                      temp: row.temp ?? 0, colour: split.hex)
        } else {
            self.init(index: index, on: row.on ?? false, mode: .white, brightness: max(1, row.brightness ?? 100),
                      temp: row.temp ?? 0)
        }
    }

    var params: [String: Any] {
        var p: [String: Any] = ["index": index ?? 0, "on": on, "mode": mode.rawValue, "brightness": brightness, "temp": temp]
        if let colour { p["colour"] = colour }
        return p
    }

    var swatch: Color {
        guard on else { return Color(light: Color(hex: 0xC9CCD4), dark: Color(hex: 0x3A3B42)) }
        if mode == .colour, let colour, let v = UInt32(colour, radix: 16) { return Color(hex: v) }
        return LightColour.white(temp: Double(temp))
    }

    func sameLook(as other: BulbLook) -> Bool {
        var a = self, b = other
        a.index = nil
        b.index = nil
        return a == b
    }

    var summary: String {
        guard on else { return "Off" }
        if mode == .colour { return "Colour \(brightness)%" }
        let tone = temp < 10 ? "Very warm" : temp < 30 ? "Warm" : temp < 60 ? "Neutral" : "Cool"
        return "\(tone) white \(brightness)%"
    }

    /// Loose match, since colours and levels round-trip through the bulb's own scales.
    func matches(_ bulb: Bulb) -> Bool {
        guard bulb.on == on else { return false }
        guard on else { return true }
        if mode == .colour {
            guard let colour, let want = LightColour.hsv(hex: colour), let got = LightColour.hsv(hex: bulb.colour) else { return false }
            let hueGap = abs(want.h - got.h)
            let hueOK = want.s < 0.15 || min(hueGap, 1 - hueGap) < 0.03
            return hueOK && abs(want.s - got.s) < 0.12 && abs(Double(brightness) / 100 - got.v) < 0.05
        }
        return bulb.colour == nil && abs(bulb.brightness - Double(brightness)) <= 3 && abs(bulb.temp - Double(temp)) <= 3
    }
}

struct LightPreset: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var looks: [BulbLook]

    var isBuiltIn: Bool { looks.contains { $0.index == nil } }

    /// The look for each bulb, with its index filled in.
    func resolved(for bulbs: [Bulb]) -> [BulbLook] {
        guard isBuiltIn else {
            return bulbs.isEmpty ? looks : looks.filter { look in bulbs.contains { $0.id == look.index } }
        }
        guard !looks.isEmpty else { return [] }
        return bulbs.enumerated().map { i, bulb in
            var look = looks[i % looks.count]
            look.index = bulb.id
            return look
        }
    }

    /// Ticked when every responding bulb it covers looks like it.
    func isActive(on bulbs: [Bulb]) -> Bool {
        let pairs = resolved(for: bulbs).compactMap { look in bulbs.first { $0.id == look.index && $0.reachable }.map { (look, $0) } }
        return !pairs.isEmpty && pairs.allSatisfy { $0.0.matches($0.1) }
    }

    func summary(labels: [Int: String]) -> String {
        if let first = looks.first, looks.allSatisfy({ $0.sameLook(as: first) }) {
            return isBuiltIn || looks.count > 1 ? "\(first.summary) on all lights" : "\(labels[first.index ?? 0] ?? "Light"): \(first.summary)"
        }
        return looks.enumerated().map { i, look in
            let label = isBuiltIn ? "Light \(i + 1)" : labels[look.index ?? 0] ?? "Light \(look.index ?? 0)"
            return "\(label): \(look.summary)"
        }.joined(separator: "\n")
    }
}

/// The result line under the grid; `text == nil` means it worked.
struct PresetResult: Equatable {
    let id: String
    let text: String?
    let failed: Bool
}

/// Naming a freshly captured preset (`looks` set) or renaming one (`looks == nil`).
struct PresetEdit: Equatable {
    let slot: Int
    var name: String
    var looks: [BulbLook]?
    var missing: [String] = []
}

// MARK: Store

/// Where the slots live while "Use home hub" is on: the hub's list replaces the local file.
@MainActor
protocol PresetRemote: AnyObject {
    var presetsActive: Bool { get }
    /// False while the hub is offline: the cached list still shows and applies, but can't be changed.
    var presetsEditable: Bool { get }
    var remotePresets: HubSnapshot.Presets? { get }
    func presetRequest(_ path: String, _ body: [String: Any]) async throws -> [String: Any]
    func refreshPresets() async
}

/// The editable slots, saved as JSON next to usage.json. `fileURL == nil` keeps them in memory only.
/// With a remote active, reads and edits go to the home hub and the local file is left as it is.
@MainActor
@Observable
final class PresetStore {
    static let slotCount = 5
    static let nameLimit = 40
    nonisolated static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SamsungTVRemote/light-presets.json")

    private struct File: Codable {
        var version = 1
        var slots: [LightPreset?]
    }

    private(set) var localSlots: [LightPreset?] = Array(repeating: nil, count: slotCount)
    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored weak var remote: (any PresetRemote)?
    @ObservationIgnored var onRemoteError: ((String) -> Void)?
    @ObservationIgnored private var writes: Task<Void, Never>?

    init(fileURL: URL? = PresetStore.defaultURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        for (i, preset) in file.slots.prefix(Self.slotCount).enumerated() {
            localSlots[i] = preset.flatMap { $0.isBuiltIn ? nil : $0 }
        }
    }

    var onHub: Bool { remote?.presetsActive == true }
    var editable: Bool { !onHub || remote?.presetsEditable == true }
    static let offlineNote = "The home hub is offline, so its presets are read-only here until it's back."

    var slots: [LightPreset?] {
        guard let remote, remote.presetsActive else { return localSlots }
        let hub = (remote.remotePresets?.slots ?? []).prefix(Self.slotCount).map { $0.flatMap { $0.isBuiltIn ? nil : $0 } }
        return hub + Array(repeating: nil, count: Self.slotCount - hub.count)
    }

    static func slotID(_ slot: Int) -> String { "slot-\(slot)" }

    func defaultName(_ slot: Int) -> String { "Preset \(slot + 1)" }

    func cleanName(_ name: String?, slot: Int) -> String {
        let words = (name ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let short = String(words.prefix(Self.nameLimit)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? defaultName(slot) : short
    }

    func save(_ slot: Int, name: String, looks: [BulbLook]) {
        guard slots.indices.contains(slot) else { return }
        if onHub { return send("/api/presets/put", ["slot": slot, "name": name, "looks": looks.map(\.params)]) }
        localSlots[slot] = LightPreset(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: name, looks: looks)
        persist()
    }

    func rename(_ slot: Int, to name: String) {
        guard slots.indices.contains(slot), slots[slot] != nil else { return }
        if onHub { return send("/api/presets/rename", ["slot": slot, "name": name]) }
        localSlots[slot]?.name = name
        persist()
    }

    func update(_ slot: Int, looks: [BulbLook]) {
        guard slots.indices.contains(slot), let preset = slots[slot] else { return }
        if onHub { return send("/api/presets/put", ["slot": slot, "name": preset.name, "looks": looks.map(\.params)]) }
        localSlots[slot]?.looks = looks
        persist()
    }

    func delete(_ slot: Int) {
        guard slots.indices.contains(slot) else { return }
        if onHub { return send("/api/presets/clear", ["slot": slot]) }
        localSlots[slot] = nil
        persist()
    }

    /// Waits for edits already sent to the hub.
    func settle() async {
        await writes?.value
    }

    private func send(_ path: String, _ body: [String: Any]) {
        guard editable else {
            onRemoteError?(Self.offlineNote)
            return
        }
        let previous = writes
        writes = Task { [weak self] in
            await previous?.value
            guard let remote = self?.remote else { return }
            do {
                _ = try await remote.presetRequest(path, body)
            } catch {
                self?.onRemoteError?(HubLink.describe(error))
            }
            await remote.refreshPresets()
        }
    }

    /// Copies this Mac's saved presets into the hub's empty slots; slots the hub already uses are left alone.
    func copyToHub() async -> (text: String, failed: Bool) {
        guard let remote, remote.presetsActive else { return ("Turn on Use home hub first.", true) }
        guard remote.presetsEditable else { return (Self.offlineNote, true) }
        guard localSlots.contains(where: { $0 != nil }) else { return ("There are no saved presets on this Mac to copy.", false) }
        let body: [Any] = localSlots.map { p in
            p.map { ["id": $0.id, "name": $0.name, "looks": $0.looks.map(\.params)] as [String: Any] } ?? NSNull()
        }
        do {
            let r = try await remote.presetRequest("/api/presets/import", ["slots": body])
            await remote.refreshPresets()
            return (Self.copySummary(imported: r["imported"] as? [Int] ?? [], kept: r["kept"] as? [Int] ?? []), false)
        } catch {
            return ("Couldn't copy the presets to the hub: \(HubLink.describe(error))", true)
        }
    }

    static func copySummary(imported: [Int], kept: [Int]) -> String {
        var parts: [String] = []
        if !imported.isEmpty { parts.append("Copied \(imported.count) preset\(imported.count == 1 ? "" : "s") to the hub.") }
        if !kept.isEmpty {
            let names = LightsModel.list(kept.map { "\($0 + 1)" })
            parts.append(kept.count == 1 ? "Slot \(names) already had a preset on the hub, so it was left alone."
                         : "Slots \(names) already had presets on the hub, so they were left alone.")
        }
        return parts.isEmpty ? "Nothing to copy." : parts.joined(separator: " ")
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(slots: localSlots)).write(to: fileURL, options: .atomic)
        } catch {}
    }
}

// MARK: Views

struct PresetGrid: View {
    @Bindable var lights: LightsModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(PresetConfig.builtIns) { preset in tile(preset, slot: nil) }
                ForEach(0..<PresetStore.slotCount, id: \.self) { slot in
                    if let preset = lights.presets.slots[slot] {
                        tile(preset, slot: slot)
                    } else {
                        EmptyPresetTile(busy: lights.presetBusy == PresetStore.slotID(slot),
                                        editing: lights.pendingEdit?.slot == slot) {
                            Task { await lights.beginSave(slot: slot) }
                        }
                        .disabled(lights.presetBusy != nil || !lights.presets.editable)
                    }
                }
            }
            if let edit = lights.pendingEdit {
                PresetNameEditor(lights: lights, edit: edit).id(edit.slot)
            } else if !lights.presets.editable {
                Text(PresetStore.offlineNote)
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let text = lights.presetResult?.text {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(lights.presetResult?.failed == true ? Theme.failure : Theme.standby)
            }
        }
    }

    private func tile(_ preset: LightPreset, slot: Int?) -> some View {
        let labels = Dictionary(uniqueKeysWithValues: lights.bulbs.map { ($0.id, $0.label) })
        let result = lights.presetResult?.id == preset.id ? lights.presetResult : nil
        return PresetTile(preset: preset, active: preset.isActive(on: lights.bulbs),
                          busy: lights.presetBusy == preset.id,
                          warning: result?.text == nil ? nil : (result?.failed == true ? Theme.failure : Theme.standby)) {
            Task { await lights.runPreset(preset) }
        }
        .disabled(lights.presetBusy != nil)
        .help("\(preset.name)\n\(preset.summary(labels: labels))" + (slot == nil ? "" : "\nRight-click to rename, update or delete."))
        .contextMenu {
            if let slot, lights.presets.editable {
                Button("Rename…") { lights.pendingEdit = PresetEdit(slot: slot, name: preset.name) }
                Button("Update to current lights") { Task { await lights.updateToCurrent(slot: slot) } }
                Divider()
                Button("Delete", role: .destructive) {
                    if lights.pendingEdit?.slot == slot { lights.pendingEdit = nil }
                    lights.presets.delete(slot)
                }
            }
        }
    }
}

struct PresetTile: View {
    let preset: LightPreset
    let active: Bool
    let busy: Bool
    let warning: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                PresetSwatch(looks: preset.looks, size: 30)
                    .overlay {
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .overlay(alignment: .bottomTrailing) { badge.offset(x: 4, y: 4) }
                Text(preset.name)
                    .font(.system(size: 10, weight: active ? .bold : .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
            }
            .padding(.top, 9).padding(.bottom, 5).padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(active ? Theme.accent : Theme.stroke, lineWidth: active ? 1.5 : 1))
            .shadow(color: Theme.shadow, radius: 4, y: 1)
        }
        .buttonStyle(PressableStyle(background: .clear, cornerRadius: 11))
    }

    @ViewBuilder private var badge: some View {
        if let warning, !busy {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13))
                .foregroundStyle(.white, warning)
                .background(Circle().fill(Theme.card).padding(-1.5))
        } else if active, !busy {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                .foregroundStyle(.white, Theme.accent)
                .background(Circle().fill(Theme.card).padding(-1.5))
        }
    }
}

struct EmptyPresetTile: View {
    let busy: Bool
    let editing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                    if busy { ProgressView().controlSize(.small) } else {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                Text("Save current")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
            }
            .padding(.top, 9).padding(.bottom, 5).padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(editing ? Theme.accent : Theme.tertiary.opacity(0.6),
                              style: StrokeStyle(lineWidth: editing ? 1.5 : 1, dash: editing ? [] : [4, 3])))
        }
        .buttonStyle(PressableStyle(background: .clear, cornerRadius: 11))
        .help("Save how the lights look now as a preset")
    }
}

/// One colour per bulb around the circle; dimmer looks are drawn darker.
struct PresetSwatch: View {
    let looks: [BulbLook]
    let size: CGFloat

    var body: some View {
        let colours = looks.map(\.swatch)
        let level = looks.isEmpty ? 1 : Double(looks.map { $0.on ? $0.brightness : 0 }.reduce(0, +)) / Double(looks.count) / 100
        ZStack {
            if colours.count < 2 || looks.allSatisfy({ $0.sameLook(as: looks[0]) }) {
                Circle().fill(RadialGradient(colors: [colours.first ?? .gray, (colours.first ?? .gray).opacity(0.7)],
                                             center: .topLeading, startRadius: 1, endRadius: size))
            } else {
                Circle().fill(AngularGradient(colors: colours + [colours[0]], center: .center, angle: .degrees(-90)))
            }
            Circle().fill(Color.black.opacity((1 - level) * (1 - level) * 0.55))
            Circle().strokeBorder(Color(light: .black.opacity(0.14), dark: .white.opacity(0.22)), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: (colours.first ?? .clear).opacity(0.25 + level * 0.35), radius: 3 + level * 4)
    }
}

struct PresetNameEditor: View {
    let lights: LightsModel
    let edit: PresetEdit
    @State private var name: String
    @FocusState private var focused: Bool

    init(lights: LightsModel, edit: PresetEdit) {
        self.lights = lights
        self.edit = edit
        _name = State(initialValue: edit.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) { field }
            if !edit.missing.isEmpty {
                Text("\(LightsModel.list(edit.missing)) didn't respond, so it won't be in this preset.")
                    .font(.system(size: 10)).foregroundStyle(Theme.standby)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.stroke))
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        PresetSwatch(looks: edit.looks ?? lights.presets.slots[edit.slot]?.looks ?? [], size: 22)
        TextField(edit.looks == nil ? "Name" : "Name this preset", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .focused($focused)
            .onSubmit { lights.commitEdit(name: name) }
            .onExitCommand { lights.pendingEdit = nil }
        Button("Cancel") { lights.pendingEdit = nil }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        Button { lights.commitEdit(name: name) } label: {
            Text(edit.looks == nil ? "Rename" : "Save").font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(PressableStyle(background: Theme.accentDeep, foreground: .white, cornerRadius: 7))
    }
}
