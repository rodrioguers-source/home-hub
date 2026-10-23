import SwiftUI
import AppKit
import Observation
import Darwin

enum PS5Config {
    static let host = "192.168.0.45"
    static let name = "PS5-011"
    static let backgroundPoll: Double = 30
    static let visiblePoll: Double = 5
    static let psnTTL: Double = 60
}

enum PS5Status: Sendable { case on, rest, off }

enum PS5Probe {
    /// Device discovery on UDP 9302: "200 Ok" means on, "620" rest mode, silence off or unreachable. No auth needed.
    static func status(timeout: Int32 = 1500) async -> PS5Status {
        await Task.detached { probe(timeout: timeout) }.value
    }

    private static func probe(timeout: Int32) -> PS5Status {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .off }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9302).bigEndian
        inet_pton(AF_INET, PS5Config.host, &addr.sin_addr)
        let message = Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n".utf8)
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return .off }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeout) > 0 else { return .off }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return .off }
        let firstLine = String(decoding: buffer[0..<n], as: UTF8.self).split(separator: "\n").first ?? ""
        if firstLine.contains(" 200") { return .on }
        if firstLine.contains(" 620") { return .rest }
        return .off
    }
}

struct PSNPresence: Decodable, Sendable {
    let availability: String?
    let onlineStatus: String?
    let platform: String?
    let title: String?
    let titleId: String?
    let icon: String?
}

struct PSNTitle: Decodable, Sendable, Identifiable {
    let titleId: String?
    let name: String?
    let image: String?
    let seconds: Int
    let plays: Int?
    let platform: String?
    var id: String { titleId ?? name ?? UUID().uuidString }
}

enum PS5PowerOutcome: Sendable {
    case done(String)
    case failed(String, code: String?)
}

struct PSNSummary: Decodable, Sendable {
    let configured: Bool
    let state: String
    let error: String?
    var onlineId: String?
    var presence: PSNPresence?
    var mostPlayed: [PSNTitle]?
}

@MainActor
@Observable
final class PS5Model {
    var status: PS5Status = .off
    var hasPolled = false
    var psn: PSNSummary?
    var psnLoading = false
    var psnFetchedAt: Date?
    var psnHelperError: String?
    var powerBusy = false
    var powerError: String?

    var panelVisible = false { didSet { activityChanged() } }
    var tabActive = false { didSet { activityChanged() } }
    var animating: Bool { panelVisible && tabActive }

    @ObservationIgnored private let helper: HomeHelper
    @ObservationIgnored private let usage: UsageStore?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastProbe = Date.distantPast

