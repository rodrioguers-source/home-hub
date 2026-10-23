import Foundation

/// Seconds per day per bucket. Buckets are app keys, plus `tv` (total time on), `other` (on, no known app visible)
/// and `ps5` (console on, tracked independently of the TV).
struct UsageHistory: Codable {
    var days: [String: [String: Double]] = [:]
}

@MainActor
final class UsageStore {
    static let tvKey = "tv"
    static let otherKey = "other"
    static let ps5Key = "ps5"

    private(set) var history = UsageHistory()
    private var lastSample: Date?
    private var lastPS5Sample: Date?
    private var lastSave = Date.distantPast

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SamsungTVRemote/usage.json")
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(UsageHistory.self, from: data) {
            history = decoded
        }
    }

    /// Called on each poll. Gaps longer than 20 s (Mac asleep, app paused) are not counted.
    func sample(tvOn: Bool, visibleAppKey: String?, now: Date = Date()) {
        defer { lastSample = tvOn ? now : nil }
        guard tvOn, let last = lastSample else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0, elapsed <= 20 else { return }

        let day = Self.dayFormatter.string(from: now)
        var buckets = history.days[day, default: [:]]
        buckets[Self.tvKey, default: 0] += elapsed
        buckets[visibleAppKey ?? Self.otherKey, default: 0] += elapsed
        history.days[day] = buckets

        if now.timeIntervalSince(lastSave) > 60 { save() }
    }

    /// PS5 is probed every ~30 s, so gaps up to 45 s count.
    func samplePS5(on: Bool, now: Date = Date()) {
        defer { lastPS5Sample = on ? now : nil }
        guard on, let last = lastPS5Sample else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0, elapsed <= 45 else { return }
        history.days[Self.dayFormatter.string(from: now), default: [:]][Self.ps5Key, default: 0] += elapsed
        if now.timeIntervalSince(lastSave) > 60 { save() }
    }

    func save() {
        lastSave = Date()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
        } catch {}
    }

    func totals(lastDays: Int, now: Date = Date()) -> [String: Double] {
        var result: [String: Double] = [:]
        let calendar = Calendar.current
        for offset in 0..<lastDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            for (key, value) in history.days[Self.dayFormatter.string(from: date)] ?? [:] {
                result[key, default: 0] += value
            }
        }
        return result
    }
}
