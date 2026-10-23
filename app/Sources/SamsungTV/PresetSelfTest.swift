import Foundation

/// Four pretend bulbs behind the helper protocol: answers lights.status and lights.apply. Touches no network.
@MainActor
final class FakeBulbs: LightsTransport {
    struct State {
        var ip: String
        var on = true
        var mode = "white"
        var brightness = 100
        var temp = 0
        var color: String?
    }

    var bulbs: [Int: State]
    var dead: Set<Int> = []
    var unavailable = false
    private(set) var calls: [(method: String, params: [String: Any])] = []

    /// IPs deliberately out of index order, so display order (by IP) differs from helper order.
    init() {
        bulbs = [1: State(ip: "192.168.0.27"), 2: State(ip: "192.168.0.24"), 3: State(ip: "192.168.0.26"), 4: State(ip: "192.168.0.25")]
    }

    var applyCalls: [[[String: Any]]] { calls.filter { $0.method == "lights.apply" }.map { $0.params["looks"] as? [[String: Any]] ?? [] } }

    func call(_ method: String, _ params: [String: Any], timeout: Double) async throws -> Data {
        calls.append((method, params))
        try? await Task.sleep(for: .milliseconds(60))
        if unavailable { throw HomeHelper.Failure.remote("Couldn't read the light keys from 1Password ('Tuya Lamps').", code: "lights_unavailable") }
        var rows: [[String: Any]] = []
        switch method {
        case "lights.status":
            for (index, b) in bulbs.sorted(by: { $0.key < $1.key }) {
                var row: [String: Any] = ["name": "Enshine GU10 Smart Bulb \(index)", "index": index, "ip": b.ip]
                if dead.contains(index) {
                    row["ok"] = false
                    row["error"] = "no answer"
                } else {
                    row.merge(["ok": true, "on": b.on, "mode": b.mode, "brightness": b.brightness, "temp": b.temp]) { $1 }
                    if b.mode == "colour", let c = b.color { row["color"] = c }
                }
                rows.append(row)
            }
        case "lights.apply":
            for look in params["looks"] as? [[String: Any]] ?? [] {
                let index = look["index"] as? Int ?? 0
                var row: [String: Any] = ["name": "Enshine GU10 Smart Bulb \(index)", "index": index]
                guard var b = bulbs[index], !dead.contains(index) else {
                    row["ok"] = false
                    row["error"] = "no answer"
                    rows.append(row)
                    continue
                }
                let level = look["brightness"] as? Int ?? 100
                if look["on"] as? Bool == false {
                    b.on = false
                } else if look["mode"] as? String == "colour", let hex = look["colour"] as? String {
                    b.on = true
                    b.mode = "colour"
                    b.color = "#" + LightColour.scaled(hex: hex, brightness: level)
                } else {
                    b.on = true
                    b.mode = "white"
                    b.brightness = level
                    b.temp = look["temp"] as? Int ?? 0
                    b.color = nil
                }
                bulbs[index] = b
                row["ok"] = true
                rows.append(row)
            }
        case "lights.on", "lights.off", "lights.brightness", "lights.temp", "lights.colour":
            let target = params["target"] as? String ?? "all"
            for (index, var b) in bulbs.sorted(by: { $0.key < $1.key }) where target == "all" || target == "\(index)" {
                rows.append(["name": "Enshine GU10 Smart Bulb \(index)", "index": index, "ok": !dead.contains(index)])
                if !dead.contains(index) {
                    switch method {
                    case "lights.on": b.on = true
                    case "lights.off": b.on = false
                    case "lights.brightness": b.brightness = params["pct"] as? Int ?? b.brightness
                    case "lights.temp": b.mode = "white"; b.temp = params["pct"] as? Int ?? b.temp; b.color = nil
                    default: b.mode = "colour"; b.color = "#" + (params["value"] as? String ?? "ffffff")
                    }
                    bulbs[index] = b
                }
            }
        default:
            throw HomeHelper.Failure.remote("Unknown method \(method)", code: nil)
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }

    func restartIfStopped() {}
}

/// Stands in for the home hub's preset endpoints, with the same rules (import fills empty slots only).
@MainActor
final class FakePresetRemote: PresetRemote {
    var presetsActive = true
    var presetsEditable = true
    var slots: [LightPreset?] = Array(repeating: nil, count: PresetStore.slotCount)
    var busy: String?
    var result: HubSnapshot.Presets.Result?
    var failNext: String?
    private(set) var paths: [String] = []

