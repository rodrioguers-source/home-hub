import SwiftUI
import Observation

enum LightsConfig {
    /// IP → label. Overrides everything else; leave empty to use automatic names.
    static let customNames: [String: String] = [:]

    static let pollInterval: Double = 10

    static let swatches: [(name: String, hex: String)] = [
        ("Red", "ff2a1f"), ("Orange", "ff6a00"), ("Amber", "ffb000"), ("Green", "2bd45a"),
        ("Cyan", "00c8ff"), ("Blue", "1f4dff"), ("Purple", "8a2bff"), ("Pink", "ff2d91"),
    ]

    /// Device names from the Tuya app are kept only when they differ by more than a trailing number;
    /// otherwise bulbs become "Light 1–4" in IP order.
    static func labels(for bulbs: [(index: Int, name: String, ip: String)]) -> [Int: String] {
        let sorted = bulbs.sorted { ipOrder($0.ip) < ipOrder($1.ip) }
        let bases = bulbs.map { base($0.name) }
        let distinct = Set(bases).count == bases.count
        var out: [Int: String] = [:]
        for (n, bulb) in sorted.enumerated() {
            out[bulb.index] = customNames[bulb.ip] ?? (distinct ? bulb.name : "Light \(n + 1)")
        }
        return out
    }

    private static func base(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "[\\s\\d]+$", with: "", options: .regularExpression)
    }

    static func ipOrder(_ ip: String) -> Int { ip.split(separator: ".").reduce(0) { $0 * 256 + (Int($1) ?? 0) } }
}

enum LightLook: Sendable, Equatable {
    case off
    /// Percentages; temp 0 is warmest.
    case white(brightness: Int, temp: Int)
    case colour(hex: String)
}

struct LightRow: Decodable, Sendable {
    let name: String
    let ok: Bool
    let index: Int?
    let ip: String?
    let on: Bool?
    let mode: String?
    let brightness: Int?
    let temp: Int?
    let color: String?
    let error: String?
}

struct Bulb: Identifiable, Equatable {
    let id: Int
    var deviceName: String
    var ip: String
    var label: String
    var reachable = false
    var on = false
    var brightness: Double = 100
    var temp: Double = 0
    var colour: String?
    var error: String?

    var subtitle: String {
        guard reachable else { return "Not responding · \(ip)" }
        guard on else { return "Off" }
        if colour != nil { return "Colour · \(Int(brightness))%" }
        return "White · \(Int(brightness))%"
    }

    var glow: Color {
        guard on else { return Theme.tertiary }
        if let colour, let value = UInt32(colour.dropFirst(), radix: 16) { return Color(hex: value) }
        return LightColour.white(temp: temp)
    }
}

