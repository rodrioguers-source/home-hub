import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Resolves against the view's colour scheme, so `.environment(\.colorScheme, …)` switches it.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

enum Theme {
    private static let ink = Color(hex: 0x15161A)

    static let background = Color(light: Color(hex: 0xF0F1F5), dark: Color(hex: 0x111215))
    static let card = Color(light: .white, dark: Color(hex: 0x1B1C20))
    static let raised = Color(light: Color(hex: 0xE7E9EF), dark: Color(hex: 0x26272D))
    static let stroke = Color(light: .black.opacity(0.07), dark: .white.opacity(0.06))
    static let shadow = Color(light: .black.opacity(0.05), dark: .clear)
    static let primary = Color(light: ink, dark: .white)
    // Samsung blue #1428A0 is too dark on the dark background, so it's lifted there for text and icons.
    static let accent = Color(light: Color(hex: 0x2B47D9), dark: Color(hex: 0x5B78FF))
    static let accentDeep = Color(hex: 0x1428A0)
    static let secondary = Color(light: ink.opacity(0.62), dark: .white.opacity(0.55))
    static let tertiary = Color(light: ink.opacity(0.48), dark: .white.opacity(0.35))
    static let online = Color(light: Color(hex: 0x1E9E47), dark: Color(hex: 0x34C759))
    static let standby = Color(light: Color(hex: 0xB86A00), dark: Color(hex: 0xFFB020))
    static let dimTrack = Color(light: .black.opacity(0.08), dark: .white.opacity(0.12))
    static let brightTrack = Color(light: Color(hex: 0xFFC53D), dark: .white.opacity(0.9))
    static let bezel = Color(light: Color(hex: 0x2A2C33), dark: .white.opacity(0.18))
    static let failure = Color(light: Color(hex: 0xD3302A), dark: Color(hex: 0xFF5A52))
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
            .shadow(color: Theme.shadow, radius: 6, y: 2)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CardHeader: View {
    let icon: String
    let title: String
    var trailing: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.secondary).font(.system(size: 12))
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing {
                if let trailingAction {
                    Button(trailing, action: trailingAction).buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                } else {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

struct PressableStyle: ButtonStyle {
    var background: Color = Theme.raised
    var foreground: Color = Theme.primary
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Rectangle())
    }
}

struct IconButton: View {
    let systemName: String
    var size: CGFloat = 40
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// Fires once on press, then repeats while held. Used for volume steps.
struct RepeatButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var timer: Timer?
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 44, height: 36)
            .background(Theme.raised.opacity(pressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .help(help)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { _ in
                                    MainActor.assumeIsolated { action() }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
    }
}

struct AppTile: View {
    let app: TVApp
    var size: CGFloat = 50
    var label: String?
    var running = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(hex: app.color))
                Text(app.short)
                    .font(.system(size: app.short.count > 3 ? size * 0.24 : size * 0.36, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if running {
                    Circle().fill(Theme.online).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                        .offset(x: 3, y: -3)
                }
            }
            if let label {
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    let minutes = s / 60
    if minutes < 60 { return "\(minutes) min" }
    return String(format: "%d h %02d min", minutes / 60, minutes % 60)
}
