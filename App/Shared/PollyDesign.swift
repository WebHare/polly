import PollyKit
import SwiftUI

// The building blocks of the Polly design: colors per color scheme, the status icons, the mascot and the
// controls. Values are taken literally from the design export; change them there first.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static let pollyAccent = Color(hex: 0x2B6FE6)
    static let pollyNavy = Color(hex: 0x14213D)
    static let pollyBlue = Color(hex: 0x3D8BFF)
}

struct PollyTheme {
    var dark = false

    private func pick(_ dark: Color, _ light: Color) -> Color { self.dark ? dark : light }
    private func ink(_ darkOpacity: Double, _ lightOpacity: Double) -> Color {
        dark ? Color.white.opacity(darkOpacity) : Color.pollyNavy.opacity(lightOpacity)
    }

    // Popover and detail
    var panel: Color { pick(Color(hex: 0x1B2336), Color(hex: 0xF7F6F3)) }
    var text: Color { pick(Color(hex: 0xEEF2FA), .pollyNavy) }
    var muted: Color { pick(Color(hex: 0xA3AECA), Color(hex: 0x55617D)) }
    var faint: Color { pick(Color(hex: 0x7683A3), Color(hex: 0x7D869B)) }
    var border: Color { ink(0.12, 0.14) }
    var divider: Color { ink(0.08, 0.09) }
    var button: Color { ink(0.10, 0.07) }
    var footer: Color { pick(Color.black.opacity(0.14), Color.pollyNavy.opacity(0.03)) }
    var selection: Color { Color.pollyBlue.opacity(dark ? 0.22 : 0.16) }
    var link: Color { pick(Color(hex: 0x7FB1FF), Color(hex: 0x2563C9)) }
    var chipSelected: Color { pick(.pollyBlue, .pollyAccent) }
    var chipSelectedText: Color { pick(.pollyNavy, .white) }

    // Settings window
    var window: Color { pick(Color(hex: 0x161E30), .white) }
    var sidebar: Color { pick(Color(hex: 0x111827), Color(hex: 0xEFEDE8)) }
    var sidebarSelection: Color { pick(Color.pollyBlue.opacity(0.25), Color.pollyNavy.opacity(0.09)) }
    var card: Color { pick(Color(hex: 0x1B2336), Color(hex: 0xFAF9F6)) }
    var cardBorder: Color { pick(.clear, Color(hex: 0xE4DFD3)) }
    var rowDivider: Color { pick(Color.white.opacity(0.07), Color(hex: 0xE4DFD3)) }
    var field: Color { pick(Color.black.opacity(0.22), .white) }
    var fieldBorder: Color { pick(Color.white.opacity(0.12), Color(hex: 0xDAD5C9)) }
    var toggleOff: Color { ink(0.18, 0.18) }
    var successBackground: Color { pick(Color(hex: 0x3DD68C, opacity: 0.15), Color(hex: 0xE1F4EA)) }
    var failureBackground: Color { pick(Color(hex: 0xFF5C63, opacity: 0.15), Color(hex: 0xFBE4E5)) }

    /// Severity as text (group headers, banners): darker on light, lighter on dark, for contrast.
    func severityText(_ severity: Severity) -> Color {
        switch severity {
        case .critical: pick(Color(hex: 0xFF7A7F), Color(hex: 0xC4262E))
        case .warning: pick(Color(hex: 0xFFC53D), Color(hex: 0x8F5B00))
        case .unknown: pick(Color(hex: 0xB9AEFF), Color(hex: 0x5B4BC4))
        case .ok: pick(Color(hex: 0x3DD68C), Color(hex: 0x13774A))
        }
    }
}

private struct PollyThemeKey: EnvironmentKey {
    static let defaultValue = PollyTheme()
}

extension EnvironmentValues {
    var pollyTheme: PollyTheme {
        get { self[PollyThemeKey.self] }
        set { self[PollyThemeKey.self] = newValue }
    }
}

private struct PollyThemed: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = PollyTheme(dark: colorScheme == .dark)
        content
            .environment(\.pollyTheme, theme)
            .foregroundStyle(theme.text)
            .font(.system(size: 13))
    }
}

extension View {
    /// Puts the theme for the current color scheme in the environment; apply once at the root of a window.
    func pollyThemed() -> some View { modifier(PollyThemed()) }
}

