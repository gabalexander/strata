import SwiftUI

// The visual language (docs/design.md). Dark only: Strata is a night-time lab bench.
// CONTRACT FILE: owned by the lead. Use these instead of literal colours and sizes.

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

public enum Theme {
    // Surfaces, back to front.
    public static let bg = Color(hex: 0x0B0D10)          // window, stage background
    public static let surface = Color(hex: 0x101317)     // sidebar, panels
    public static let raised = Color(hex: 0x161A1F)      // cards, nodes, inputs
    public static let overlay = Color(hex: 0x1B2027)     // menus, popovers, palette
    public static let hover = Color.white.opacity(0.05)
    public static let selected = Color.white.opacity(0.08)
    public static let border = Color.white.opacity(0.07)
    public static let borderStrong = Color.white.opacity(0.14)
    public static let grid = Color.white.opacity(0.035)  // stage dot grid

    // Text.
    public static let text = Color(hex: 0xE6E8EB)
    public static let muted = Color(hex: 0x8C939D)
    public static let faint = Color(hex: 0x5B626C)

    // Meaning.
    public static let accent = Color(hex: 0xF5A524)      // selection, focus, the one thing to look at
    public static let good = Color(hex: 0x3DD68C)
    public static let bad = Color(hex: 0xF2555A)
    public static let warn = Color(hex: 0xE9B44C)
    public static let info = Color(hex: 0x5AB0F7)

    /// Flow / token colours, 1...6 (wraps).
    public static func token(_ i: Int) -> Color {
        let p: [UInt32] = [0x5AB0F7, 0xA78BFA, 0x34D3B4, 0xF472B6, 0xFBBF24, 0xA3E635]
        return Color(hex: p[((max(i, 1) - 1) % p.count)])
    }

    // Type. SF Pro for UI, SF Mono for numbers, ids and code.
    public static func ui(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    public static func mono(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    public static let title = Font.system(size: 22, weight: .semibold)
    public static let heading = Font.system(size: 15, weight: .semibold)
    public static let label = Font.system(size: 11, weight: .medium)     // section labels, uppercase-free
    public static let small = Font.system(size: 11)

    // Shape.
    public static let radius: CGFloat = 10        // cards, nodes, panels
    public static let radiusSmall: CGFloat = 6    // buttons, chips, inputs
    public static let sidebarWidth: CGFloat = 248
    public static let inspectorWidth: CGFloat = 320

    // Motion: UI chrome animates quickly; the simulation has its own clock.
    public static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    public static let gentle = Animation.easeInOut(duration: 0.45)
}

/// A panel/card background: raised fill, hairline border.
public struct CardStyle: ViewModifier {
    var fill: Color = Theme.raised
    var radius: CGFloat = Theme.radius
    public func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border))
    }
}

public extension View {
    func card(_ fill: Color = Theme.raised, radius: CGFloat = Theme.radius) -> some View { modifier(CardStyle(fill: fill, radius: radius)) }
}
