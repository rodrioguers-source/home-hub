import SwiftUI
import Observation

enum GlanceConfig {
    static let latitude = 51.5362
    static let longitude = -0.1033
    static let place = "Islington"
    static let weatherEvery: Double = 15 * 60
    static let teamID = "359"
    static let teamShort = "ARS"
    static let matchEvery: Double = 60 * 60
    static let liveEvery: Double = 60
    static let london = TimeZone(identifier: "Europe/London")!

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: String) async -> Data? {
        guard let url = URL(string: url),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

// MARK: Weather (Open-Meteo, no key)

struct WeatherNow: Equatable, Sendable {
    var temp: Double
    var code: Int
    var isDay: Bool
    var high: Double?
    var low: Double?
    /// Highest precipitation probability over the next 3 hours.
    var rainChance: Int?

    var symbol: String { WeatherCode.symbol(code, day: isDay) }
    var summary: String { WeatherCode.text(code) }
}

enum WeatherCode {
    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77: "Snow"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95...99: "Thunderstorm"
        default: "Cloudy"
        }
    }
}

private struct OpenMeteo: Decodable {
    struct Current: Decodable { let time: String; let temperature_2m: Double; let weather_code: Int; let is_day: Int }
    struct Hourly: Decodable { let time: [String]; let precipitation_probability: [Int?] }
    struct Daily: Decodable { let temperature_2m_max: [Double?]; let temperature_2m_min: [Double?] }
    let current: Current
    let hourly: Hourly?
    let daily: Daily?

    var weather: WeatherNow {
        var rain: Int?
        if let hourly, let i = hourly.time.firstIndex(where: { $0.prefix(13) == current.time.prefix(13) }) {
            rain = hourly.precipitation_probability[i..<min(i + 3, hourly.time.count)].compactMap { $0 }.max()
        }
        return WeatherNow(temp: current.temperature_2m, code: current.weather_code, isDay: current.is_day == 1,
                          high: daily?.temperature_2m_max.first ?? nil, low: daily?.temperature_2m_min.first ?? nil,
                          rainChance: rain)
    }
}

@MainActor
@Observable
final class WeatherModel {
    static let shared = WeatherModel()

    var now: WeatherNow?
    var fetchedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    private static let cacheKey = "glance.weather"

    func start() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey) { apply(data, at: nil) }
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(GlanceConfig.weatherEvery))
            }
        }
    }

    func refresh() async {
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(GlanceConfig.latitude)&longitude=\(GlanceConfig.longitude)"
            + "&current=temperature_2m,weather_code,is_day&hourly=precipitation_probability"
            + "&daily=temperature_2m_max,temperature_2m_min&timezone=Europe%2FLondon&forecast_days=2"
        guard let data = await GlanceConfig.fetch(url) else { return }
        if apply(data, at: Date()) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    @discardableResult
    private func apply(_ data: Data, at: Date?) -> Bool {
        guard let decoded = try? JSONDecoder().decode(OpenMeteo.self, from: data) else { return false }
        now = decoded.weather
        if let at { fetchedAt = at }
        return true
    }
}

// MARK: Arsenal (ESPN public site API, no key)

struct Match: Equatable, Sendable {
    enum State: Equatable, Sendable { case upcoming, live(clock: String), finished }

    var kickoff: Date
    var opponent: String
    var home: Bool
    var neutral: Bool
    var competition: String
    var state: State
    var ourScore: String?
    var theirScore: String?

    var venue: String { neutral ? "N" : (home ? "H" : "A") }
    var fixture: String { "v \(opponent) (\(venue))" }

    var when: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = GlanceConfig.london
        f.dateFormat = Calendar.current.isDateInToday(kickoff) ? "'Today' · HH:mm" : "EEE d MMM · HH:mm"
        return f.string(from: kickoff)
    }

    /// Short form for the slim pill; the tooltip keeps the full name.
    var competitionShort: String {
        ["Premier League": "PL", "Champions League": "UCL", "Carabao Cup": "EFL Cup", "English Carabao Cup": "EFL Cup"][competition] ?? competition
    }

    /// The glance pill's two lines.
    var headline: String {
        switch state {
        case .upcoming: fixture
        case .live, .finished: "\(score ?? "ARS") \(fixture)"
        }
    }

    var detail: String {
        switch state {
        case .upcoming: "\(when) · \(competitionShort)"
        case .live: competition
        case .finished: "Full time · \(competition)"
        }
    }

    var score: String? {
        guard let ourScore, let theirScore else { return nil }
        return "\(GlanceConfig.teamShort) \(ourScore)–\(theirScore)"
    }
}

private struct ESPNSchedule: Decodable {
    struct Event: Decodable {
        let date: String
        let league: League?
        let competitions: [Competition]
    }
    struct League: Decodable { let name: String?; let shortName: String?; let abbreviation: String? }
    struct Competition: Decodable {
        let neutralSite: Bool?
        let status: Status
        let competitors: [Competitor]
    }
    struct Status: Decodable {
        struct Kind: Decodable { let name: String?; let state: String; let shortDetail: String? }
        let displayClock: String?
        let type: Kind
    }
    struct Competitor: Decodable {
        struct Team: Decodable { let id: String; let displayName: String?; let shortDisplayName: String? }
        let homeAway: String
        let team: Team
        let score: Score?
    }
    /// The schedule gives scores as objects; scoreboards give plain strings.
    struct Score: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) { text = s; return }
            struct Object: Decodable { let displayValue: String? }
            text = (try? Object(from: decoder))?.displayValue
        }
    }
    let events: [Event]?

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    var matches: [Match] {
        (events ?? []).compactMap { e -> Match? in
            guard let c = e.competitions.first, let kickoff = Self.date(e.date),
                  let us = c.competitors.first(where: { $0.team.id == GlanceConfig.teamID }),
                  let them = c.competitors.first(where: { $0.team.id != GlanceConfig.teamID }) else { return nil }
            let state: Match.State
            switch c.status.type.state {
            case "in":
                let clock = c.status.type.name == "STATUS_HALFTIME" ? "HT" : (c.status.displayClock ?? c.status.type.shortDetail ?? "")
                state = .live(clock: clock)
            case "post": state = .finished
            default: state = .upcoming
            }
            let league = e.league?.shortName ?? e.league?.abbreviation ?? e.league?.name ?? ""
            return Match(kickoff: kickoff, opponent: them.team.shortDisplayName ?? them.team.displayName ?? "TBC",
                         home: us.homeAway == "home", neutral: c.neutralSite ?? false,
                         competition: league.replacingOccurrences(of: "UEFA ", with: ""), state: state,
                         ourScore: us.score?.text, theirScore: them.score?.text)
        }
    }
}

