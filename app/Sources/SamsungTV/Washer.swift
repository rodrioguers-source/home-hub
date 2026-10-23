import SwiftUI
import Observation
import UserNotifications

enum WasherConfig {
    static let pollActive: Double = 60
    static let pollIdle: Double = 300
    static let pollMissing: Double = 1800
    static let maxBackoff: Double = 900
    static let claimKeptFor: TimeInterval = 30 * 60
    /// Two readings of one cycle's estimated start differ by far less than this; back-to-back cycles by a whole cycle.
    static let sameCycleWithin: TimeInterval = 20 * 60
}

struct WasherStatus: Decodable, Equatable, Sendable {
    struct Phase: Decodable, Equatable, Sendable {
        var name: String
        var minutes: Int?
    }

    var found: Bool = true
    var label: String?
    var state: String?
    var stateSince: String?
    var phase: String?
    var jobState: String?
    var progress: Int?
    var remainingMin: Int?
    var operationMin: Int?
    var completionTime: String?
    var phases: [Phase]?
    var temp: String?
    var spin: String?
    var rinses: String?
    var kidsLock: Bool?
    var updatedAt: String?

    var active: Bool { state == "running" || state == "paused" }

    /// When this cycle started, as far as the washer's numbers say; stable across polls of one cycle.
    func estimatedStart(now: Date) -> Date {
        if let done = WasherText.date(completionTime), let total = operationMin { return done.addingTimeInterval(-Double(total) * 60) }
        if let done = WasherText.date(completionTime), let left = remainingMin, let p = progress, p > 0, p < 100 {
            return done.addingTimeInterval(-Double(left) * 60 / (1 - Double(p) / 100))
        }
        return now
    }

    /// Minutes left: counted down from the completion time while running, frozen while paused.
    func minutesLeft(now: Date) -> Int? {
        if state == "running", let done = WasherText.date(completionTime) {
            return max(Int((done.timeIntervalSince(now) / 60).rounded(.up)), 0)
        }
        return remainingMin.map { max($0, 0) }
    }
}

/// The cycle Rodrigo said is his. Persisted, so a relaunch mid-cycle keeps it.
struct WasherClaim: Codable, Equatable {
    var start: Date
    var finishedAt: Date?
    var notified = false
}

/// What the full bar shows; only ever for a claimed cycle.
enum WasherDisplay: Equatable {
    case hidden
    case running(phase: String?, progress: Int?, remaining: Int?, done: Date?)
    case paused(phase: String?, progress: Int?, remaining: Int?)
    case finished(at: Date)
}

/// The dim chip in the glance row for everyone else's washes.
enum WasherAvailability: Equatable {
    case free
    case busy(remaining: Int?, done: Date?)
    case paused(remaining: Int?)
}

