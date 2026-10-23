import Foundation
import Observation

enum AutomationKind: String, CaseIterable, Identifiable, Sendable {
    case ps5Blue, tvOffNormal, tvOnEvening

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ps5Blue: "PS5 comes online"
        case .tvOffNormal: "TV turns off"
        case .tvOnEvening: "TV turns on in the evening"
        }
    }

    var detail: String {
        switch self {
        case .ps5Blue: "Lights go PlayStation blue."
        case .tvOffNormal: "Lights back to warm white 100%, only if they're on."
        case .tvOnEvening: "After \(AutomationConfig.eveningFrom):00 (until 0\(AutomationConfig.eveningUntil):00): lights warm white 40%."
        }
    }

    var icon: String {
        switch self {
        case .ps5Blue: "gamecontroller"
        case .tvOffNormal: "tv.slash"
        case .tvOnEvening: "sunset"
        }
    }

    var look: LightLook {
        switch self {
        case .ps5Blue: .colour(hex: SceneConfig.playStationBlue)
        case .tvOffNormal: .white(brightness: 100, temp: 0)
        case .tvOnEvening: .white(brightness: 40, temp: 0)
        }
    }
}

enum AutomationConfig {
    static let manualGrace: TimeInterval = 120
    static let cooldown: TimeInterval = 60
    static let eveningFrom = 18
    static let eveningUntil = 4
    // Turning off needs to hold longer than turning on: a single missed poll reads as "off",
    // while an "on" answer is positive evidence. PS5 is only probed every 30 s in the background.
    @Sendable static func tvHold(_ on: Bool) -> TimeInterval { on ? 3 : 12 }
    @Sendable static func ps5Hold(_ on: Bool) -> TimeInterval { on ? 0 : 75 }
}

/// Turns a stream of samples into confirmed transitions. The first sample only sets the baseline.
struct Debounced<State: Equatable & Sendable>: Sendable {
    private(set) var confirmed: State?
    private var candidate: State?
    private var since = Date.distantPast
    let hold: @Sendable (State) -> TimeInterval

    init(hold: @escaping @Sendable (State) -> TimeInterval) { self.hold = hold }

    mutating func feed(_ state: State, at now: Date) -> (from: State, to: State)? {
        guard let current = confirmed else { confirmed = state; return nil }
        if state == current { candidate = nil; return nil }
        if candidate != state { candidate = state; since = now }
        guard now.timeIntervalSince(since) >= hold(state) else { return nil }
        confirmed = state
        candidate = nil
        return (current, state)
    }
}

enum AutomationDecision: Equatable, Sendable {
    case fire(AutomationKind)
    case skip(AutomationKind, String)
}

/// Pure decision logic, so it can be checked offline (`--scenes-dryrun`).
struct AutomationLogic: Sendable {
    var tv = Debounced<Bool>(hold: AutomationConfig.tvHold)
    var ps5 = Debounced<Bool>(hold: AutomationConfig.ps5Hold)
    var lastFired: [AutomationKind: Date] = [:]

    mutating func step(tvOn: Bool?, ps5On: Bool?, now: Date, enabled: Set<AutomationKind>,
                       lastManual: Date, sceneRunning: Bool, calendar: Calendar = .current) -> [AutomationDecision] {
        var triggered: [AutomationKind] = []
        if let tvOn, let change = tv.feed(tvOn, at: now) {
            if change.to {
                let hour = calendar.component(.hour, from: now)
                if hour >= AutomationConfig.eveningFrom || hour < AutomationConfig.eveningUntil { triggered.append(.tvOnEvening) }
            } else {
                triggered.append(.tvOffNormal)
            }
        }
        if let ps5On, let change = ps5.feed(ps5On, at: now), change.to { triggered.append(.ps5Blue) }

        var out: [AutomationDecision] = []
        for kind in triggered where enabled.contains(kind) {
            if sceneRunning {
                out.append(.skip(kind, "a scene was running"))
            } else if now.timeIntervalSince(lastManual) < AutomationConfig.manualGrace {
                out.append(.skip(kind, "you changed the lights in the last 2 min"))
            } else if let last = lastFired[kind], now.timeIntervalSince(last) < AutomationConfig.cooldown {
                out.append(.skip(kind, "it ran less than a minute ago"))
            } else if kind == .tvOnEvening, ps5.confirmed == true {
                out.append(.skip(kind, "the PS5 is on, keeping the gaming lights"))
            } else {
                lastFired[kind] = now
                out.append(.fire(kind))
            }
        }
        return out
    }
}