    var remotePresets: HubSnapshot.Presets? { HubSnapshot.Presets(slots: slots, busy: busy, result: result) }

    func presetRequest(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        paths.append(path)
        try? await Task.sleep(for: .milliseconds(20))
        if let failNext {
            self.failNext = nil
            throw HomeHelper.Failure.remote(failNext, code: nil)
        }
        let slot = body["slot"] as? Int ?? 0
        switch path {
        case "/api/presets/put":
            slots[slot] = LightPreset(id: slots[slot]?.id ?? "custom-hub\(slot)", name: body["name"] as? String ?? "",
                                      looks: (body["looks"] as? [[String: Any]] ?? []).compactMap(Self.look))
        case "/api/presets/rename":
            slots[slot]?.name = body["name"] as? String ?? ""
        case "/api/presets/clear":
            slots[slot] = nil
        case "/api/presets/import":
            var imported: [Int] = [], kept: [Int] = []
            for (i, raw) in (body["slots"] as? [Any] ?? []).enumerated() {
                guard let p = raw as? [String: Any] else { continue }
                if slots[i] != nil { kept.append(i); continue }
                slots[i] = LightPreset(id: p["id"] as? String ?? "", name: p["name"] as? String ?? "",
                                       looks: (p["looks"] as? [[String: Any]] ?? []).compactMap(Self.look))
                imported.append(i)
            }
            return ["ok": true, "imported": imported, "kept": kept]
        case "/api/lights/preset":
            result = HubSnapshot.Presets.Result(id: body["id"] as? String ?? "", text: nil, failed: false)
        default:
            throw HomeHelper.Failure.remote("Not found.", code: nil)
        }
        return ["ok": true]
    }

    func refreshPresets() async {}

