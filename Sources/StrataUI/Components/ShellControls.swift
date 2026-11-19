import AppKit
import SwiftUI

@MainActor
public struct StrataIconButton: View {
    private let symbol: String
    private let title: String
    private let shortcut: String?
    private let active: Bool
    private let action: () -> Void
    @State private var hovered = false

    public init(_ symbol: String, title: String, shortcut: String? = nil, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.shortcut = shortcut
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.ui(13, .medium))
                .foregroundStyle(active ? Theme.accent : hovered ? Theme.text : Theme.muted)
                .frame(width: 28, height: 28)
                .background(active ? Theme.accent.opacity(0.10) : hovered ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { hovered = $0 }
        .strataHint(title, shortcut: shortcut)
    }
}

@MainActor
public struct StrataChip: View {
    private let title: String
    private let symbol: String?
    private let tint: Color

    public init(_ title: String, symbol: String? = nil, tint: Color = Theme.muted) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(title).lineLimit(1)
        }
        .font(Theme.label)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
    }
}

@MainActor
public struct StrataSegmentedControl<Option: Hashable>: View {
    private let options: [Option]
    @Binding private var selection: Option
    private let title: (Option) -> String

    public init(_ options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String) {
        self.options = options
        self._selection = selection
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(Theme.label)
                        .foregroundStyle(selected ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(selected ? Theme.selected : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.radiusSmall - 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .card(Theme.raised, radius: Theme.radiusSmall)
    }
}

@MainActor
public struct StrataSparkline: View {
    private let samples: [Double]
    private let color: Color

    public init(_ samples: [Double], color: Color = Theme.accent) {
        self.samples = samples
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let values = samples.filter(\.isFinite)
            guard let low = values.min(), let high = values.max(), values.count > 1 else { return }
            let span = high - low
            let line = Path { path in
                for (index, value) in values.enumerated() {
                    let ratio = span > 0 ? (value - low) / span : 0.5
                    let point = CGPoint(x: 1 + (size.width - 2) * Double(index) / Double(values.count - 1),
                                        y: 2 + (size.height - 4) * (1 - ratio))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(minWidth: 32, idealWidth: 64, minHeight: 16, idealHeight: 20)
        .accessibilityHidden(true)
    }
}

@MainActor
public struct StrataSectionLabel: View {
    private let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(Theme.ui(11, .semibold))
            .foregroundStyle(Theme.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
public struct StrataKeycap: View {
    private let key: String

    public init(_ key: String) { self.key = key }

    public var body: some View {
        Text(key)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .card(Theme.raised, radius: Theme.radiusSmall - 2)
            .fixedSize()
    }
}

public extension View {
    /// Selectable text opens the system's context menu on right-click, a separate window that screen
    /// sharing would see. This claims the right-click and offers an in-window Copy instead.
    func strataCopyMenu(_ title: String, text: String, overlays: Overlays) -> some View {
        strataMenu(overlays) {
            [MenuItem(title, icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                overlays.toast("Copied")
            }]
        }
    }
}