struct AutomationEvent: Sendable {
    let at: Date
    let text: String
}

@MainActor
@Observable
final class AutomationEngine {
    private(set) var enabled: Set<AutomationKind> = []
    private(set) var events: [AutomationKind: AutomationEvent] = [:]

    @ObservationIgnored private var logic = AutomationLogic()
    @ObservationIgnored private let devices: SceneDevices
    @ObservationIgnored private let runner: SceneRunner
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored var log: ((String) -> Void)?
    /// With "Use home hub" on, the hub watches the TV and PS5 and this only mirrors its toggles and events.
    @ObservationIgnored var hub: HubLink?
    @ObservationIgnored private var mirrored = false
    @ObservationIgnored private(set) var standingIn = false

    init(devices: SceneDevices, runner: SceneRunner, defaults: UserDefaults = .standard) {
        self.devices = devices
        self.runner = runner
        self.defaults = defaults
        enabled = Set(AutomationKind.allCases.filter { defaults.bool(forKey: key($0)) })
    }

    private func key(_ kind: AutomationKind) -> String { "automation.\(kind.rawValue)" }

    func isOn(_ kind: AutomationKind) -> Bool { enabled.contains(kind) }

    func set(_ kind: AutomationKind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        if let hub, hub.enabled {
            if hub.active { hub.post("/api/automations/set", ["kind": kind.rawValue, "on": on]) }
            return
        }
        defaults.set(on, forKey: key(kind))
    }

    /// Samples the models once a second; they poll the devices on their own schedule.
    func start(tv: TVModel, ps5: PS5Model) {
        loop?.cancel()
        loop = Task { [weak self, weak tv, weak ps5] in
            while !Task.isCancelled {
                guard let self, let tv, let ps5 else { return }
                self.sample(tvOn: tv.hasPolled ? tv.power == .on : nil, ps5On: ps5.hasPolled ? ps5.status == .on : nil)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func sample(tvOn: Bool?, ps5On: Bool?, now: Date = Date()) {
        if let hub, hub.active {
            standingIn = false
            if let a = hub.snapshot?.automations {
                mirrored = true
                enabled = Set(a.enabled.compactMap(AutomationKind.init(rawValue:)))
                events = Dictionary(uniqueKeysWithValues: a.events.compactMap { k, e in
                    AutomationKind(rawValue: k).map { ($0, AutomationEvent(at: Date(timeIntervalSince1970: e.at), text: e.text)) }
                })
            }
            return
        }
        if hub?.enabled == true {
            // Hub offline: keep its toggles and watch the TV and PS5 here, starting from a fresh baseline.
            if !standingIn {
                standingIn = true
                mirrored = false
                logic = AutomationLogic()
                log?("automations: the home hub is offline, running them on this Mac")
            }
        } else if mirrored || standingIn {
            mirrored = false
            standingIn = false
            logic = AutomationLogic()
            events = [:]
            enabled = Set(AutomationKind.allCases.filter { defaults.bool(forKey: key($0)) })
        }
        let decisions = logic.step(tvOn: tvOn, ps5On: ps5On, now: now, enabled: enabled,
                                   lastManual: devices.lastManualLightsChange, sceneRunning: runner.running)
        for decision in decisions {
            switch decision {
            case .skip(let kind, let reason): record(kind, "Skipped: \(reason)")
            case .fire(let kind): Task { await fire(kind) }
            }
        }
    }

    func fire(_ kind: AutomationKind) async {
        log?("automation \(kind.rawValue) fired")
        if kind == .tvOffNormal {
            switch await devices.lightsAnyOn() {
            case nil: record(kind, "Skipped: couldn't read the lights"); return
            case .some(false): record(kind, "Skipped: the lights were off"); return
            case .some(true): break
            }
        }
        // Re-checked because reading the lights can take a few seconds.
        if Date().timeIntervalSince(devices.lastManualLightsChange) < AutomationConfig.manualGrace || runner.running {
            record(kind, "Skipped: you changed the lights in the meantime")
            return
        }
        switch await devices.lights(kind.look, manual: false) {
        case .done: record(kind, "Ran")
        case .warning(let text): record(kind, "Ran: \(text)")
        case .failed(let text): record(kind, "Failed: \(text)")
        default: break
        }
    }

    private func record(_ kind: AutomationKind, _ text: String) {
        events[kind] = AutomationEvent(at: Date(), text: text)
        log?("automation \(kind.rawValue): \(text)")
    }
}