enum WasherText {
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = GlanceConfig.london
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func phase(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "none" else { return nil }
        let names = ["wash": "Washing", "rinse": "Rinsing", "spin": "Spinning", "weightSensing": "Weighing",
                     "drying": "Drying", "dry": "Drying", "airWash": "Air wash", "cooling": "Cooling",
                     "delayWash": "Delayed start", "wrinklePrevent": "Anti-crease", "finish": "Finishing"]
        if let name = names[raw] { return name }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    static func minutes(_ m: Int) -> String {
        m <= 0 ? "Almost done" : "\(formatDuration(Double(m) * 60)) left"
    }

    static func detail(_ s: WasherStatus, fetchedAt: Date?) -> String {
        var parts = [s.label ?? "Washing machine"]
        if let t = s.temp, t != "none" { parts.append(t == "cold" ? "Cold" : "\(t) °C") }
        if let spin = s.spin {
            parts.append(["noSpin": "No spin", "rinseHold": "Rinse hold"][spin] ?? "\(spin) rpm")
        }
        if let r = s.rinses, let n = Int(r) { parts.append(n == 1 ? "1 rinse" : "\(n) rinses") }
        if s.active, let p = s.progress { parts.append("\(p)%") }
        if s.kidsLock == true { parts.append("Child lock on") }
        if let fetchedAt { parts.append("Checked \(clock(fetchedAt))") }
        return parts.joined(separator: " · ")
    }

    static func title(_ d: WasherDisplay) -> String {
        switch d {
        case .running(let raw, _, _, _): phase(raw) ?? "Washing"
        case .paused(let raw, _, _): phase(raw).map { "Paused · \($0)" } ?? "Paused"
        case .finished: "Your washing is done"
        case .hidden: ""
        }
    }

    static func trailing(_ d: WasherDisplay) -> String {
        switch d {
        case .running(_, _, let left, let done):
            let time = left.map(minutes) ?? ""
            guard let done, (left ?? 1) > 0 else { return time }
            return time.isEmpty ? "Done \(clock(done))" : "\(time) · done \(clock(done))"
        case .paused(_, _, let left): return left.map(minutes) ?? ""
        case .finished(let at): return "Finished at \(clock(at))"
        case .hidden: return ""
        }
    }

    /// A word or two for the narrow chip, then the full sentence for its tooltip.
    static func chip(_ a: WasherAvailability) -> (short: String, sentence: String) {
        switch a {
        case .free:
            return ("Free", "Washer free")
        case .busy(let left, let done):
            let sentence = "Washer busy" + (left.map { " · \(minutes($0))" } ?? "")
                + (done.map { (left ?? 1) > 0 ? " · done \(clock($0))" : "" } ?? "")
            return (left.map(compact) ?? "Busy", sentence)
        case .paused(let left):
            return ("Paused", "Washer paused" + (left.map { " · \(minutes($0))" } ?? ""))
        }
    }

    private static func compact(_ m: Int) -> String {
        if m <= 0 { return "Busy" }
        return m < 60 ? "\(m)m" : String(format: "%dh%02d", m / 60, m % 60)
    }
}

@MainActor
protocol WasherSource: AnyObject {
    func fetch() async throws -> WasherStatus
}

@MainActor
final class HelperWasherSource: WasherSource {
    private let helper: HomeHelper

    init(helper: HomeHelper) { self.helper = helper }

    func fetch() async throws -> WasherStatus {
        try await helper.call("st.washer", timeout: 90, as: WasherStatus.self)
    }
}

@MainActor
protocol WasherAlerts: AnyObject {
    func prepare()
    func post(_ title: String, _ body: String)
}

/// Fails quietly: an ad-hoc signed build may never be allowed to post notifications.
@MainActor
final class LiveWasherAlerts: NSObject, WasherAlerts, UNUserNotificationCenterDelegate {
    private var asked = false

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func prepare() {
        guard !asked, let center else { return }
        asked = true
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func post(_ title: String, _ body: String) {
        guard let center else { return }
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "washer.\(UUID().uuidString)", content: content, trigger: nil)
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            try? await center.add(request)
        }
    }

    /// A menu bar app counts as frontmost while its panel is open, which would otherwise swallow the banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// The building's shared washing machine through the helper's read-only st.washer. Everyone's cycles show
/// only as a dim free/busy chip; a cycle Rodrigo claims gets the full bar and a notification when it ends.
/// Polls every minute during a cycle and every 5 min otherwise. An auth failure stops it until the TV's
/// SmartThings poll works again, so a locked 1Password never turns into repeated Touch ID prompts.
@MainActor
@Observable
final class WasherModel {
    enum Phase: Equatable { case idle, ready, missing, unavailable(String) }

    var phase: Phase = .idle
    var status: WasherStatus?
    var fetchedAt: Date?
    var claim: WasherClaim? {
        didSet { save(claim, Self.claimKey) }
    }
    private(set) var notifyWhenFree: Bool {
        didSet { defaults.set(notifyWhenFree, forKey: Self.freeKey) }
    }
    @ObservationIgnored private(set) var failures = 0
    @ObservationIgnored private(set) var blockedAt: Date?
    @ObservationIgnored private var attemptedAt: Date?
    @ObservationIgnored private var lastPollActive: Bool?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let source: WasherSource
    @ObservationIgnored private let alerts: WasherAlerts
    @ObservationIgnored private let defaults: UserDefaults
    /// When SmartThings last answered the TV poll; nil while it's unavailable.
    @ObservationIgnored var smartThingsOK: () -> Date? = { nil }
    /// With "Use home hub" on, the hub polls the washer and keeps the claim; this mirrors it and still notifies.
    @ObservationIgnored var hub: HubLink?
    @ObservationIgnored private var hubSeen = false
    /// A claim made here while the hub was offline, to hand to the hub when it's back.
    @ObservationIgnored private var claimForHub = false

