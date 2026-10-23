import SwiftUI
import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto (dark 18:00–07:00)"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Light or dark look for the panel. Auto follows London time, not the Mac's appearance.
@MainActor
@Observable
final class AppearanceModel {
    static let darkFrom = 18
    static let lightFrom = 7
    static let zone = TimeZone(identifier: "Europe/London")!

    var mode: AppearanceMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.key)
            update()
        }
    }
    private(set) var scheme: ColorScheme = .dark

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appliesToApp: Bool
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?
    private static let key = "appearance.mode"

    init(defaults: UserDefaults = .standard, appliesToApp: Bool = true) {
        self.defaults = defaults
        self.appliesToApp = appliesToApp
        mode = defaults.string(forKey: Self.key).flatMap(AppearanceMode.init) ?? .auto
        update()
    }

    /// For snapshots: a fixed look that never touches the saved setting.
    init(fixed scheme: ColorScheme) {
        defaults = UserDefaults(suiteName: "com.rodrigocarneiro.samsungtv.appearance-fixed")!
        appliesToApp = false
        mode = scheme == .dark ? .dark : .light
        self.scheme = scheme
    }

    /// Re-checks the clock, e.g. when the panel opens after the Mac slept through a boundary.
    func update(now: Date = Date()) {
        let next = resolved(at: now)
        if next != scheme { scheme = next }
        if appliesToApp { NSApp?.appearance = NSAppearance(named: next == .dark ? .darkAqua : .aqua) }
        scheduleBoundary(now: now)
    }

    /// The look right now, without waiting for the next boundary timer. The phone page asks on every load.
    func resolved(at now: Date = Date()) -> ColorScheme {
        switch mode {
        case .light: .light
        case .dark: .dark
        case .auto: Self.autoScheme(at: now)
        }
    }

    static func autoScheme(at date: Date) -> ColorScheme {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        return hour >= darkFrom || hour < lightFrom ? .dark : .light
    }

    static func nextBoundary(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return [darkFrom, lightFrom].compactMap {
            calendar.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }.min() ?? date.addingTimeInterval(3600)
    }

    private func scheduleBoundary(now: Date) {
        boundaryTask?.cancel()
        guard mode == .auto, appliesToApp else { return }
        let wait = max(1, Self.nextBoundary(after: now).timeIntervalSince(now) + 1)
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }
}
