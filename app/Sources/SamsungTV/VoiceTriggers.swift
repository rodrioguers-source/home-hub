import Foundation
import Observation

enum VoiceTriggerConfig {
    static let interval: Double = 4
    static let backoff: Double = 30
    static let staleAfter: TimeInterval = 120
    /// SmartThings virtual switch label per scene id. Alexa sees them after "Alexa, discover devices".
    static let switches: [String: String] = ["cinema": "Cinema", "gaming": "Gaming", "goodnight": "Good Night",
                                             "normal": "Back to Normal"]
    static var names: [String] { SceneConfig.scenes.compactMap { switches[$0.id] } }
}

struct VoiceTrigger: Decodable, Sendable {
    let deviceId: String
    let name: String
    let on: Bool
    let changedAt: String?

    var changed: Date? {
        guard let changedAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: changedAt) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: changedAt)
    }
}

struct VoiceTriggerList: Decodable, Sendable {
    let triggers: [VoiceTrigger]
    let missing: [String]
}

@MainActor
protocol VoiceTriggerSource: AnyObject {
    func fetch(_ names: [String]) async throws -> VoiceTriggerList
    func reset(_ deviceID: String) async throws
    /// Switches it off only if it's still on; false means someone else (the hub) got there first.
    func claim(_ deviceID: String) async throws -> Bool
}

@MainActor
final class HelperTriggerSource: VoiceTriggerSource {
    private let helper: HomeHelper

    init(helper: HomeHelper) { self.helper = helper }

    func fetch(_ names: [String]) async throws -> VoiceTriggerList {
        try await helper.call("st.triggers", ["names": names], timeout: 60, as: VoiceTriggerList.self)
    }

    func reset(_ deviceID: String) async throws {
        _ = try await helper.call("st.reset_trigger", ["id": deviceID], timeout: 30)
    }

    func claim(_ deviceID: String) async throws -> Bool {
        struct Claim: Decodable { let claimed: Bool }
        return try await helper.call("st.claim_trigger", ["id": deviceID], timeout: 30, as: Claim.self).claimed
    }
}

/// Polls the SmartThings virtual switches Alexa turns on, switches them back off and runs the matching
/// scene. A locked 1Password only fails these calls (the helper never re-prompts), so they just back off.
@MainActor
@Observable
final class VoiceTriggers {
    private(set) var enabled: Bool
    var last: AutomationEvent?
    var problem: String?

    @ObservationIgnored private let source: VoiceTriggerSource
    @ObservationIgnored private let runner: SceneRunner
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var handled: Set<String> = []
    @ObservationIgnored private var polled = false
    @ObservationIgnored private var active: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored var log: ((String) -> Void)?
    /// With "Use home hub" on, the hub polls the switches and this only mirrors it. While the hub is offline
    /// this polls them itself, claiming each switch (see `VoiceTriggerSource.claim`), so a scene never runs twice.
    @ObservationIgnored var hub: HubLink?
    @ObservationIgnored private var mirrored = false
    @ObservationIgnored private(set) var standingIn = false

    private static let key = "voiceTriggers.enabled"

    init(source: VoiceTriggerSource, runner: SceneRunner, defaults: UserDefaults = .standard) {
        self.source = source
        self.runner = runner
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func set(_ on: Bool) {
        if let hub, hub.enabled {
            enabled = on
            if hub.active { hub.post("/api/voice/set", ["on": on]) }
            return
        }
        enabled = on
        defaults.set(on, forKey: Self.key)
        if !on { problem = nil }
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.tick()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// One poll; returns the seconds to wait before the next.
    func tick(now: Date = Date()) async -> Double {
        if let hub, hub.active {
            if standingIn { log?("voice triggers: the home hub is back, it polls them again") }
            standingIn = false
            mirror(hub)
            return VoiceTriggerConfig.interval
        }
        let hubDown = hub?.enabled == true
        if hubDown {
            if !standingIn {
                standingIn = true
                mirrored = false
                polled = false
                handled = []
                log?("voice triggers: the home hub is offline, polling them on this Mac")
            }
        } else if mirrored || standingIn {
            mirrored = false
            standingIn = false
            enabled = defaults.object(forKey: Self.key) as? Bool ?? true
            last = nil
            problem = nil
            polled = false
        }
        guard enabled else { return VoiceTriggerConfig.interval }
        let list: VoiceTriggerList
        do {
            list = try await source.fetch(VoiceTriggerConfig.names)
        } catch {
            problem = Self.describe(error)
            return VoiceTriggerConfig.backoff
        }
        let firstPoll = !polled
        polled = true
        problem = list.missing.isEmpty ? nil : "Not found in SmartThings: \(list.missing.joined(separator: ", "))."

        let on = list.triggers.filter(\.on).sorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) }
        // A switch whose reset didn't stick still reads on with the same timestamp; that must not run twice.
        let keys = Set(on.map { "\($0.deviceId)@\($0.changedAt ?? "")" })
        var resetFailed = false
        var started = false
        // Standing in for the hub: if it answers again now, leave the switches to it.
        if hubDown, !on.isEmpty, let hub, await hub.reachableNow() {
            standingIn = false
            mirror(hub)
            return VoiceTriggerConfig.interval
        }
        for trigger in on {
            let isNew = handled.insert("\(trigger.deviceId)@\(trigger.changedAt ?? "")").inserted
            var claimed = true
            do {
                if hubDown {
                    claimed = try await source.claim(trigger.deviceId)
                } else {
                    try await source.reset(trigger.deviceId)
                }
            } catch {
                resetFailed = true
                problem = "Couldn't switch \(trigger.name) back off: \(Self.describe(error))"
            }
            guard isNew, let scene = SceneConfig.scenes.first(where: { VoiceTriggerConfig.switches[$0.id] == trigger.name }) else { continue }
            if !claimed {
                record(scene, "Already handled by the home hub")
                continue
            }
            let stale = trigger.changed.map { now.timeIntervalSince($0) > VoiceTriggerConfig.staleAfter } ?? firstPoll
            if stale {
                record(scene, "Ignored, switched on more than 2 min ago")
            } else if started || runner.running || active != nil {
                record(scene, "Skipped, another scene was running")
            } else {
                started = true
                run(scene)
            }
        }
        handled.formIntersection(keys)
        return resetFailed ? VoiceTriggerConfig.backoff : VoiceTriggerConfig.interval
    }

    private func mirror(_ hub: HubLink) {
        mirrored = true
        guard let v = hub.snapshot?.voice else {
            problem = hub.problem
            return
        }
        enabled = v.enabled
        last = v.last.map { AutomationEvent(at: Date(timeIntervalSince1970: $0.at), text: $0.text) }
        problem = v.problem ?? hub.problem
    }

    private func run(_ scene: SceneDef) {
        record(scene, "Running…")
        active = Task {
            await runner.runAndWait(scene)
            record(scene, runner.current?.summary ?? "Done")
            active = nil
        }
    }

    /// For the dry run: waits for a scene started by a trigger.
    func waitForRun() async { await active?.value }

    private func record(_ scene: SceneDef, _ text: String) {
        last = AutomationEvent(at: Date(), text: "\(scene.name): \(text)")
        log?("voice trigger \(scene.id): \(text)")
    }

    private static func describe(_ error: Error) -> String {
        if case HomeHelper.Failure.remote(let message, _) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? "SmartThings didn't answer."
    }
}