    private static let claimKey = "washer.claim"
    private static let freeKey = "washer.notifyWhenFree"

    init(source: WasherSource, alerts: WasherAlerts, defaults: UserDefaults = .standard) {
        self.source = source
        self.alerts = alerts
        self.defaults = defaults
        claim = defaults.data(forKey: Self.claimKey).flatMap { try? JSONDecoder().decode(WasherClaim.self, from: $0) }
        notifyWhenFree = defaults.bool(forKey: Self.freeKey)
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    var interval: Double {
        if failures > 0 { return min(WasherConfig.pollActive * pow(2, Double(failures)), WasherConfig.maxBackoff) }
        if phase == .missing { return WasherConfig.pollMissing }
        return status?.active == true ? WasherConfig.pollActive : WasherConfig.pollIdle
    }

    func due(now: Date = Date()) -> Bool {
        if let blockedAt {
            guard let ok = smartThingsOK(), ok > blockedAt else { return false }
        }
        return attemptedAt.map { now.timeIntervalSince($0) >= interval - 1 } ?? true
    }

    func tick(now: Date = Date()) async {
        if let hub, hub.active { return mirror(hub, now: now) }
        hubSeen = false
        if due(now: now) { await fetch(now: now) }
    }

    func fetch(now: Date = Date()) async {
        if let hub, hub.active {
            await hub.refresh()
            return mirror(hub, now: now)
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        attemptedAt = now
        let new: WasherStatus
        do {
            new = try await source.fetch()
        } catch {
            if case HomeHelper.Failure.remote(_, let code) = error, Self.isAuthFailure(code) {
                blockedAt = now
                failures = 0
            } else {
                blockedAt = nil
                failures += 1
            }
            phase = .unavailable(Self.describe(error))
            return
        }
        failures = 0
        blockedAt = nil
        fetchedAt = now
        guard new.found else {
            status = nil
            phase = .missing
            return
        }
        status = new
        phase = .ready
        follow(new, now: now)
    }

    // MARK: claims

    /// User-initiated, so it may ask for notification permission.
    func claimCurrent(now: Date = Date()) {
        guard let s = status, s.active else { return }
        if let hub, hub.enabled {
            if hub.active { hub.post("/api/washer/claim", [:]) } else { claimForHub = true }
        }
        claim = WasherClaim(start: s.estimatedStart(now: now))
        notifyWhenFree = false
        lastPollActive = true
        alerts.prepare()
    }

    func unclaim() {
        claim = nil
        claimForHub = false
        if let hub, hub.active { hub.post("/api/washer/unclaim", [:]) }
    }

    func setNotifyWhenFree(_ on: Bool) {
        notifyWhenFree = on && status?.active == true
        if let hub, hub.active { hub.post("/api/washer/notify-free", ["on": notifyWhenFree]) }
        if notifyWhenFree { alerts.prepare() }
    }

    private func mirror(_ hub: HubLink, now: Date) {
        guard let w = hub.snapshot?.washer else {
            phase = .unavailable(hub.problem ?? "Waiting for the home hub.")
            return
        }
        if claimForHub {
            claimForHub = false
            if claim != nil, w.claim == nil, w.status?.active == true {
                hub.post("/api/washer/claim", [:])
                return
            }
        }
        let before = (claim: claim, free: notifyWhenFree, seen: hubSeen)
        hubSeen = true
        switch w.phase {
        case "ready": phase = w.status == nil ? .missing : .ready
        case "missing": phase = .missing
        case "unavailable": phase = .unavailable(w.reason ?? "SmartThings didn't answer.")
        default: phase = .idle
        }
        status = w.phase == "missing" ? nil : w.status
        fetchedAt = w.fetchedAt.map { Date(timeIntervalSince1970: $0) }
        lastPollActive = status?.active
        let mirrored = w.claim.map {
            WasherClaim(start: Date(timeIntervalSince1970: $0.start), finishedAt: $0.finishedAt.map { Date(timeIntervalSince1970: $0) },
                        notified: $0.notified ?? false)
        }
        if mirrored != claim { claim = mirrored }
        if notifyWhenFree != w.notifyWhenFree { notifyWhenFree = w.notifyWhenFree }
        guard before.seen else { return }
        if let b = before.claim, b.finishedAt == nil, let f = claim?.finishedAt, now.timeIntervalSince(f) < WasherConfig.claimKeptFor {
            alerts.post("Your washing is done", "Finished at \(WasherText.clock(f))")
        }
        if before.free, !w.notifyWhenFree, status?.active != true {
            let ended = WasherText.date(status?.stateSince).map { min($0, now) } ?? now
            alerts.post("The washer is free", "Finished at \(WasherText.clock(ended))")
        }
    }

    private func follow(_ s: WasherStatus, now: Date) {
        defer { lastPollActive = s.active }
        if s.active {
            guard let c = claim else { return }
            let start = s.estimatedStart(now: now)
            // Seen running since the last poll means the same cycle even if a long pause moved the estimate.
            let same = c.finishedAt == nil && (lastPollActive == true || abs(start.timeIntervalSince(c.start)) < WasherConfig.sameCycleWithin)
            if same { claim?.start = start } else { claim = nil }
            return
        }
        let endedAt = WasherText.date(s.stateSince).map { min($0, now) } ?? now
        if var c = claim, c.finishedAt == nil {
            c.finishedAt = endedAt < c.start ? now : endedAt
            if !c.notified, now.timeIntervalSince(c.finishedAt!) < WasherConfig.claimKeptFor {
                alerts.post("Your washing is done", "Finished at \(WasherText.clock(c.finishedAt!))")
            }
            c.notified = true
            claim = c
        }
        if notifyWhenFree {
            notifyWhenFree = false
            alerts.post("The washer is free", "Finished at \(WasherText.clock(endedAt))")
        }
        if let f = claim?.finishedAt, now.timeIntervalSince(f) >= WasherConfig.claimKeptFor { claim = nil }
    }

    private func liveClaim(now: Date) -> WasherClaim? {
        guard let c = claim else { return nil }
        if let f = c.finishedAt, now.timeIntervalSince(f) >= WasherConfig.claimKeptFor { return nil }
        return c
    }

    // MARK: display

    func display(now: Date = Date()) -> WasherDisplay {
        guard let s = status, let c = liveClaim(now: now) else { return .hidden }
        if let f = c.finishedAt { return s.active ? .hidden : .finished(at: f) }
        switch s.state {
        case "running":
            return .running(phase: s.phase, progress: s.progress, remaining: s.minutesLeft(now: now), done: WasherText.date(s.completionTime))
        case "paused":
            return .paused(phase: s.phase, progress: s.progress, remaining: s.minutesLeft(now: now))
        default:
            return .hidden
        }
    }

    /// nil while the claimed bar is showing, or when there's no washer to report.
    func availability(now: Date = Date()) -> WasherAvailability? {
        guard let s = status, display(now: now) == .hidden else { return nil }
        switch s.state {
        case "running": return .busy(remaining: s.minutesLeft(now: now), done: WasherText.date(s.completionTime))
        case "paused": return .paused(remaining: s.minutesLeft(now: now))
        default: return .free
        }
    }

    private func save(_ claim: WasherClaim?, _ key: String) {
        if let claim, let data = try? JSONEncoder().encode(claim) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func isAuthFailure(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.hasPrefix("st_") || code.hasPrefix("op_") || code == "reauth_needed" || code == "token_failed"
    }

    private static func describe(_ error: Error) -> String {
        if case HomeHelper.Failure.remote(let message, _) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? "SmartThings didn't answer."
    }
}

// MARK: Views

/// Dim free/busy pill at the end of the glance row. Clicking a busy one offers the claim and the free alert.
struct WasherChip: View {
    let washer: WasherModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let a = washer.availability(now: context.date), let s = washer.status {
                let text = WasherText.chip(a)
                if a == .free {
                    pill(text, bell: false).help("\(text.sentence)\n\(WasherText.detail(s, fetchedAt: washer.fetchedAt))")
                } else {
                    Menu {
                        Button("This one's mine") { washer.claimCurrent() }
                        Toggle("Tell me when it's free", isOn: Binding(get: { washer.notifyWhenFree }, set: { washer.setNotifyWhenFree($0) }))
                    } label: {
                        pill(text, bell: washer.notifyWhenFree)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(text.sentence)\(washer.notifyWhenFree ? " · you'll be told when it's free" : "")\n\(WasherText.detail(s, fetchedAt: washer.fetchedAt))")
                }
            }
        }
    }

    /// Narrow on purpose: it shares the row with the weather and Arsenal pills.
    private func pill(_ text: (short: String, sentence: String), bell: Bool) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "washer").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .overlay(alignment: .topTrailing) {
                    if bell { Image(systemName: "bell.fill").font(.system(size: 7)).foregroundStyle(Theme.accent).offset(x: 6, y: -2) }
                }
            Text(text.short).font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(Theme.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 5).frame(minWidth: 32).frame(height: 34)
        .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// The full row under the glance pills for a claimed cycle, until 30 min after it ends.
struct WasherBar: View {
    let washer: WasherModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let display = washer.display(now: context.date)
            if display != .hidden, let status = washer.status {
                Menu {
                    Button(display.isFinished ? "Dismiss" : "Not mine") { washer.unclaim() }
                } label: {
                    row(display, status, now: context.date)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help(WasherText.detail(status, fetchedAt: washer.fetchedAt))
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    private func row(_ display: WasherDisplay, _ s: WasherStatus, now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: display.isPaused ? "pause.fill" : "washer.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint(display), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(WasherText.title(display)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(WasherText.trailing(display)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                }
                switch display {
                case .running(let phase, let progress, _, _), .paused(let phase, let progress, _):
                    PhaseProgress(segments: WasherProgress.fills(s.phases ?? [], progress: progress, current: phase),
                                  tint: tint(display))
                case .finished(let at):
                    Text("Unload me · \(formatDuration(max(now.timeIntervalSince(at), 60))) ago")
                        .font(.system(size: 9)).foregroundStyle(Theme.tertiary).lineLimit(1)
                case .hidden:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    private func tint(_ d: WasherDisplay) -> Color {
        switch d {
        case .paused: Theme.standby
        case .finished: Theme.online
        default: Theme.accent
        }
    }
}

private extension WasherDisplay {
    var isFinished: Bool { if case .finished = self { true } else { false } }
    var isPaused: Bool { if case .paused = self { true } else { false } }
}

enum WasherProgress {
    struct Segment: Equatable { var weight: Double; var fill: Double }

    /// Phases before the current one are full and later ones empty; the current one is filled from overall progress.
    static func fills(_ phases: [WasherStatus.Phase], progress: Int?, current: String?) -> [Segment] {
        let p = min(max(Double(progress ?? 0) / 100, 0), 1)
        let weights = phases.map { Double(max($0.minutes ?? 0, 1)) }
        let total = weights.reduce(0, +)
        guard phases.count > 1, let at = phases.firstIndex(where: { $0.name == current }) else {
            return [Segment(weight: 1, fill: p)]
        }
        var start = 0.0
        return phases.indices.map { i in
            defer { start += weights[i] }
            if i < at { return Segment(weight: weights[i], fill: 1) }
            if i > at { return Segment(weight: weights[i], fill: 0) }
            let within = (p * total - start) / weights[i]
            return Segment(weight: weights[i], fill: min(max(within, 0.06), 0.97))
        }
    }
}

private struct PhaseProgress: View {
    let segments: [WasherProgress.Segment]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 3
            let usable = geo.size.width - gap * CGFloat(segments.count - 1)
            let total = segments.map(\.weight).reduce(0, +)
            HStack(spacing: gap) {
                ForEach(segments.indices, id: \.self) { i in
                    let width = usable * segments[i].weight / total
                    Capsule().fill(Theme.dimTrack)
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: width * segments[i].fill)
                        }
                        .frame(width: width)
                }
            }
        }
        .frame(height: 4)
    }
}