@MainActor
@Observable
final class MatchModel {
    static let shared = MatchModel()

    var match: Match?
    var fetchedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let base = "https://site.api.espn.com/apis/site/v2/sports/soccer/all/teams/\(GlanceConfig.teamID)/schedule"

    /// From 10 min before kick-off to 3 h after, so live scores and the final result show up quickly.
    private var inMatchWindow: Bool {
        guard let match else { return false }
        if case .live = match.state { return true }
        let t = Date().timeIntervalSince(match.kickoff)
        return t > -600 && t < 3 * 3600
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            var last = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let every = self.inMatchWindow ? GlanceConfig.liveEvery : GlanceConfig.matchEvery
                if Date().timeIntervalSince(last) >= every - 1 {
                    await self.refresh()
                    last = Date()
                }
                try? await Task.sleep(for: .seconds(GlanceConfig.liveEvery))
            }
        }
    }

    func refresh() async {
        guard let data = await GlanceConfig.fetch(Self.base + "?fixture=true"),
              let fixtures = try? JSONDecoder().decode(ESPNSchedule.self, from: data) else { return }
        let upcoming = fixtures.matches.filter { $0.state != .finished }.sorted { $0.kickoff < $1.kickoff }
        var pick = upcoming.first { if case .live = $0.state { true } else { false } }
        // A match that ended in the last 3 h drops off the fixture list, so show its result for a while.
        if pick == nil, let data = await GlanceConfig.fetch(Self.base),
           let results = try? JSONDecoder().decode(ESPNSchedule.self, from: data) {
            pick = results.matches.filter { $0.state == .finished && Date().timeIntervalSince($0.kickoff) < 3 * 3600 }
                .max { $0.kickoff < $1.kickoff }
        }
        match = pick ?? upcoming.first
        fetchedAt = Date()
    }
}

// MARK: View

/// Weather, Arsenal's next match and the washer's free/busy chip, one slim row under the header.
/// Each part hides itself without data.
struct GlanceBar: View {
    let weather: WeatherModel
    let match: MatchModel
    var washer: WasherModel?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: washer?.status == nil ? 8 : 6) {
            weatherPill
            matchPill
            if let washer { WasherChip(washer: washer) }
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    @ViewBuilder private var weatherPill: some View {
        if let w = weather.now {
            HStack(spacing: 6) {
                weatherIcon(w.symbol).font(.system(size: 13))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 13, weight: .semibold))
                    Text(range(w)).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 9).frame(height: 34)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help(weatherHelp(w))
        } else {
            dash.help("Weather unavailable")
        }
    }

    @ViewBuilder private var matchPill: some View {
        if let m = match.match {
            HStack(spacing: 7) {
                Text(GlanceConfig.teamShort).font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 24, height: 18)
                    .background(Color(hex: 0xEF0107), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.headline).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(m.detail).font(.system(size: 9)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if case .live(let clock) = m.state {
                    Text(clock.isEmpty ? "LIVE" : "LIVE \(clock)").font(.system(size: 8, weight: .heavy)).tracking(0.5)
                        .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(hex: 0xEF0107), in: Capsule())
                }
            }
            .padding(.horizontal, 9).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help("Arsenal \(m.fixture) · \(m.competition) · \(m.when) (UK time)")
        } else {
            dash.frame(maxWidth: .infinity).help("Arsenal fixtures unavailable")
        }
    }

    /// Multicolour clouds are pure white, which vanishes on a white card, so the light look uses a palette.
    @ViewBuilder private func weatherIcon(_ name: String) -> some View {
        if scheme == .dark {
            Image(systemName: name).symbolRenderingMode(.multicolor)
        } else {
            Image(systemName: name).symbolRenderingMode(.palette)
                .foregroundStyle(Color(hex: 0x8C93A3), Color(hex: 0xF2A900), Color(hex: 0x3A8DDE))
        }
    }

    private var dash: some View {
        Text("–").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 12).frame(height: 34)
            .background(Theme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func range(_ w: WeatherNow) -> String {
        var parts: [String] = []
        if let h = w.high, let l = w.low { parts.append("\(Int(h.rounded()))° / \(Int(l.rounded()))°") }
        if let r = w.rainChance, r >= 10 { parts.append("☂ \(r)%") }
        return parts.joined(separator: " · ")
    }

    private func weatherHelp(_ w: WeatherNow) -> String {
        var text = "\(GlanceConfig.place): \(w.summary), \(Int(w.temp.rounded()))°C"
        if let h = w.high, let l = w.low { text += ". Today \(Int(h.rounded()))° / \(Int(l.rounded()))°" }
        if let r = w.rainChance { text += ". Rain chance next 3 h: \(r)%" }
        return text
    }
}