enum LightColour {
    static func white(temp: Double) -> Color {
        let c = whiteComponents(temp: temp)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    static func whiteHex(temp: Double) -> String {
        let c = whiteComponents(temp: temp)
        return String(format: "%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    private static func whiteComponents(temp: Double) -> (r: Double, g: Double, b: Double) {
        let warm = (r: 1.0, g: 0.72, b: 0.38), cool = (r: 0.80, g: 0.90, b: 1.0)
        let t = min(max(temp, 0), 100) / 100
        return (warm.r + (cool.r - warm.r) * t, warm.g + (cool.g - warm.g) * t, warm.b + (cool.b - warm.b) * t)
    }

    static func hex(hue: Double) -> String {
        let c = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func hue(hex: String?) -> Double? {
        guard let hex, let v = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        let c = NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                        blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        return Double(c.hueComponent)
    }

    static func hsv(hex: String?) -> (h: Double, s: Double, v: Double)? {
        guard let hex, let v = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) else { return nil }
        let c = NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                        blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        return (Double(c.hueComponent), Double(c.saturationComponent), Double(c.brightnessComponent))
    }

    /// The bulbs report colour with the brightness baked in; this splits it into a full-value hex and a percentage.
    static func split(hex: String) -> (hex: String, brightness: Int)? {
        guard let (h, s, v) = hsv(hex: hex) else { return nil }
        return (scaled(h: h, s: s, v: 1), max(1, Int((v * 100).rounded())))
    }

    static func scaled(hex: String, brightness: Int) -> String {
        guard let (h, s, _) = hsv(hex: hex) else { return hex }
        return scaled(h: h, s: s, v: Double(brightness) / 100)
    }

    private static func scaled(h: Double, s: Double, v: Double) -> String {
        let sector = (h - h.rounded(.down)) * 6, f = sector - sector.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b) = switch Int(sector) {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return String(format: "%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

@MainActor
@Observable
final class LightsModel {
    var bulbs: [Bulb] = []
    var loaded = false
    var refreshing = false
    var unavailable: String?
    var lastError: String?

    var panelVisible = false { didSet { updateActivity() } }
    var tabActive = false { didSet { updateActivity() } }

    let presets: PresetStore
    var presetBusy: String?
    var presetResult: PresetResult?
    var pendingEdit: PresetEdit?

    @ObservationIgnored private let helper: any LightsTransport
    @ObservationIgnored private var resultClear: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastLocalChange = Date.distantPast
    /// Changes made from this app (sliders, toggles, scenes). Automations back off after one.
    @ObservationIgnored private(set) var lastManualChange = Date.distantPast

    init(helper: any LightsTransport, presets: PresetStore = PresetStore()) {
        self.helper = helper
        self.presets = presets
        presets.onRemoteError = { [weak self] message in
            let text = message == PresetStore.offlineNote ? message : "The hub didn't save that: \(message)"
            self?.show(PresetResult(id: "hub", text: text, failed: true))
        }
    }

    private func updateActivity() {
        if panelVisible && tabActive {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastLocalChange) > 3 { await self.refresh() }
                    try? await Task.sleep(for: .seconds(LightsConfig.pollInterval))
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let rows = try await helper.request("lights.status", ["target": "all"], as: [LightRow].self)
            unavailable = nil
            apply(rows)
        } catch HomeHelper.Failure.remote(let message, let code) where code == "lights_unavailable" {
            unavailable = message
        } catch {
            lastError = error.localizedDescription
        }
        loaded = true
    }

    func retry() {
        unavailable = nil
        helper.restartIfStopped()
        Task {
            _ = try? await helper.call("retry", ["what": "lights"], timeout: 45)
            await refresh()
        }
    }

    /// `fresh` is a read made on purpose (saving a preset), so it wins over the brief guard for local changes.
    func apply(_ rows: [LightRow], fresh: Bool = false) {
        let recentLocal = !fresh && Date().timeIntervalSince(lastLocalChange) < 3
        let labels = LightsConfig.labels(for: rows.compactMap { r in r.index.map { ($0, r.name, r.ip ?? "") } })
        var next: [Bulb] = []
        for row in rows {
            guard let index = row.index else { continue }
            var bulb = bulbs.first { $0.id == index }
                ?? Bulb(id: index, deviceName: row.name, ip: row.ip ?? "", label: labels[index] ?? row.name)
            bulb.label = labels[index] ?? row.name
            bulb.ip = row.ip ?? bulb.ip
            bulb.reachable = row.ok
            bulb.error = row.ok ? nil : row.error
            if row.ok && !recentLocal {
                bulb.on = row.on ?? false
                if let b = row.brightness { bulb.brightness = Double(b) }
                if let t = row.temp { bulb.temp = Double(t) }
                bulb.colour = row.mode == "colour" ? row.color : nil
            }
            next.append(bulb)
        }
        bulbs = next.sorted { LightsConfig.ipOrder($0.ip) < LightsConfig.ipOrder($1.ip) }
    }

    // MARK: Commands. `index == nil` means all lights.

    private func targets(_ index: Int?) -> [Int] {
        bulbs.indices.filter { (index == nil && bulbs[$0].reachable) || bulbs[$0].id == index }
    }

    private func target(_ index: Int?) -> String { index.map(String.init) ?? "all" }

    func setPower(_ index: Int?, on: Bool) {
        for i in targets(index) { bulbs[i].on = on }
        send("lights.\(on ? "on" : "off")", index: index, key: "power", delay: 0)
    }

    func setBrightness(_ index: Int?, _ pct: Double) {
        for i in targets(index) { bulbs[i].brightness = pct }
        send("lights.brightness", ["pct": Int(pct.rounded())], index: index, key: "brightness")
    }

    func setTemp(_ index: Int?, _ pct: Double) {
        for i in targets(index) { bulbs[i].temp = pct; bulbs[i].colour = nil }
        send("lights.temp", ["pct": Int(pct.rounded())], index: index, key: "colour")
    }

    func setColour(_ index: Int?, hex: String) {
        for i in targets(index) { bulbs[i].colour = "#" + hex }
        send("lights.colour", ["value": hex], index: index, key: "colour")
    }

    /// Debounced per target and kind, so dragging a slider sends only the settled value.
    private func send(_ method: String, _ params: [String: Any] = [:], index: Int?, key: String, delay: Double = 0.3) {
        lastLocalChange = Date()
        lastManualChange = Date()
        let id = "\(target(index))|\(key)"
        debounce[id]?.cancel()
        var params = params
        params["target"] = target(index)
        let payload = params
        debounce[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            do {
                let rows = try await self.helper.request(method, payload, as: [LightRow].self)
                let failed = rows.filter { !$0.ok }
                self.lastError = failed.isEmpty ? nil : "\(failed.count) light(s) didn't respond."
            } catch {
                self.lastError = error.localizedDescription
            }
            self.lastLocalChange = Date()
        }
    }

    // MARK: Scenes and automations

    struct LookResult: Sendable {
        var responded = 0
        var total = 0
        var error: String?
        var failed: [String] = []
    }

    /// Applies a whole look to all lights in one helper call. `manual` marks it as the user's own change.
    func apply(_ look: LightLook, manual: Bool) async -> LookResult {
        if manual { lastManualChange = Date() }
        lastLocalChange = Date()
        for i in targets(nil) {
            switch look {
            case .off: bulbs[i].on = false
            case .white(let b, let t): bulbs[i].on = true; bulbs[i].brightness = Double(b); bulbs[i].temp = Double(t); bulbs[i].colour = nil
            case .colour(let hex): bulbs[i].on = true; bulbs[i].colour = "#" + hex
            }
        }
        let (method, params): (String, [String: Any]) = switch look {
        case .off: ("lights.off", [:])
        case .white(let b, let t): ("lights.white", ["brightness": b, "temp": t])
        case .colour(let hex): ("lights.colour", ["value": hex])
        }
        var payload = params
        payload["target"] = "all"
        helper.restartIfStopped()
        do {
            let rows = try await helper.request(method, payload, as: [LightRow].self)
            lastLocalChange = Date()
            if manual { lastManualChange = Date() }
            unavailable = nil
            let failed = rows.filter { !$0.ok }.count
            lastError = failed == 0 ? nil : "\(failed) light(s) didn't respond."
            return LookResult(responded: rows.count - failed, total: rows.count)
        } catch HomeHelper.Failure.remote(let message, let code) where code == "lights_unavailable" {
            unavailable = message
            return LookResult(error: message)
        } catch {
            return LookResult(error: error.localizedDescription)
        }
    }

    /// Fresh read from the bulbs; nil if they couldn't be read.
    func anyOnNow() async -> Bool? {
        lastError = nil
        await refresh()
        guard unavailable == nil, lastError == nil, !reachable.isEmpty else { return nil }
        return anyOn
    }

    // MARK: Presets

    /// One helper round-trip with a look per bulb; bulbs a saved preset doesn't know are left alone.
    func apply(_ preset: LightPreset, manual: Bool) async -> LookResult {
        let looks = preset.resolved(for: bulbs)
        guard !looks.isEmpty else { return LookResult(error: "No lights found.") }
        if manual { lastManualChange = Date() }
        lastLocalChange = Date()
        for look in looks {
            guard let i = bulbs.firstIndex(where: { $0.id == look.index }) else { continue }
            bulbs[i].on = look.on
            guard look.on else { continue }
            bulbs[i].brightness = Double(look.brightness)
            if look.mode == .colour, let hex = look.colour {
                bulbs[i].colour = "#" + LightColour.scaled(hex: hex, brightness: look.brightness)
            } else {
                bulbs[i].temp = Double(look.temp)
                bulbs[i].colour = nil
            }
        }
        helper.restartIfStopped()
        do {
            let rows = try await helper.request("lights.apply", ["looks": looks.map(\.params)], as: [LightRow].self)
            lastLocalChange = Date()
            if manual { lastManualChange = Date() }
            unavailable = nil
            let failed = rows.filter { !$0.ok }.map { row in bulbs.first { $0.id == row.index }?.label ?? row.name }
            if failed.isEmpty { lastError = nil }
            return LookResult(responded: rows.count - failed.count, total: rows.count, failed: failed)
        } catch HomeHelper.Failure.remote(let message, let code) where code == "lights_unavailable" {
            unavailable = message
            return LookResult(error: message)
        } catch {
            return LookResult(error: error.localizedDescription)
        }
    }

    /// Reads every bulb fresh. Bulbs that don't answer are left out and named in `missing`.
    func captureLooks() async throws -> (looks: [BulbLook], missing: [String]) {
        helper.restartIfStopped()
        let rows: [LightRow]
        do {
            rows = try await helper.request("lights.status", ["target": "all"], as: [LightRow].self)
        } catch HomeHelper.Failure.remote(let message, let code) where code == "lights_unavailable" {
            unavailable = message
            throw HomeHelper.Failure.remote(message, code: code)
        }
        unavailable = nil
        apply(rows, fresh: true)
        let looks = rows.filter(\.ok).compactMap(BulbLook.init(row:)).sorted { $0.index ?? 0 < $1.index ?? 0 }
        let missing = rows.filter { !$0.ok }.map { row in bulbs.first { $0.id == row.index }?.label ?? row.name }
        guard !looks.isEmpty else { throw HomeHelper.Failure.remote("None of the lights responded.", code: nil) }
        return (looks, missing)
    }

    func runPreset(_ preset: LightPreset) async {
        guard presetBusy == nil else { return }
        if let remote = presets.remote, remote.presetsActive, remote.presetsEditable { return await runOnHub(preset, remote) }
        presetBusy = preset.id
        let r = await apply(preset, manual: true)
        presetBusy = nil
        let text: String? = if let error = r.error { "Couldn't apply \(preset.name): \(error)" }
            else if r.responded == 0 { "None of the lights responded." }
            else if !r.failed.isEmpty { "\(preset.name): \(Self.list(r.failed)) didn't respond." }
            else { nil }
        show(PresetResult(id: preset.id, text: text, failed: r.error != nil || r.responded == 0))
    }

    /// The hub applies it and reports back through its snapshot, which is polled until the result shows up.
    private func runOnHub(_ preset: LightPreset, _ remote: any PresetRemote) async {
        presetBusy = preset.id
        defer { presetBusy = nil }
        do {
            _ = try await remote.presetRequest("/api/lights/preset", ["id": preset.id])
        } catch {
            show(PresetResult(id: preset.id, text: "Couldn't apply \(preset.name): \(HubLink.describe(error))", failed: true))
            return
        }
        for attempt in 0..<60 {
            await remote.refreshPresets()
            let state = remote.remotePresets
            if state?.busy != preset.id, let r = state?.result, r.id == preset.id {
                show(PresetResult(id: preset.id, text: r.text, failed: r.failed))
                break
            }
            if state?.busy == nil, attempt >= 6 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        lastManualChange = Date()
        await refresh()
    }

    func copyPresetsToHub() async {
        let r = await presets.copyToHub()
        show(PresetResult(id: "copy", text: r.text, failed: r.failed))
    }

    /// The first time this Mac sees a given hub, its saved presets go to the hub's empty slots.
    func copyPresetsToHubOnce(host: String?) async {
        guard let host, presets.onHub, presets.editable, presets.remote?.remotePresets != nil else { return }
        let key = "hub.presetsCopied.\(host)"
        guard !presets.defaults.bool(forKey: key) else { return }
        presets.defaults.set(true, forKey: key)
        guard presets.localSlots.contains(where: { $0 != nil }) else { return }
        await copyPresetsToHub()
    }

    /// Captures the lights for an empty slot, then asks for a name (see `PresetEdit`).
    func beginSave(slot: Int) async {
        guard presetBusy == nil else { return }
        guard presets.editable else { return show(PresetResult(id: PresetStore.slotID(slot), text: PresetStore.offlineNote, failed: true)) }
        presetBusy = PresetStore.slotID(slot)
        defer { presetBusy = nil }
        do {
            let (looks, missing) = try await captureLooks()
            pendingEdit = PresetEdit(slot: slot, name: presets.defaultName(slot), looks: looks, missing: missing)
        } catch {
            show(PresetResult(id: PresetStore.slotID(slot), text: "Couldn't read the lights: \(error.localizedDescription)", failed: true))
        }
    }

    func updateToCurrent(slot: Int) async {
        guard presetBusy == nil, let preset = presets.slots[slot] else { return }
        presetBusy = preset.id
        defer { presetBusy = nil }
        do {
            let (looks, missing) = try await captureLooks()
            presets.update(slot, looks: looks)
            show(PresetResult(id: preset.id, text: missing.isEmpty ? nil : "Saved without \(Self.list(missing)) (didn't respond).",
                              failed: false))
        } catch {
            show(PresetResult(id: preset.id, text: "Couldn't read the lights: \(error.localizedDescription)", failed: true))
        }
    }

    func commitEdit(name: String) {
        guard let edit = pendingEdit else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? presets.defaultName(edit.slot) : trimmed
        if let looks = edit.looks {
            presets.save(edit.slot, name: final, looks: looks)
            if !edit.missing.isEmpty {
                show(PresetResult(id: presets.slots[edit.slot]?.id ?? "", text: "Saved without \(Self.list(edit.missing)) (didn't respond).", failed: false))
            }
        } else {
            presets.rename(edit.slot, to: final)
        }
        pendingEdit = nil
    }

    private func show(_ result: PresetResult) {
        presetResult = result
        resultClear?.cancel()
        resultClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(result.text == nil ? 3 : 10))
            guard !Task.isCancelled else { return }
            self?.presetResult = nil
        }
    }

    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: Master values

    var reachable: [Bulb] { bulbs.filter(\.reachable) }
    var anyOn: Bool { reachable.contains { $0.on } }
    var masterBrightness: Double {
        let on = reachable.filter(\.on)
        return on.isEmpty ? 100 : on.map(\.brightness).reduce(0, +) / Double(on.count)
    }
    var masterSubtitle: String {
        let on = reachable.filter(\.on).count
        let missing = bulbs.count - reachable.count
        var text = on == 0 ? "All off" : "\(on) of \(bulbs.count) on"
        if missing > 0 { text += " · \(missing) not responding" }
        return text
    }

    var masterTemp: Double {
        let list = reachable.filter { $0.on && $0.colour == nil }
        return list.isEmpty ? 0 : list.map(\.temp).reduce(0, +) / Double(list.count)
    }
}

// MARK: Views

struct LightsTab: View {
    @Bindable var lights: LightsModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                SectionLabel(text: "Lights")
                if lights.refreshing { ProgressView().controlSize(.mini) }
            }
            if let message = lights.unavailable {
                Card {
                    CardHeader(icon: "key", title: "Lights unavailable")
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { lights.retry() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            } else if !lights.loaded && lights.bulbs.isEmpty {
                Card {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for the lights…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            } else if lights.bulbs.isEmpty {
                Card {
                    Text("No lights found.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Button("Retry") { Task { await lights.refresh() } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            } else {
                PresetGrid(lights: lights)
                LightCard(lights: lights, index: nil, title: "All lights", subtitle: lights.masterSubtitle,
                          on: lights.anyOn, brightness: lights.masterBrightness, temp: lights.masterTemp,
                          colour: nil, glow: lights.anyOn ? Theme.accent : Theme.tertiary, enabled: !lights.reachable.isEmpty)
                ForEach(lights.bulbs) { bulb in
                    LightCard(lights: lights, index: bulb.id, title: bulb.label, subtitle: bulb.subtitle,
                              on: bulb.on, brightness: bulb.brightness, temp: bulb.temp,
                              colour: bulb.colour, glow: bulb.glow, enabled: bulb.reachable)
                }
            }
            if let error = lights.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.standby)
            }
            Text("Controlled over the local network (Tuya, no cloud). State refreshes every \(Int(LightsConfig.pollInterval)) s while this tab is open.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LightCard: View {
    let lights: LightsModel
    let index: Int?
    let title: String
    let subtitle: String
    let on: Bool
    let brightness: Double
    let temp: Double
    let colour: String?
    let glow: Color
    let enabled: Bool
    @State private var showHue = false

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(glow.opacity(on ? 0.22 : 0.08))
                    Image(systemName: index == nil ? "lightbulb.2.fill" : (on ? "lightbulb.fill" : "lightbulb"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? glow : Theme.secondary)
                }
                .frame(width: 30, height: 30)
                .shadow(color: on ? glow.opacity(0.6) : .clear, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                PowerSwitch(on: on) { lights.setPower(index, on: !on) }
                    .disabled(!enabled)
                    .help(on ? "Turn off" : "Turn on")
            }
            if enabled {
                SliderRow(icon: "sun.min", value: brightness, range: 1...100,
                          track: [Theme.dimTrack, Theme.brightTrack], help: "Brightness") {
                    lights.setBrightness(index, $0)
                }
                SliderRow(icon: "thermometer.medium", value: temp, range: 0...100,
                          track: [LightColour.white(temp: 0), LightColour.white(temp: 100)], help: "Warm ↔ cool white") {
                    lights.setTemp(index, $0)
                }
                .opacity(colour == nil ? 1 : 0.55)
                HStack(spacing: 7) {
                    ForEach(LightsConfig.swatches, id: \.hex) { swatch in
                        Button { lights.setColour(index, hex: swatch.hex) } label: {
                            Circle().fill(Color(hex: UInt32(swatch.hex, radix: 16) ?? 0))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Theme.primary.opacity(isCurrent(swatch.hex) ? 0.9 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                    Spacer(minLength: 0)
                    Button { showHue.toggle() } label: {
                        Circle()
                            .fill(AngularGradient(colors: hueStops, center: .center))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Theme.primary.opacity(showHue ? 0.9 : 0.2), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help("Pick any colour")
                }
                if showHue {
                    SliderRow(icon: "paintpalette", value: (LightColour.hue(hex: colour) ?? 0) * 360, range: 0...360,
                              track: hueStops, help: "Colour") {
                        lights.setColour(index, hex: LightColour.hex(hue: $0 / 360))
                    }
                }
            }
        }
        .opacity(enabled ? 1 : 0.6)
    }

    private var hueStops: [Color] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }
    }

    private func isCurrent(_ hex: String) -> Bool {
        colour?.lowercased().replacingOccurrences(of: "#", with: "") == hex
    }
}

struct PowerSwitch: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule().fill(on ? Theme.accent : Theme.raised)
                .frame(width: 36, height: 20)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
                .animation(.easeOut(duration: 0.15), value: on)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A gradient-track slider; the value shown follows the drag locally and the change is reported on every move.
struct SliderRow: View {
    let icon: String
    let value: Double
    let range: ClosedRange<Double>
    let track: [Color]
    let help: String
    let onChange: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 16)
            GeometryReader { geo in
                let shown = dragging ?? value
                let fraction = (shown - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = 8 + (geo.size.width - 16) * min(max(fraction, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 6)
                        .overlay(Capsule().stroke(Theme.stroke))
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: x - 8)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let f = min(max((g.location.x - 8) / max(geo.size.width - 16, 1), 0), 1)
                            let v = range.lowerBound + f * (range.upperBound - range.lowerBound)
                            dragging = v
                            onChange(v)
                        }
                        .onEnded { _ in dragging = nil }
                )
            }
            .frame(height: 20)
        }
        .help(help)
    }
}