// MARK: - Shapes

extension Path {
    /// Builds a path from the subset of SVG path data the design uses: absolute M, L, H, V, Q and Z.
    init(svg: String) {
        self.init()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var current = CGPoint.zero
        func flush(_ path: inout Path) {
            switch command {
            case "M": current = CGPoint(x: numbers[0], y: numbers[1]); path.move(to: current)
            case "L": current = CGPoint(x: numbers[0], y: numbers[1]); path.addLine(to: current)
            case "H": current.x = numbers[0]; path.addLine(to: current)
            case "V": current.y = numbers[0]; path.addLine(to: current)
            case "Q":
                current = CGPoint(x: numbers[2], y: numbers[3])
                path.addQuadCurve(to: current, control: CGPoint(x: numbers[0], y: numbers[1]))
            case "Z": path.closeSubpath()
            default: assertionFailure("Unsupported SVG path command \"\(command)\"")
            }
            numbers = []
        }
        let arity: [Character: Int] = ["M": 2, "L": 2, "H": 1, "V": 1, "Q": 4, "Z": 0]
        for token in svg.split(separator: " ") {
            var text = Substring(token)
            if let first = text.first, first.isLetter {
                command = first
                text = text.dropFirst()
                if command == "Z" { flush(&self) }
            }
            guard let value = Double(text) else { continue }
            numbers.append(value)
            if numbers.count == arity[command] { flush(&self) }
        }
    }
}

/// The status icon of the design: every status has its own shape, so it never depends on color alone.
struct StatusIcon: View {
    let severity: Severity
    var size: CGFloat = 16
    /// The design uses the dark-scheme colors on colored and dark surfaces; nil follows the theme.
    var dark: Bool?
    @Environment(\.pollyTheme) private var theme

    var body: some View {
        let onDark = dark ?? theme.dark
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 20, y: canvasSize.height / 20)
            Self.draw(severity, dark: onDark, in: &context)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(severity.label)
    }

    private static func draw(_ severity: Severity, dark: Bool, in context: inout GraphicsContext) {
        let round = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        switch severity {
        case .ok:
            let (fill, glyph) = dark ? (Color(hex: 0x3DD68C), Color(hex: 0x0B2418)) : (Color(hex: 0x1E9E63), .white)
            context.fill(Path(ellipseIn: CGRect(x: 1.4, y: 1.4, width: 17.2, height: 17.2)), with: .color(fill))
            context.stroke(Path(svg: "M6.1 10.3 L8.7 12.9 L13.9 7.4"), with: .color(glyph),
                           style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
        case .warning:
            let fill = dark ? Color(hex: 0xFFC53D) : Color(hex: 0xF2B21B)
            let triangle = Path(svg: "M10 2.6 L18 16.6 H2 Z")
            context.fill(triangle, with: .color(fill))
            context.stroke(triangle, with: .color(fill), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
            context.stroke(Path(svg: "M10 7.6 V11.4"), with: .color(.pollyNavy), style: round)
            context.fill(Path(ellipseIn: CGRect(x: 8.75, y: 12.95, width: 2.5, height: 2.5)), with: .color(.pollyNavy))
        case .critical:
            let fill = dark ? Color(hex: 0xFF5C63) : Color(hex: 0xDC3B42)
            let octagon = Path(svg: "M6.6 1.6 H13.4 L18.4 6.6 V13.4 L13.4 18.4 H6.6 L1.6 13.4 V6.6 Z")
            context.fill(octagon, with: .color(fill))
            context.stroke(octagon, with: .color(fill), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            context.stroke(Path(svg: "M7.2 7.2 L12.8 12.8 M12.8 7.2 L7.2 12.8"), with: .color(.white), style: round)
        case .unknown:
            let (fill, glyph) = dark ? (Color(hex: 0xA99BFF), Color(hex: 0x1A1640)) : (Color(hex: 0x7C6CF0), .white)
            context.fill(Path(roundedRect: CGRect(x: 1.8, y: 1.8, width: 16.4, height: 16.4), cornerRadius: 4.5),
                         with: .color(fill))
            context.stroke(Path(svg: "M7.6 7.8 Q7.6 5.4 10 5.4 Q12.4 5.4 12.4 7.6 Q12.4 9.2 10.6 9.9 Q10 10.2 10 11.4"),
                           with: .color(glyph), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 8.8, y: 13.1, width: 2.4, height: 2.4)), with: .color(glyph))
        }
    }
}