    static func look(_ d: [String: Any]) -> BulbLook? {
        (try? JSONSerialization.data(withJSONObject: d)).flatMap { try? JSONDecoder().decode(BulbLook.self, from: $0) }
    }
}

/// `SamsungTV --presets-dryrun [dir]`: runs the light presets against `FakeBulbs`, saving to `dir`
/// (default: a temporary folder), and exits non-zero on any failure.
enum PresetSelfTest {
    @MainActor static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--presets-dryrun") else { return }
        let base = flag + 1 < args.count ? URL(fileURLWithPath: args[flag + 1]) : FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("presets-dryrun-\(UUID().uuidString.prefix(6))")
        var done = false
        var failures = 0
        Task { @MainActor in
            failures = await run(dir: dir)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        try? FileManager.default.removeItem(at: dir)
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func run(dir: URL) async -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        let file = dir.appendingPathComponent("light-presets.json")
        let fake = FakeBulbs()
        let lights = LightsModel(helper: fake, presets: PresetStore(fileURL: file))
        await lights.refresh()
        func label(_ index: Int) -> String { lights.bulbs.first { $0.id == index }?.label ?? "?" }
        func activeNow() async -> [String] {
            await lights.refresh()
            return (PresetConfig.builtIns + lights.presets.slots.compactMap { $0 }).filter { $0.isActive(on: lights.bulbs) }.map(\.name)
        }

        print("== Config")
        check(PresetConfig.builtIns.count == 5 && PresetStore.slotCount == 5, "5 built-ins and 5 editable slots")
        check(PresetConfig.builtIns.allSatisfy(\.isBuiltIn), "Built-ins are read-only (no bulb index)")
        check(lights.bulbs.map(\.id) == [2, 4, 3, 1] && lights.bulbs.map(\.label) == ["Light 1", "Light 2", "Light 3", "Light 4"],
              "Display order follows IP: \(lights.bulbs.map { "\($0.label)=#\($0.id)" })")
        check(lights.presets.slots.allSatisfy { $0 == nil }, "No saved presets on a fresh file")

        print("\n== Built-ins apply per bulb")
        for preset in PresetConfig.builtIns {
            let before = fake.applyCalls.count
            let manualBefore = lights.lastManualChange
            await lights.runPreset(preset)
            let sent = fake.applyCalls.last ?? []
            let expected = preset.resolved(for: lights.bulbs)
            var applied = true
            for look in expected {
                guard let b = fake.bulbs[look.index ?? 0] else { applied = false; continue }
                if look.mode == .colour {
                    let hsv = LightColour.hsv(hex: b.color)
                    applied = applied && b.on && b.mode == "colour" && abs((hsv?.v ?? 0) - Double(look.brightness) / 100) < 0.02
                } else {
                    applied = applied && b.on && b.mode == "white" && b.brightness == look.brightness && b.temp == look.temp
                }
            }
            check(fake.applyCalls.count == before + 1 && sent.count == 4, "\(preset.name): one lights.apply call with 4 looks")
            check(applied, "\(preset.name): every bulb got its look (\(expected.map(\.summary).joined(separator: ", ")))")
            check(lights.lastManualChange > manualBefore, "\(preset.name): marked as a manual change")
            check(lights.presetResult?.text == nil, "\(preset.name): no warning")
            let active = await activeNow()
            check(active == [preset.name], "\(preset.name): ticked, and only it: \(active)")
        }
        let orange = LightColour.hsv(hex: "ff5a00")!.h
        check(abs((LightColour.hsv(hex: fake.bulbs[2]?.color)?.h ?? -1) - orange) < 0.01 && fake.bulbs[2]?.color != fake.bulbs[1]?.color,
              "Sunset: Light 1 (bulb #2, lowest IP) is orange, Light 4 differs")

        print("\n== Save current")
        fake.bulbs[1]?.on = false
        fake.bulbs[2]?.mode = "colour"
        fake.bulbs[2]?.color = "#7f2d00"
        fake.bulbs[3]?.mode = "white"; fake.bulbs[3]?.brightness = 30; fake.bulbs[3]?.temp = 80; fake.bulbs[3]?.color = nil
        fake.bulbs[4]?.mode = "white"; fake.bulbs[4]?.brightness = 100; fake.bulbs[4]?.temp = 0; fake.bulbs[4]?.color = nil
        let statusBefore = fake.calls.filter { $0.method == "lights.status" }.count
        await lights.beginSave(slot: 0)
        check(fake.calls.filter { $0.method == "lights.status" }.count == statusBefore + 1, "Reads the bulbs fresh before saving")
        check(lights.pendingEdit?.slot == 0 && lights.pendingEdit?.name == "Preset 1", "Asks for a name, default \"Preset 1\"")
        let captured = lights.pendingEdit?.looks ?? []
        let c2 = captured.first { $0.index == 2 }
        check(captured.count == 4 && captured.first { $0.index == 1 }?.on == false, "Captures all 4, bulb #1 off")
        check(c2?.mode == .colour && c2?.brightness == 50 && c2?.colour == "ff5a00",
              "Dim colour split into full hex + level: \(c2?.colour ?? "-") at \(c2?.brightness ?? -1)%")
        check(captured.first { $0.index == 3 } == BulbLook(index: 3, on: true, mode: .white, brightness: 30, temp: 80),
              "White bulb captured with brightness and temp")
        check(fake.applyCalls.count == 5, "Saving sends nothing to the bulbs")
        lights.commitEdit(name: "   ")
        check(lights.pendingEdit == nil && lights.presets.slots[0]?.name == "Preset 1", "Blank name falls back to \"Preset 1\"")
        check(!lights.presets.slots[0]!.isBuiltIn, "Saved preset is editable")
        let active = await activeNow()
        check(active == ["Preset 1"], "The saved preset is ticked straight away: \(active)")

        print("\n== Apply a saved preset")
        await lights.runPreset(PresetConfig.builtIns[0])
        await lights.runPreset(lights.presets.slots[0]!)
        check(fake.bulbs[1]?.on == false, "Bulb that was off in the preset is turned off")
        let back = LightColour.hsv(hex: fake.bulbs[2]?.color), saved = LightColour.hsv(hex: "#7f2d00")!
        check(back.map { abs($0.v - saved.v) < 0.01 && abs($0.h - saved.h) < 0.01 } == true,
              "Colour comes back at the saved level: \(fake.bulbs[2]?.color ?? "-") (saved from #7f2d00)")
        check(fake.bulbs[3]?.brightness == 30 && fake.bulbs[3]?.temp == 80, "White comes back with brightness and temp")
        check(await activeNow() == ["Preset 1"], "Ticked after applying")

        print("\n== Rename, update, delete")
        let id = lights.presets.slots[0]!.id
        lights.pendingEdit = PresetEdit(slot: 0, name: "Preset 1")
        lights.commitEdit(name: " Reading ")
        check(lights.presets.slots[0]?.name == "Reading" && lights.presets.slots[0]?.id == id, "Rename keeps the looks and id, trims the name")
        fake.bulbs[3]?.brightness = 60
        fake.bulbs[3]?.temp = 20
        let applies = fake.applyCalls.count
        await lights.updateToCurrent(slot: 0)
        check(lights.presets.slots[0]?.looks.first { $0.index == 3 }?.brightness == 60 && lights.presets.slots[0]?.name == "Reading",
              "Update to current lights re-captures, keeps the name")
        check(fake.applyCalls.count == applies, "Updating sends nothing to the bulbs")
        await lights.beginSave(slot: 3)
        lights.commitEdit(name: "Temporary")
        check(lights.presets.slots[3]?.name == "Temporary", "Second slot saved")
        lights.presets.delete(3)
        check(lights.presets.slots[3] == nil, "Delete empties the slot")
        await lights.beginSave(slot: 4)
        lights.pendingEdit = nil
        check(lights.presets.slots[4] == nil, "Cancelling the name leaves the slot empty")

        print("\n== Persistence")
        let reloaded = PresetStore(fileURL: file)
        check(reloaded.slots == lights.presets.slots, "Round-trips through \(file.lastPathComponent)")
        let json = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(json.contains("\"Reading\"") && json.contains("\"version\" : 1"), "File is readable JSON with a version")
        try? Data("{not json".utf8).write(to: file)
        check(PresetStore(fileURL: file).slots.allSatisfy { $0 == nil }, "A corrupt file loads as empty slots, no crash")
        try? Data(json.utf8).write(to: file)

        print("\n== Partial failure")
        fake.dead = [3]
        await lights.runPreset(PresetConfig.builtIns[0])
        check(lights.presetResult?.text == "Bright: \(label(3)) didn't respond." && lights.presetResult?.failed == false,
              "One bulb down: warns by name: \(lights.presetResult?.text ?? "-")")
        check(fake.bulbs[1]?.on == true && fake.bulbs[1]?.brightness == 100, "The others still change")
        check(PresetConfig.builtIns[0].isActive(on: lights.bulbs), "Tick still shows from the bulbs that answered")
        await lights.beginSave(slot: 2)
        check(lights.pendingEdit?.missing == [label(3)] && lights.pendingEdit?.looks?.count == 3,
              "Saving with a bulb down: 3 looks, names the missing one")
        lights.commitEdit(name: "Three")
        check(lights.presetResult?.text?.contains("Saved without \(label(3))") == true, "Says it saved without it")
        fake.dead = []
        await lights.runPreset(lights.presets.slots[2]!)
        check(fake.applyCalls.last?.count == 3 && !(fake.applyCalls.last ?? []).contains { $0["index"] as? Int == 3 },
              "Applying it leaves the missing bulb alone")
        fake.dead = [1, 2, 3, 4]
        await lights.runPreset(PresetConfig.builtIns[1])
        check(lights.presetResult?.text == "None of the lights responded." && lights.presetResult?.failed == true, "All down: failure")
        fake.dead = []
        fake.unavailable = true
        await lights.runPreset(PresetConfig.builtIns[1])
        check(lights.presetResult?.text?.hasPrefix("Couldn't apply Focus") == true && lights.unavailable != nil,
              "Keys unavailable: says so, and the tab shows the unavailable card")
        await lights.beginSave(slot: 4)
        check(lights.pendingEdit == nil && lights.presetResult?.text?.hasPrefix("Couldn't read the lights") == true,
              "Can't save when the lights can't be read")
        fake.unavailable = false

        failures += await hubMode(dir: dir, check: check)

        print("\n== One at a time")
        let count = fake.applyCalls.count
        async let a: Void = lights.runPreset(PresetConfig.builtIns[0])
        async let b: Void = lights.runPreset(PresetConfig.builtIns[2])
        _ = await (a, b)
        check(fake.applyCalls.count == count + 1, "A second tap while one is applying is ignored")
        return failures
    }

    @MainActor private static func hubMode(dir: URL, check: (Bool, String) -> Void) async -> Int {
        print("\n== Home hub keeps the list")
        let suite = "presets-dryrun-\(UUID().uuidString.prefix(6))"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = dir.appendingPathComponent("hub-mode-presets.json")
        let fake = FakeBulbs()
        let store = PresetStore(fileURL: file, defaults: defaults)
        let lights = LightsModel(helper: fake, presets: store)
        await lights.refresh()
        store.save(0, name: "Mine", looks: [BulbLook(index: 1, on: true, mode: .white, brightness: 30, temp: 10)])
        store.save(1, name: "Second", looks: [BulbLook(index: 2, on: true, mode: .white, brightness: 60, temp: 50)])
        let remote = FakePresetRemote()
        remote.slots[1] = LightPreset(id: "custom-hub1", name: "Hub's own", looks: [BulbLook(index: 3, on: false, mode: .white, brightness: 50, temp: 0)])
        store.remote = remote
        check(store.onHub && store.slots[0] == nil && store.slots[1]?.name == "Hub's own", "Hub on: the slots shown are the hub's")
        check(store.localSlots[0]?.name == "Mine", "…and the Mac's own list is kept aside")

        await lights.copyPresetsToHubOnce(host: "hub.test")
        check(remote.slots[0]?.name == "Mine" && remote.slots[1]?.name == "Hub's own" && remote.slots[0]?.looks.first?.brightness == 30,
              "First link copies into empty slots and leaves the hub's slot 2 alone")
        check(lights.presetResult?.text == "Copied 1 preset to the hub. Slot 2 already had a preset on the hub, so it was left alone.",
              "Says what it copied and kept: \(lights.presetResult?.text ?? "-")")
        let sent = remote.paths.count
        await lights.copyPresetsToHubOnce(host: "hub.test")
        check(remote.paths.count == sent, "Only once per hub")

        await lights.beginSave(slot: 3)
        lights.commitEdit(name: "Hub save")
        await store.settle()
        check(remote.slots[3]?.name == "Hub save" && remote.slots[3]?.looks.count == 4, "Saving goes to the hub, with every bulb's look")
        check(store.localSlots[3] == nil && PresetStore(fileURL: file).slots[3] == nil, "…and doesn't touch the Mac's file")
        lights.pendingEdit = PresetEdit(slot: 3, name: "Hub save")
        lights.commitEdit(name: "Evening")
        store.update(0, looks: [BulbLook(index: 1, on: true, mode: .white, brightness: 90, temp: 10)])
        store.delete(1)
        await store.settle()
        check(remote.slots[3]?.name == "Evening" && remote.slots[0]?.looks.first?.brightness == 90 && remote.slots[0]?.name == "Mine"
              && remote.slots[1] == nil, "Rename, update and delete go to the hub, in order")
        remote.failNext = "The home hub refused that (500)."
        store.rename(0, to: "Nope")
        await store.settle()
        check(lights.presetResult?.failed == true && lights.presetResult?.text?.contains("The hub didn't save that") == true,
              "A hub refusal shows under the grid")

        let applies = fake.applyCalls.count
        await lights.runPreset(store.slots[0]!)
        check(remote.paths.last == "/api/lights/preset" && fake.applyCalls.count == applies && lights.presetBusy == nil,
              "Applying a preset asks the hub, not the Mac's helper")

        remote.presetsEditable = false
        let paths = remote.paths.count
        let localApplies = fake.applyCalls.count
        check(store.slots[0]?.name == "Mine" && !store.editable, "Hub offline: the cached list still shows, read-only")
        await lights.runPreset(store.slots[0]!)
        check(fake.applyCalls.count == localApplies + 1 && remote.paths.count == paths, "…and a preset applies from this Mac")
        store.rename(0, to: "Offline edit")
        await store.settle()
        check(remote.paths.count == paths && lights.presetResult?.text == PresetStore.offlineNote, "…editing is refused with a clear note")
        await lights.beginSave(slot: 4)
        check(lights.pendingEdit == nil && remote.paths.count == paths, "…and Save current doesn't start")
        let copied = await store.copyToHub()
        check(copied.failed && remote.paths.count == paths, "…nor does copying presets to the hub")
        remote.presetsEditable = true

        remote.presetsActive = false
        check(!store.onHub && store.slots[0]?.name == "Mine" && store.slots[1]?.name == "Second" && store.slots[3] == nil,
              "Hub off: back to the Mac's own presets")
        store.remote = nil

        let json = #"{"slots":[{"id":"custom-a","name":"Ok","looks":[{"index":1,"on":true,"mode":"white","brightness":40,"temp":5,"colour":null}]},{"id":"x","looks":"broken"},null],"busy":null,"result":{"id":"custom-a","text":null,"failed":false}}"#
        let decoded = try? JSONDecoder().decode(HubSnapshot.Presets.self, from: Data(json.utf8))
        check(decoded?.slots.count == 3 && decoded?.slots[0]?.name == "Ok" && decoded?.slots[1] == .some(nil) && decoded?.result?.id == "custom-a",
              "The hub's presets decode, and a broken slot reads as empty")
        let cached = decoded.flatMap { try? JSONEncoder().encode(HubSnapshot.Presets(slots: $0.slots)) }
            .flatMap { try? JSONDecoder().decode(HubSnapshot.Presets.self, from: $0) }
        check(cached?.slots == decoded?.slots, "The offline cache round-trips the hub's list")
        return 0
    }
}