    init(helper: HomeHelper, usage: UsageStore?, live: Bool = true) {
        self.helper = helper
        self.usage = usage
        guard live else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.animating ? PS5Config.visiblePoll : PS5Config.backgroundPoll
                if Date().timeIntervalSince(self.lastProbe) >= interval - 0.5 { await self.probe() }
                try? await Task.sleep(for: .seconds(PS5Config.visiblePoll))
            }
        }
    }

    func probe() async {
        lastProbe = Date()
        status = await PS5Probe.status()
        hasPolled = true
        usage?.samplePS5(on: status == .on)
    }

    private func activityChanged() {
        guard animating else { return }
        Task {
            await probe()
            await refreshPSN()
        }
    }

    var refreshing = false

    func refreshNow() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            async let minimumSpin: Void? = try? Task.sleep(for: .milliseconds(500))
            async let status: Void = probe()
            await refreshPSN(force: true)
            _ = await (minimumSpin, status)
            refreshing = false
        }
    }

    /// Wake or rest mode through the helper (Remote Play), then re-probe until the console agrees.
    @discardableResult
    func setPower(on: Bool) async -> PS5PowerOutcome {
        guard !powerBusy else { return .failed("Already changing power.", code: nil) }
        powerBusy = true
        powerError = nil
        defer { powerBusy = false }
        helper.restartIfStopped()
        do {
            _ = try await helper.call(on ? "ps5.wake" : "ps5.standby", on ? ["wait": false] : [:], timeout: 150)
        } catch {
            var code: String?
            var message = error.localizedDescription
            if case HomeHelper.Failure.remote(let text, let c) = error { code = c; message = Self.powerMessage(c) ?? text }
            powerError = message
            await probe()
            return .failed(message, code: code)
        }
        let want: PS5Status = on ? .on : .rest
        let start = Date()
        while Date().timeIntervalSince(start) < 40 {
            await probe()
            if status == want {
                return .done(on ? "On after \(Int(Date().timeIntervalSince(start).rounded())) s" : "In rest mode")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        let message = on ? "Wake sent, but it hasn't come on yet." : "Rest mode sent, but it still reports on."
        powerError = message
        return .failed(message, code: nil)
    }

    var playingCaption: String {
        let presence = psn?.presence
        var parts: [String] = []
        if let platform = presence?.platform, presence?.onlineStatus == "online" { parts.append("On \(platform)") }
        if let at = psnFetchedAt {
            let minutes = Int(Date().timeIntervalSince(at) / 60)
            parts.append(minutes < 1 ? "Updated just now" : "Updated \(minutes) min ago")
        }
        return parts.isEmpty ? "From your PSN presence" : parts.joined(separator: " · ")
    }

    static func hours(_ seconds: Int) -> String {
        let h = Double(seconds) / 3600
        return h >= 10 ? "\(Int(h.rounded())) h" : (h >= 1 ? String(format: "%.1f h", h) : "\(seconds / 60) min")
    }

    static func powerMessage(_ code: String?) -> String? {
        switch code {
        case "not_paired": "Not paired yet. Run ps5_pair.py."
        case "op_unavailable": "1Password CLI isn't available."
        case "op_failed": "Couldn't read the PS5 pairing from 1Password."
        case "bad_creds": "The pairing in 1Password looks broken. Pair again with ps5_pair.py."
        case "unreachable": "The PS5 isn't answering on the network."
        case "network": "Network error talking to the PS5."
        case "wake_timeout": "Wake sent, but it's still in rest mode."
        case "session_failed": "The Remote Play session failed."
        case "session_timeout": "The Remote Play session timed out."
        case "standby_failed": "Couldn't put the PS5 into rest mode."
        case "standby_timeout": "Rest mode sent, but it still reports on. A game may be blocking it."
        default: nil
        }
    }

    func refreshPSN(force: Bool = false) async {
        if !force, let at = psnFetchedAt, Date().timeIntervalSince(at) < PS5Config.psnTTL { return }
        guard !psnLoading else { return }
        psnLoading = true
        defer { psnLoading = false }
        if force { helper.restartIfStopped() }
        do {
            let summary = try await helper.call("psn.summary", ["force": force], timeout: 150, as: PSNSummary.self)
            psn = summary
            psnHelperError = nil
            psnFetchedAt = summary.state == "ready" ? Date() : nil
        } catch {
            psnHelperError = error.localizedDescription
        }
    }
}

// MARK: Look

enum PSTheme {
    static let deep = Color(light: Color(hex: 0xE8F0FF), dark: Color(hex: 0x00072D))
    static let mid = Color(light: Color(hex: 0xC6D8FF), dark: Color(hex: 0x0B1F6B))
    static let blue = Color(hex: 0x0070D1)
    // Neon cyan is unreadable on the pale backdrop, so the light look uses a darkened PlayStation blue.
    static let cyan = Color(light: Color(hex: 0x005BB5), dark: Color(hex: 0x3FE0FF))
    static let amber = Color(light: Color(hex: 0xB86A00), dark: Color(hex: 0xFFB020))
    static let glass = Color(light: Color(hex: 0x0070D1, opacity: 0.08), dark: .white.opacity(0.06))
    static let edge = Color(light: Color(hex: 0x0070D1, opacity: 0.22), dark: Color(hex: 0x3FE0FF, opacity: 0.18))
    static let cardFill = Color(light: .white.opacity(0.78), dark: Color(hex: 0x00072D, opacity: 0.55))
    static let muted = Color(light: Color(hex: 0x15161A, opacity: 0.55), dark: .white.opacity(0.45))
    static let artIcon = Color(light: Color(hex: 0x0070D1, opacity: 0.6), dark: .white.opacity(0.5))
}

/// Synthwave floor plus drifting △ ○ ✕ □. Paused (one static frame) when the panel is closed.
struct PS5Backdrop: View {
    let animating: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [PSTheme.deep, PSTheme.mid, PSTheme.deep], startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    drawGrid(&ctx, size: size, t: t)
                    drawSymbols(&ctx, size: size, t: t)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let horizon = size.height * 0.58
        let vanish = CGPoint(x: size.width / 2, y: horizon)
        let floorHeight = size.height - horizon
        var glow = Path()
        glow.addRect(CGRect(x: 0, y: horizon - 1, width: size.width, height: 2))
        ctx.fill(glow, with: .color(PSTheme.cyan.opacity(0.35)))

        var lines = Path()
        for i in -12...12 {
            let xBottom = size.width / 2 + CGFloat(i) * size.width / 7
            lines.move(to: vanish)
            lines.addLine(to: CGPoint(x: xBottom, y: size.height))
        }
        let phase = (t * 0.12).truncatingRemainder(dividingBy: 1)
        for i in 0..<14 {
            let z = (Double(i) + phase) / 14
            let y = horizon + floorHeight * CGFloat(z * z)
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        var clip = ctx
        clip.clip(to: Path(CGRect(x: 0, y: horizon, width: size.width, height: floorHeight)))
        clip.stroke(lines, with: .linearGradient(Gradient(colors: [PSTheme.cyan.opacity(0.03), PSTheme.cyan.opacity(0.22)]),
                                                  startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)),
                    lineWidth: 0.8)
    }

    private func drawSymbols(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let palette: [Color] = [Color(hex: 0x40E0B0), Color(hex: 0xFF5A7A), Color(hex: 0x6AA8FF), Color(hex: 0xE58AFF)]
        for i in 0..<10 {
            let seed = Double(i) * 1.618
            let speed = 0.008 + 0.004 * Double(i % 3)
            let yFrac = 1 - ((seed * 0.37 + t * speed).truncatingRemainder(dividingBy: 1.15))
            let x = size.width * CGFloat((seed * 0.53).truncatingRemainder(dividingBy: 1)) + CGFloat(sin(t * 0.2 + seed) * 14)
            let y = size.height * CGFloat(yFrac)
            let s = CGFloat(10 + (i % 4) * 4)
            let path = symbol(i % 4, at: CGPoint(x: x, y: y), size: s)
            let colour = palette[i % 4]
            var glow = ctx
            glow.addFilter(.blur(radius: 4))
            glow.stroke(path, with: .color(colour.opacity(0.35)), lineWidth: 2.5)
            ctx.stroke(path, with: .color(colour.opacity(0.22)), lineWidth: 1.2)
        }
    }

    private func symbol(_ kind: Int, at c: CGPoint, size s: CGFloat) -> Path {
        var p = Path()
        switch kind {
        case 0:
            p.move(to: CGPoint(x: c.x, y: c.y - s / 2))
            p.addLine(to: CGPoint(x: c.x + s / 2, y: c.y + s / 2.4))
            p.addLine(to: CGPoint(x: c.x - s / 2, y: c.y + s / 2.4))
            p.closeSubpath()
        case 1:
            p.addEllipse(in: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
        case 2:
            p.move(to: CGPoint(x: c.x - s / 2, y: c.y - s / 2)); p.addLine(to: CGPoint(x: c.x + s / 2, y: c.y + s / 2))
            p.move(to: CGPoint(x: c.x + s / 2, y: c.y - s / 2)); p.addLine(to: CGPoint(x: c.x - s / 2, y: c.y + s / 2))
        default:
            p.addRect(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
        }
        return p
    }
}

struct NeonCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PSTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(.ultraThinMaterial.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PSTheme.edge))
    }
}