/// Polly on its tile. The drawings are the SVGs of the design, in the asset catalog.
struct PollyMascot: View {
    let mood: MonitorSummary.Mood
    var size: CGFloat = 44

    var body: some View {
        let scale = size / 248
        let radius = (size * 0.225).rounded()
        Image(assetName)
            .resizable()
            .frame(width: size, height: size)
            .overlay {
                // The question mark is text in the design, which an asset catalog SVG can't carry.
                if mood == .unreachable {
                    Text("?")
                        .font(.system(size: 46 * scale, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0xB4A8FF))
                        .position(x: 203 * scale, y: 52 * scale)
                }
            }
            .background(LinearGradient(colors: tile, startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    .mask(alignment: .top) { Rectangle().frame(height: radius) }
            }
            .shadow(color: Color.pollyNavy.opacity(0.18), radius: 1, y: 1)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch mood {
        case .ok: "MascotOk"
        case .warning: "MascotWarning"
        case .critical: "MascotCritical"
        case .unreachable: "MascotUnreachable"
        }
    }

    private var tile: [Color] {
        switch mood {
        case .ok: [Color(hex: 0x22365F), Color(hex: 0x14213D)]
        case .warning: [Color(hex: 0x6B4A12), Color(hex: 0x3A2608)]
        case .critical: [Color(hex: 0x6E1D33), Color(hex: 0x38101C)]
        case .unreachable: [Color(hex: 0x3B4160), Color(hex: 0x20243A)]
        }
    }
}

// MARK: - Controls

/// Marks a part of the design that is drawn but does not work yet.
struct PlaceholderTag: View {
    var text = "PLACEHOLDER"

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Color(hex: 0xE07800))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0xFF9F1C), lineWidth: 1))
            .fixedSize()
            .help("Drawn from the design, not working yet")
    }
}

extension View {
    /// Dims a control that is only a placeholder and takes it out of reach of the pointer and keyboard.
    func placeholderControl() -> some View {
        opacity(0.5).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PollyButtonStyle: ButtonStyle {
    enum Kind { case primary, soft, outlined }
    var kind = Kind.soft
    var horizontal: CGFloat = 12
    var vertical: CGFloat = 5
    var radius: CGFloat = 7
    var expands = false
    @Environment(\.pollyTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(kind == .primary ? .semibold : .medium)
            .foregroundStyle(kind == .primary ? Color.white : theme.text)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                if kind == .outlined {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(theme.fieldBorder, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }

    private var background: Color {
        switch kind {
        case .primary: .pollyAccent
        case .soft: theme.button
        case .outlined: theme.field
        }
    }
}

/// Text-only button in the link color.
struct PollyLinkStyle: ButtonStyle {
    @Environment(\.pollyTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(theme.link)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// The 32 by 19 switch of the design. It draws only the switch; the label is for assistive technology,
/// because every row in the design lays out its own title and subtitle.
struct PollyToggleStyle: ToggleStyle {
    @Environment(\.pollyTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Color.pollyAccent : theme.toggleOff)
            .frame(width: 32, height: 19)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The 14 pt checkbox of the design.
struct PollyCheckboxStyle: ToggleStyle {
    @Environment(\.pollyTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? theme.chipSelected : Color.clear)
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(theme.chipSelectedText)
                        } else {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(theme.faint, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PollyFieldModifier: ViewModifier {
    var horizontal: CGFloat
    var vertical: CGFloat
    var radius: CGFloat
    @FocusState private var focused: Bool
    @Environment(\.pollyTheme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(theme.field, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(focused ? Color.pollyBlue : theme.fieldBorder, lineWidth: focused ? 2 : 1)
            }
    }
}

extension View {
    /// Text field in the look of the design, with the blue border while it has focus.
    func pollyField(horizontal: CGFloat = 8, vertical: CGFloat = 5, radius: CGFloat = 6) -> some View {
        modifier(PollyFieldModifier(horizontal: horizontal, vertical: vertical, radius: radius))
    }

    /// Small uppercase label above a group, e.g. "FILTERS".
    func pollySectionLabel(_ color: Color) -> some View {
        font(.system(size: 12, weight: .semibold)).tracking(0.6).textCase(.uppercase).foregroundStyle(color)
    }
}
