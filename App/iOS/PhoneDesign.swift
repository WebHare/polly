import PollyKit
import SwiftUI

// The iPhone screens of the Polly design: the colors they add to `PollyTheme` and the pieces they share.
// Values are taken literally from the design export ("Polly App" → iPhone, "Polly Design System").

extension PollyTheme {
    var screen: Color { dark ? Color(hex: 0x0E1628) : Color(hex: 0xF2F0EB) }
    var surface: Color { dark ? Color(hex: 0x1B2336) : .white }
    var surfaceDivider: Color { dark ? Color.white.opacity(0.07) : Color(hex: 0xECE8DF) }
    /// Second line of a problem row, e.g. the service name.
    var secondary: Color { dark ? Color(hex: 0xC9D2E6) : Color(hex: 0x3A4766) }
    /// Glyphs on the action tiles.
    var tileGlyph: Color { dark ? Color(hex: 0x7FB1FF) : Color(hex: 0x2563C9) }
    var tabSelected: Color { .pollyBlue }
    var tagBorder: Color { dark ? Color.white.opacity(0.18) : Color.pollyNavy.opacity(0.18) }
    var chipActive: Color { dark ? Color(hex: 0xEEF2FA) : .pollyNavy }
    var chipActiveText: Color { dark ? .pollyNavy : .white }

    /// The color of Polly's line above the summary, matching its mood.
    func moodText(_ mood: MonitorSummary.Mood) -> Color {
        switch mood {
        case .critical: severityText(.critical)
        case .warning: severityText(.warning)
        case .unreachable: severityText(.unknown)
        case .ok: severityText(.ok)
        }
    }
}

private struct PhoneThemed: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = PollyTheme(dark: colorScheme == .dark)
        content
            .environment(\.pollyTheme, theme)
            .foregroundStyle(theme.text)
            .tint(.pollyAccent)
    }
}

extension View {
    /// The iPhone counterpart of `pollyThemed()`: the theme for the current color scheme, without the 13 pt
    /// macOS text size.
    func phoneThemed() -> some View { modifier(PhoneThemed()) }

    /// A list or form on the paper (light) or night (dark) background of the design, with surface-colored rows.
    func phoneListBackground(_ theme: PollyTheme) -> some View {
        scrollContentBackground(.hidden).background(theme.screen)
    }
}

/// Outlined uppercase tag for a state that is not a severity: ACK, DOWNTIME, SOFT 2/3.
struct StateTag: View {
    let text: String
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.55)
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.tagBorder, lineWidth: 1))
    }
}

/// The solid status pill of the problem detail: "⨯ CRITICAL".
struct StatusPill: View {
    let severity: Severity

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(severity: severity, size: 15, dark: true)
            Text(severity.label.uppercased())
        }
        .font(.system(size: 12, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(severity == .warning ? Color.pollyNavy : .white)
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 11))
        .background(severity.pillColor, in: Capsule())
    }
}

extension Date {
    /// "09:18" today, with the date in front for anything older.
    var pollyClock: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(date: .abbreviated, time: .shortened)
    }
}