struct NeonPill: View {
    let status: PS5Status
    let polled: Bool

    private var look: (String, Color) {
        guard polled else { return ("SEARCHING", Theme.secondary) }
        switch status {
        case .on: return ("ONLINE", PSTheme.cyan)
        case .rest: return ("REST MODE", PSTheme.amber)
        case .off: return ("OFFLINE", PSTheme.muted)
        }
    }

    var body: some View {
        let (text, colour) = look
        let lit = polled && status != .off
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 6, height: 6).shadow(color: lit ? colour : .clear, radius: 4)
            Text(text).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(2)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(colour.opacity(lit ? 0.12 : 0.06), in: Capsule())
        .overlay(Capsule().stroke(colour.opacity(lit ? 0.8 : 0.3), lineWidth: 1))
        .shadow(color: lit ? colour.opacity(0.55) : .clear, radius: 8)
    }
}

// MARK: Tab

struct PS5Tab: View {
    let ps5: PS5Model
    let tv: TVModel

    var body: some View {
        VStack(spacing: 12) {
            header
            switchCard
            psnSection
            powerCard
            Text("Status is read from the console on the local network every \(Int(PS5Config.visiblePoll)) s while this tab is open (every \(Int(PS5Config.backgroundPoll)) s otherwise). PSN data refreshes at most every minute, or press ↻.")
                .font(.system(size: 10)).foregroundStyle(PSTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PlayStation 5").font(.system(size: 20, weight: .heavy, design: .rounded))
                    .shadow(color: PSTheme.cyan.opacity(0.35), radius: 6)
                Text("\(PS5Config.name) · \(PS5Config.host)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(PSTheme.muted)
            }
            Spacer()
            NeonPill(status: ps5.status, polled: ps5.hasPolled)
        }
        .padding(.top, 4)
    }

    private var powerCard: some View {
        let on = ps5.status == .on
        let reachable = ps5.hasPolled && ps5.status != .off
        return NeonCard {
            HStack(spacing: 10) {
                Image(systemName: "power").font(.system(size: 13)).frame(width: 30, height: 30)
                    .background(PSTheme.glass, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Power").font(.system(size: 13, weight: .semibold))
                    Text(ps5.powerBusy ? (on ? "Going to rest mode…" : "Waking…")
                         : reachable ? (on ? "On" : "In rest mode")
                         : "Not answering on the network")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button { Task { await ps5.setPower(on: !on) } } label: {
                    HStack(spacing: 6) {
                        if ps5.powerBusy { ProgressView().controlSize(.mini) }
                        Text(on ? "Rest mode" : "Turn on").font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(PressableStyle(background: on ? PSTheme.glass : PSTheme.blue, foreground: on ? Theme.primary : .white))
                .disabled(!reachable || ps5.powerBusy)
                .opacity(reachable ? 1 : 0.5)
                .help(on ? "Put the PS5 into rest mode (Remote Play)" : "Wake the PS5 from rest mode (Remote Play)")
            }
            if let error = ps5.powerError {
                Text(error).font(.system(size: 10)).foregroundStyle(PSTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var switchCard: some View {
        Button {
            let st = tv.smartThings
            if st.usable {
                Task { if await st.setInput(SceneConfig.ps5Input) != nil { tv.key("KEY_HDMI") } }
            } else {
                tv.key("KEY_HDMI")
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "tv.and.mediabox").font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Switch TV to PS5").font(.system(size: 13, weight: .bold))
                    Text(tv.power != .on ? "The TV needs to be on"
                         : tv.smartThings.usable ? "Sets the \(TVConfig.room) TV to \(SceneConfig.ps5InputName)"
                         : "Sends HDMI to the \(TVConfig.room) TV")
                        .font(.system(size: 10)).opacity(0.75)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 48)
            .background(LinearGradient(colors: [PSTheme.blue, Color(hex: 0x2A5BFF)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PSTheme.cyan.opacity(0.35)))
            .shadow(color: PSTheme.blue.opacity(tv.power == .on ? 0.6 : 0), radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tv.power != .on)
        .opacity(tv.power == .on ? 1 : 0.5)
        .help(tv.smartThings.usable ? "Switches input through SmartThings" : "HDMI cycles the TV inputs; press again if it lands on the wrong one")
    }

    @ViewBuilder private var psnSection: some View {
        if let summary = ps5.psn, !summary.configured {
            connectCard(error: nil)
        } else if let summary = ps5.psn, summary.state != "ready" && summary.mostPlayed == nil {
            connectCard(error: summary.error ?? "PSN isn't available right now.")
        } else if let summary = ps5.psn {
            nowPlaying(summary)
            mostPlayed(summary)
        } else if let error = ps5.psnHelperError {
            connectCard(error: error)
        } else {
            NeonCard {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to PSN…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private func connectCard(error: String?) -> some View {
        NeonCard {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(PSTheme.cyan)
                Text(error == nil ? "Connect PSN" : "PSN not connected").font(.system(size: 14, weight: .bold))
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(PSTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("To show what you're playing and your most played games:")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 5) {
                step(1, "Sign in at playstation.com in your browser.")
                step(2, "Open ca.account.sony.com/api/v1/ssocookie and copy the npsso value.")
                step(3, "In 1Password, create an API Credential item called \"PSN NPSSO\" and paste it into the credential field.")
                step(4, "Come back here and press Retry.")
            }
            HStack {
                Button {
                    Task { await ps5.refreshPSN(force: true) }
                } label: {
                    Text(ps5.psnLoading ? "Checking…" : "Retry").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .buttonStyle(PressableStyle(background: PSTheme.blue, foreground: .white))
                .disabled(ps5.psnLoading)
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: "https://ca.account.sony.com/api/v1/ssocookie")!)
                } label: {
                    Label("Open the npsso page", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(PSTheme.cyan)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(PSTheme.cyan)
                .frame(width: 16, height: 16).overlay(Circle().stroke(PSTheme.cyan.opacity(0.5)))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nowPlaying(_ summary: PSNSummary) -> some View {
        let presence = summary.presence
        let playing = presence?.title
        let online = presence?.onlineStatus == "online"
        return NeonCard {
            HStack {
                Text("NOW PLAYING").font(.system(size: 11, weight: .bold)).tracking(1.6).foregroundStyle(PSTheme.cyan)
                Spacer()
                if let id = summary.onlineId {
                    Text(id).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(PSTheme.muted)
                }
                Button { ps5.refreshNow() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PSTheme.cyan.opacity(0.8))
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: ps5.refreshing)
                }
                .buttonStyle(.plain)
                .help("Refresh PS5 status and what you're playing")
            }
            HStack(spacing: 12) {
                GameArt(url: presence?.icon, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playing ?? (online ? "Online, not in a game" : "Not playing"))
                        .font(.system(size: 15, weight: .bold)).lineLimit(2)
                    Text(ps5.playingCaption)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            if let error = summary.error {
                Text(error).font(.system(size: 10)).foregroundStyle(PSTheme.amber)
            }
        }
    }

    private func mostPlayed(_ summary: PSNSummary) -> some View {
        let titles = summary.mostPlayed ?? []
        let top = Double(titles.first?.seconds ?? 1)
        return NeonCard {
            Text("MOST PLAYED").font(.system(size: 11, weight: .bold)).tracking(1.6).foregroundStyle(PSTheme.cyan)
            if titles.isEmpty {
                Text("No play time on record yet.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            ForEach(Array(titles.enumerated()), id: \.offset) { rank, title in
                HStack(spacing: 10) {
                    GameArt(url: title.image, size: 36)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(title.name ?? "Unknown title").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(PS5Model.hours(title.seconds)).font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(PSTheme.cyan)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PSTheme.glass)
                                Capsule()
                                    .fill(LinearGradient(colors: [PSTheme.blue, PSTheme.cyan], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, geo.size.width * Double(title.seconds) / max(top, 1)))
                                    .shadow(color: PSTheme.cyan.opacity(rank == 0 ? 0.8 : 0.45), radius: 5)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}

struct GameArt: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [PSTheme.mid, PSTheme.blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.36)).foregroundStyle(PSTheme.artIcon)
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(PSTheme.edge))
    }
}
