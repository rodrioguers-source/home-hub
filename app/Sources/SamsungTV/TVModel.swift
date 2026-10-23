import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class TVModel {
    var power: PowerState = .unreachable
    var hasPolled = false
    var modelName = "UE32F6000FKXXU"
    var visibleApp: TVApp?
    var runningApps: Set<String> = []
    var installed: [TVApp: String] = [:]
    var socketState: RemoteSocket.State = .idle
    var usageRevision = 0
    var waking = false
    private var turningOffUntil: Date?
    private var missedPolls = 0
    private var offRequestedAt: Date?
    private var wakeStartedAt: Date?
    private var lastDiscovery: Date?

    var launching: TVApp?

    let socket = RemoteSocket()
    let usage = UsageStore()
    let smartThings: SmartThingsModel
    private var pollTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var catalogueChecked = false

    init(helper: HomeHelper = HomeHelper(live: false), live: Bool = true) {
        smartThings = SmartThingsModel(helper: helper)
        guard live else { return }
        smartThings.isTVOn = { [weak self] in self?.power == .on }
        smartThings.start()
        socket.onChange = { [weak self] in
            guard let self else { return }
            self.socketState = self.socket.state
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        start()
    }

    private var lastPollAt = Date()
    private var watchdog: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        lastPollAt = Date()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                self.lastPollAt = Date()
                let fast = self.waking || self.power != .on
                try? await Task.sleep(for: .seconds(fast ? 3 : 5))
            }
        }
        // The panel once sat on "Disconnected" with no traffic to the TV at all: a poll had hung. Start a fresh loop.
        if watchdog == nil {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastPollAt) > 60 {
                        self.socket.disconnect()
                        self.start()
                    }
                }
            }
        }
    }

    func poll() async {
        var (reported, model) = await REST.power()
        if reported == .unreachable, Date().timeIntervalSince(lastDiscovery ?? .distantPast) > 60 {
            lastDiscovery = Date()
            if let ip = await REST.discover(), ip != TVConfig.host {
                TVConfig.host = ip
                socket.disconnect()
                (reported, model) = await REST.power()
            }
        }
        // A busy TV sometimes misses one REST poll; dropping the remote over that felt like random disconnects.
        if reported == .unreachable, power == .on, turningOffUntil == nil, missedPolls < 2 {
            missedPolls += 1
            return
        }
        missedPolls = 0
        // An off tapped while the TV was still waking can't go out until the remote connects, so hold it here.
        if let requested = offRequestedAt {
            if Date().timeIntervalSince(requested) > 60 {
                offRequestedAt = nil
            } else if reported == .on {
                turningOffUntil = Date().addingTimeInterval(30)
                socket.allowed = true
                socket.connectIfNeeded()
                if socket.isReady {
                    socket.key("KEY_POWER")
                    offRequestedAt = nil
                    power = .standby
                    return
                }
            }
        }
        var state = reported
        // The TV keeps answering "on" for a while after KEY_POWER, so trust the click until it drops off.
        if let until = turningOffUntil {
            if state != .on || Date() > until { turningOffUntil = nil } else { state = .standby }
        }
        power = state
        hasPolled = true
        if let model { modelName = model }

        socket.allowed = state == .on || offRequestedAt != nil
        // A TV that has dropped into deep standby often misses the first magic packet, so keep sending for a while.
        if waking, state != .on, let started = wakeStartedAt {
            if Date().timeIntervalSince(started) < 40 { WakeOnLAN.send() } else { waking = false; wakeStartedAt = nil }
        }
        if state == .on {
            waking = false
            wakeStartedAt = nil
            socket.connectIfNeeded()
            if !catalogueChecked { await checkCatalogue() }
            await refreshApps()
        } else {
            if offRequestedAt == nil { socket.disconnect() }
            visibleApp = nil
            runningApps = []
        }
        usage.sample(tvOn: state == .on, visibleAppKey: currentApp?.key)
        usageRevision += 1
    }

    private func checkCatalogue() async {
        let results = await withTaskGroup(of: (TVApp, AppStatus?).self) { group in
            for app in TVApp.all { group.addTask { (app, await REST.status(app.id)) } }
            var out: [(TVApp, AppStatus?)] = []
            for await r in group { out.append(r) }
            return out
        }
        var found: [TVApp: String] = [:]
        for (app, status) in results { if let status { found[app] = status.name ?? app.name } }
        installed = found
        catalogueChecked = !found.isEmpty
    }

    private func refreshApps() async {
        let apps = installed.isEmpty ? TVApp.favourites : Array(installed.keys)
        let results = await withTaskGroup(of: (TVApp, AppStatus?).self) { group in
            for app in apps { group.addTask { (app, await REST.status(app.id)) } }
            var out: [(TVApp, AppStatus?)] = []
            for await r in group { out.append(r) }
            return out
        }
        visibleApp = results.first { $0.1?.visible == true }?.0
        runningApps = Set(results.filter { $0.1?.running == true }.map { $0.0.id })
    }

    func key(_ key: String) { socket.key(key) }

    /// What's on screen: the local REST answer, else SmartThings' tvChannelName, which carries the
    /// app id for apps whose REST status is empty (Stremio).
    var currentApp: TVApp? {
        if let visibleApp { return visibleApp }
        guard power == .on, let name = smartThings.status?.tvChannelName, !name.isEmpty else { return nil }
        return TVApp.all.first { $0.id == name }
    }

    /// The input to highlight. SmartThings' HDMI report also goes stale when the TV moves to an app or live TV,
    /// so foreground info wins over it, unless the input was picked here in the last 15 s.
    var activeInput: STOption? {
        let st = smartThings
        guard st.usable, let input = st.currentInput else { return nil }
        if let chosen = st.chosenInput, Date().timeIntervalSince(chosen.at) < 15 { return input }
        guard power == .on, input.id.lowercased().hasPrefix("hdmi") else { return input }
        if currentApp != nil { return nil }
        let channel = st.status?.tvChannel ?? "", name = st.status?.tvChannelName ?? ""
        if !channel.isEmpty || (!name.isEmpty && !name.contains(".")) {
            return st.status?.inputs?.first { !$0.id.lowercased().hasPrefix("hdmi") }
        }
        return name.isEmpty ? input : nil
    }

    func launch(_ app: TVApp) {
        launchTask?.cancel()
        launchTask = Task { _ = await open(app) }
    }

    /// Sends the launch by the first path that works, and only falls through to the next when one errors,
    /// so the TV never gets asked twice. Seeing it on screen afterwards is reported but not required.
    func open(_ app: TVApp) async -> LaunchResult? {
        launching = app
        defer { if launching == app { launching = nil } }
        if await isOnScreen(app, cloud: false) { return LaunchResult(method: "already open", confirmed: true) }
        let st = smartThings
        let methods = [
            LaunchMethod(name: "SmartThings", window: 8) { st.usable ? await st.launch(app.id) == nil : false },
            LaunchMethod(name: "remote", window: 6) { [weak self] in
                guard let self, await self.remoteReady() else { return false }
                self.socket.launch(app.id)
                return true
            },
            LaunchMethod(name: "remote (native)", window: 6) { [weak self] in
                guard let self, self.socket.isReady else { return false }
                self.socket.launch(app.id, native: true)
                return true
            },
            LaunchMethod(name: "local network", window: 6) { await REST.launch(app.id); return true },
        ]
        let worked = await LaunchChain.run(methods) { [weak self] window in
            await self?.waitOnScreen(app, window: window) ?? false
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.poll()
        }
        return worked
    }

    private func waitOnScreen(_ app: TVApp, window: Double) async -> Bool {
        let start = Date()
        var lastCloud = Date()
        while Date().timeIntervalSince(start) < window, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let cloud = smartThings.usable && Date().timeIntervalSince(lastCloud) >= 3
            if cloud { lastCloud = Date() }
            if await isOnScreen(app, cloud: cloud) { return true }
        }
        return false
    }

    private func isOnScreen(_ app: TVApp, cloud: Bool) async -> Bool {
        if await REST.status(app.id)?.visible == true { return true }
        guard cloud else { return false }
        let before = smartThings.status?.tvChannelName
        await smartThings.fetch()
        // tvChannelName keeps the last app after the TV leaves it, so only a change counts.
        return before != app.id && smartThings.status?.tvChannelName == app.id
    }

    /// SmartThings accepts a launch while the TV is still waking but the TV drops it, so wait for the cloud to see it on.
    func waitForCloudReady(timeout: Double = 20) async {
        guard smartThings.usable else { return }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout, !Task.isCancelled {
            await smartThings.fetch(refresh: true)
            if smartThings.status?.power == "on" { break }
            try? await Task.sleep(for: .seconds(2))
        }
        try? await Task.sleep(for: .seconds(3))
    }

    private func remoteReady(timeout: Double = 6) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            switch socket.state {
            case .ready: return true
            case .tokenUnavailable, .unauthorized: return false
            default: socket.connectIfNeeded()
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    func togglePower() {
        if power == .on || waking {
            powerOff()
        } else {
            powerOn()
        }
    }

    func powerOff() {
        if socket.isReady {
            socket.key("KEY_POWER")
        } else {
            offRequestedAt = Date()
        }
        waking = false
        turningOffUntil = Date().addingTimeInterval(30)
        power = .standby
    }

    func powerOn() {
        offRequestedAt = nil
        turningOffUntil = nil
        waking = true
        wakeStartedAt = Date()
        WakeOnLAN.send()
        if smartThings.usable { Task { await smartThings.powerOn() } }
    }

    var refreshing = false

    func refreshNow() {
        guard !refreshing else { return }
        refreshing = true
        turningOffUntil = nil
        waking = false
        Task {
            async let minimumSpin: Void? = try? Task.sleep(for: .milliseconds(500))
            async let cloud: Void = smartThings.refreshNow()
            await poll()
            _ = await (minimumSpin, cloud)
            refreshing = false
        }
    }

    func retryConnection() {
        socket.retry()
        Task { await poll() }
    }

    func shutdown() {
        usage.save()
    }

    var statusText: String {
        if !hasPolled { return "Searching…" }
        switch power {
        case .on: return "Connected"
        case .standby: return "Standby"
        case .unreachable: return waking ? "Turning on…" : "Disconnected"
        }
    }

    var nowCaption: String {
        switch power {
        case .on:
            if let app = currentApp { return "\(app.name) in the foreground." }
            if let input = activeInput {
                return "No known app in the foreground. Last input: \(InputsCard.label(input))."
            }
            return "No known app in the foreground: it could be the home screen, live TV or HDMI."
        case .standby: return "The TV is on standby."
        case .unreachable: return waking ? "Wake-on-LAN packet sent, waiting for the TV…" : "The TV isn't responding on the network."
        }
    }

    var remoteStatusText: String {
        switch socketState {
        case .ready: return "Remote ready"
        case .connecting: return "Connecting…"
        case .fetchingToken: return "Waiting for 1Password…"
        case .unauthorized: return "Token rejected by the TV"
        case .tokenUnavailable: return "Token unavailable"
        case .idle: return power == .on ? "Reconnecting…" : "TV off"
        }
    }
}

struct LaunchMethod {
    let name: String
    /// Seconds to watch for the app on screen after sending, for the report only.
    let window: Double
    /// Returns false when the method can't be used or its send errored, so the chain moves on.
    let send: @MainActor () async -> Bool
}

struct LaunchResult: Equatable {
    let method: String
    let confirmed: Bool
}

enum LaunchChain {
    @MainActor static func run(_ methods: [LaunchMethod], confirm: @MainActor (Double) async -> Bool) async -> LaunchResult? {
        for method in methods {
            if Task.isCancelled { return nil }
            guard await method.send() else { continue }
            return LaunchResult(method: method.name, confirmed: await confirm(method.window))
        }
        return nil
    }
}
