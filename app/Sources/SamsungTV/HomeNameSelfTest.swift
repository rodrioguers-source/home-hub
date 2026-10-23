import Foundation
import dnssd

@MainActor
final class FakeAdvertiser: NameAdvertiser {
    private(set) var events: [String] = []
    var refuse: String?
    private var onLost: (@MainActor (String) -> Void)?

    func publish(host: String, ip: String, interface: UInt32, port: UInt16, ttl: UInt32,
                 onLost: @escaping @MainActor (String) -> Void) -> String? {
        if let refuse { return refuse }
        self.onLost = onLost
        events.append("publish \(host) \(ip) port \(port) ttl \(ttl)")
        return nil
    }

    func withdraw() { events.append("withdraw") }

    func conflict() { onLost?("another device already answers for that name") }

    func take() -> [String] {
        defer { events = [] }
        return events
    }
}

/// `SamsungTV --homename-dryrun`: the homehub.local stand-in against an in-memory hub and a fake advertiser,
/// the paired-phone mirror, and one real Bonjour registration that stays on this Mac (LocalOnly, no packets).
enum HomeNameSelfTest {
    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains("--homename-dryrun") else { return }
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
        let suite = "com.rodrigocarneiro.samsungtv.homename-dryrun"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        print("== homehub.local follows the hub")
        let fake = FakeHub()
        let hub = fake.link(defaults: defaults)
        var clock = Date()
        hub.now = { clock }
        let ad = FakeAdvertiser()
        let name = HomeName()
        name.advertiser = ad
        name.now = { clock }
        var port: UInt16? = WebConfig.port
        var address: (ip: String, interface: UInt32)? = ("192.168.0.31", 4)
        name.wanted = { hub.enabled && hub.offline }
        name.port = { port }
        name.address = { address }
        hub.onPoll = { name.update() }

        await hub.refresh()
        check(ad.take().isEmpty && name.publishedIP == nil, "Hub up: the Mac doesn't answer homehub.local")
        fake.up = false
        await hub.refresh()
        clock += 30
        await hub.refresh()
        check(ad.take().isEmpty && !hub.offline, "Hub down for 30 s: still not answering")
        clock += 31
        await hub.refresh()
        check(hub.offline && ad.take() == ["publish homehub.local 192.168.0.31 port 8787 ttl 30"] && name.publishedIP == "192.168.0.31",
              "Down for over 60 s: answers homehub.local -> this Mac, TTL 30 s")
        check(name.note == "Answering homehub.local at 192.168.0.31", "Panel note says so")
        await hub.refresh()
        check(ad.take().isEmpty, "Next poll, same address: nothing re-sent")
        address = ("192.168.0.44", 4)
        await hub.refresh()
        check(ad.take() == ["publish homehub.local 192.168.0.44 port 8787 ttl 30"] && name.publishedIP == "192.168.0.44",
              "The Mac's IP changes: re-announced at the new address within one poll")
        address = nil
        await hub.refresh()
        check(ad.take() == ["withdraw"] && name.publishedIP == nil, "No LAN address: withdrawn")
        address = ("192.168.0.44", 4)
        await hub.refresh()
        _ = ad.take()
        port = 8788
        await hub.refresh()
        check(ad.take() == ["withdraw"] && name.note?.contains("isn't on port 8787") == true,
              "Phone server fell back to another port: withdrawn, with a note")
        port = WebConfig.port
        await hub.refresh()
        check(ad.take().count == 1 && name.publishedIP != nil, "Port 8787 again: answering again")
        ad.conflict()
        check(ad.take() == ["withdraw"] && name.publishedIP == nil && name.note?.contains("another device") == true,
              "Conflict (someone else holds the name): withdrawn, with a note")
        await hub.refresh()
        check(ad.take().isEmpty, "…and it doesn't grab the name back straight away")
        clock += HomeName.retryAfter + 1
        await hub.refresh()
        check(ad.take().count == 1 && name.publishedIP != nil, "…but tries again after \(Int(HomeName.retryAfter)) s")

        fake.up = true
        await hub.refresh()
        check(!hub.offline && ad.take() == ["withdraw"] && name.publishedIP == nil, "Hub answers again: withdrawn on that same poll")
        await hub.refresh()
        check(ad.take().isEmpty, "Hub up: stays withdrawn")

        fake.up = false
        await hub.refresh()
        clock += 61
        await hub.refresh()
        _ = ad.take()
        fake.up = true
        check(await hub.reachableNow() && name.publishedIP != nil, "Flapping: a single good check before the next poll…")
        await hub.refresh()
        check(ad.take() == ["withdraw"] && name.publishedIP == nil, "…and the poll that sees it withdraws")

        fake.up = false
        await hub.refresh()
        clock += 61
        await hub.refresh()
        _ = ad.take()
        hub.turnOff()
        check(ad.take() == ["withdraw"] && name.publishedIP == nil, "Use home hub turned off while standing in: withdrawn")

        let ad2 = FakeAdvertiser()
        let refused = HomeName()
        refused.advertiser = ad2
        refused.wanted = { true }
        refused.port = { WebConfig.port }
        refused.address = { ("192.168.0.31", 4) }
        ad2.refuse = "mDNSResponder isn't running"
        refused.update()
        check(refused.publishedIP == nil && refused.note?.contains("mDNSResponder") == true, "A failed registration shows why")

        let hosted = HubLink(defaults: defaults, testHost: "homehub.local", testToken: String(repeating: "t", count: 40))
        let guardName = HomeName()
        guardName.advertiser = FakeAdvertiser()
        guardName.configure(hub: hosted, port: { WebConfig.port })
        check(!guardName.wanted(), "A hub saved as homehub.local itself is never shadowed by the Mac")

        failures += await mirror(check)
        failures += await live(check)
        return failures
    }

    @MainActor private static func mirror(_ check: (Bool, String) -> Void) async -> Int {
        print("\n== Paired phones shared with the hub")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homename-dryrun-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("web-devices.json")
        let suite = "com.rodrigocarneiro.samsungtv.homename-mirror"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let fake = FakeHub()
        let hub = fake.link(defaults: defaults)
        var clock = Date()
        hub.now = { clock }
        let store = PairingStore(fileURL: file)
        store.pairingForHub = { hub.enabled && hub.offline }
        hub.pairing = store

        let hubToken = "h" + String(repeating: "x", count: 42)
        fake.devices = [["hash": PairingStore.hash(hubToken), "label": "iPhone · Safari", "pairedAt": "2026-10-17T09:00:00Z"]]
        check(!store.isAuthorised(hubToken), "Before syncing, the hub's phone isn't known here")
        await hub.refresh()
        check(store.isAuthorised(hubToken), "A phone paired on the hub works on the Mac after one sync")
        let mirrorText = (try? String(contentsOf: dir.appendingPathComponent("hub-devices.json"), encoding: .utf8)) ?? ""
        check(mirrorText.contains(PairingStore.hash(hubToken)) && !mirrorText.contains(hubToken), "The mirror file holds the hash, never the token")
        check(PairingStore(fileURL: file).isAuthorised(hubToken), "The mirror survives a restart (works with the hub down from launch)")

        let code = store.startPairing()
        guard case .paired(let upToken) = store.pair(code: code, label: "iPhone", from: "192.168.0.50") else {
            check(false, "Pairs a phone on the Mac"); return 1
        }
        check(store.pendingForHub.isEmpty, "Paired on the Mac while the hub is up: not sent to the hub")

        fake.up = false
        await hub.refresh()
        clock += 61
        await hub.refresh()
        let code2 = store.startPairing()
        guard case .paired(let downToken) = store.pair(code: code2, label: "iPhone", from: "192.168.0.51") else {
            check(false, "Pairs a phone while the hub is down"); return 1
        }
        check(store.pendingForHub.count == 1 && store.isAuthorised(downToken), "Paired while the hub is down: works here, waiting for the hub")
        fake.up = true
        await hub.refresh()
        let sent = fake.imported.compactMap { $0["hash"] as? String }
        check(sent == [PairingStore.hash(downToken)], "Hub back: that phone's hash (only) is passed on")
        check(!fake.imported.contains { row in row.values.contains { "\($0)".contains(downToken) } }, "…never the token itself")
        check(store.pendingForHub.isEmpty, "…and it's no longer pending once the hub lists it")
        check(!sent.contains(PairingStore.hash(upToken)), "The phone paired while the hub was up stays Mac-only")

        fake.devices = []
        clock += HubLink.devicesEvery - 1
        await hub.refresh()
        check(store.isAuthorised(hubToken), "Within a minute the old mirror still applies")
        clock += 2
        await hub.refresh()
        check(!store.isAuthorised(hubToken), "Phones forgotten on the hub stop working here at the next sync")
        check(store.isAuthorised(downToken), "The Mac's own record of a phone it paired is kept")
        return 0
    }

    private final class Answers: @unchecked Sendable {
        var rows: [(ip: String, ttl: UInt32)] = []
    }

    /// Real registration with the LocalOnly interface: visible to this Mac only, nothing sent on the network.
    @MainActor private static func live(_ check: (Bool, String) -> Void) async -> Int {
        print("\n== Real Bonjour registration (LocalOnly, a test name, no network packets)")
        let localOnly = UInt32.max
        let host = "homehub-selftest.local"
        let ad = DNSSDAdvertiser(instance: "Home Hub selftest \(UUID().uuidString.prefix(4))")
        let failure = ad.publish(host: host, ip: "127.0.0.2", interface: localOnly, port: WebConfig.port, ttl: HomeName.ttl,
                                 onLost: { print("  note: lost \($0)") })
        check(failure == nil, "Registers \(host) without root: \(failure ?? "ok")")
        let first = await query(host + ".", interface: localOnly)
        check(first.contains { $0.ip == "127.0.0.2" }, "Resolves to the registered address: \(first.map(\.ip))")
        check(first.allSatisfy { $0.ttl <= HomeName.ttl && $0.ttl > 0 }, "Measured TTL \(first.map(\.ttl)) s (asked for \(HomeName.ttl))")
        ad.withdraw()
        try? await Task.sleep(for: .milliseconds(300))
        let after = await query(host + ".", interface: localOnly)
        check(after.isEmpty, "Withdrawn: no longer resolves (\(after.map(\.ip)))")
        return 0
    }

    @MainActor private static func query(_ name: String, interface: UInt32) async -> [(ip: String, ttl: UInt32)] {
        let answers = Answers()
        var ref: DNSServiceRef?
        let ctx = Unmanaged.passRetained(answers)
        defer { ctx.release() }
        let err = DNSServiceQueryRecord(&ref, 0, interface, name, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                        { _, flags, _, error, _, _, _, rdlen, rdata, ttl, context in
            guard error == DNSServiceErrorType(kDNSServiceErr_NoError), flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                  rdlen == 4, let rdata, let context else { return }
            let b = rdata.assumingMemoryBound(to: UInt8.self)
            let box = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
            box.rows.append(("\(b[0]).\(b[1]).\(b[2]).\(b[3])", ttl))
        }, ctx.toOpaque())
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else { return [] }
        DNSServiceSetDispatchQueue(ref, .main)
        try? await Task.sleep(for: .milliseconds(800))
        DNSServiceRefDeallocate(ref)
        return answers.rows
    }
}
