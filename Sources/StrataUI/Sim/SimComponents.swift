import SwiftUI
import StrataCore

enum SimFormat {
    private static let number0 = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
    private static let number1 = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
    private static let number2 = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))

    static func number(_ value: Double) -> String { value.formatted(value.magnitude >= 100 ? number0 : number1) }
    static func seconds(_ time: Double) -> String { "\(time.formatted(.number.precision(.fractionLength(1)))) s" }
    static func latency(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        if seconds == 0 { return "0 ms" }
        if seconds < 0.001 { return "\((seconds * 1_000_000).formatted(number1)) µs" }
        if seconds < 1 { return "\((seconds * 1_000).formatted(number1)) ms" }
        return "\(seconds.formatted(number2)) s"
    }

    static func value(_ value: Value, param: String, unit: String? = nil) -> String {
        guard let n = value.number else { return value.description }
        // The engine reads 0 as "no timeout" / "never expires", and ports have no limits at all.
        if n == 0, ["timeout", "ttl"].contains(param) { return "None" }
        if n >= 1e15, ["concurrency", "queue", "capacity"].contains(param) { return "Unlimited" }
        if unit == "%" || ["errors", "loss", "hitRate"].contains(param) { return "\(number(n * 100))%" }
        if let unit { return "\(number(n))\(unit)" }
        if ["latency", "timeout", "backoff", "ttl"].contains(param) { return latency(n) }
        return n.formatted(number2)
    }
}

@MainActor
struct SimButton: View {
    let title: String
    var icon: String?
    var iconOnly = false
    var active = false
    var tint = Theme.muted
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon, iconOnly { Image(systemName: icon).frame(width: 13) }
                else if let icon { Label(title, systemImage: icon) }
                else { Text(title) }
            }
            .font(Theme.ui(11, .medium))
            .foregroundStyle(active ? Theme.accent : hovered ? Theme.text : tint)
            .padding(.horizontal, iconOnly ? 7 : 8)
            .frame(minHeight: 25)
            .background(active ? Theme.accent.opacity(0.12) : hovered ? Theme.hover : Theme.raised,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(active ? Theme.accent.opacity(0.26) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}

@MainActor
struct SimSegments<Item: Hashable>: View {
    let values: [Item]
    let selected: Item
    let label: (Item) -> String
    let select: (Item) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { store in
                Button { select(store) } label: {
                    Text(label(store))
                        .font(Theme.ui(11, .medium))
                        .lineLimit(1)
                        .foregroundStyle(store == selected ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 20)
                        .background(store == selected ? Theme.accent.opacity(0.13) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: Theme.radiusSmall - 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store == selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.border))
    }
}

struct SimPill: View {
    let title: String
    var icon: String?
    var tint: Color = Theme.muted

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(Theme.ui(9, .semibold)) }
            Text(title).lineLimit(1)
        }
        .font(Theme.label)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.11), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.20)))
    }
}

struct SimSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SimSparkline: View {
    let points: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let samples = points.filter(\.isFinite)
            guard samples.count > 1 else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 2))
                context.stroke(baseline, with: .color(Theme.borderStrong))
                return
            }
            let minimum = min(0, samples.min() ?? 0)
            let span = max(0.000_001, (samples.max() ?? 0) - minimum)
            let line = Path { path in
                for (i, sample) in samples.enumerated() {
                    let x = size.width * Double(i) / Double(samples.count - 1)
                    let y = size.height - 2 - (size.height - 4) * (sample - minimum) / span
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.24), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.15, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

extension Condition {
    func matches(_ value: Value) -> Bool {
        switch self {
        case .always: return true
        case .eq(let other): return value == other
        case .lt(let n): return value.number.map { $0 < n } ?? false
        case .le(let n): return value.number.map { $0 <= n } ?? false
        case .gt(let n): return value.number.map { $0 > n } ?? false
        case .ge(let n): return value.number.map { $0 >= n } ?? false
        case .between(let a, let b): return value.number.map { a <= $0 && $0 <= b } ?? false
        }
    }
}

extension Health {
    var presentation: (title: String, icon: String, tint: Color) {
        switch self {
        case .up: ("Healthy", "circle.fill", Theme.good)
        case .down: ("Down", "xmark.circle.fill", Theme.bad)
        case .slow: ("Slow", "tortoise", Theme.warn)
        case .failing: ("Errors", "exclamationmark.circle.fill", Theme.bad)
        }
    }
}

struct SimPanelScroll<Content: View>: View {
    let still: Bool
    /// Scrolls back to the top when this changes (a new selection or tab), keeping the scroll view
    /// itself, which is much cheaper than rebuilding it with `.id`.
    var resetOn: AnyHashable?
    @ViewBuilder var content: Content
    @State private var position = ScrollPosition(edge: .top)

    init(still: Bool, resetOn: AnyHashable? = nil, @ViewBuilder content: () -> Content) {
        self.still = still
        self.resetOn = resetOn
        self.content = content()
    }

    var body: some View {
        if still {
            GeometryReader { proxy in
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
            }
        } else {
            ScrollView { content }
                .scrollPosition($position)
                .onChange(of: resetOn) { position.scrollTo(edge: .top) }
        }
    }
}

@MainActor
struct SimSlider: View {
    let title: String
    @SwiftUI.Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { proxy in
            let radius: CGFloat = 5
            let travel = max(1, proxy.size.width - radius * 2)
            let fraction = (min(range.upperBound, max(range.lowerBound, dragValue ?? value)) - range.lowerBound) /
                (range.upperBound - range.lowerBound)
            let x = radius + travel * fraction
            let y = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.borderStrong).frame(width: proxy.size.width, height: 3)
                    .offset(y: y - 1.5)
                Capsule().fill(Theme.accent.opacity(0.78)).frame(width: x, height: 3)
                    .offset(y: y - 1.5)
                Circle().fill(Theme.accent).frame(width: radius * 2, height: radius * 2)
                    .position(x: x, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                let fraction = min(1, max(0, (event.location.x - radius) / travel))
                let offset = range.upperBound - range.lowerBound
                let candidate = fraction == 1 ? range.upperBound : range.lowerBound + (fraction * offset / step).rounded() * step
                dragValue = update(candidate)
            }.onEnded { _ in dragValue = nil })
        }
        .frame(height: 20)
        .focusable()
        .onKeyPress(.leftArrow) { update(value - step); return .handled }
        .onKeyPress(.rightArrow) { update(value + step); return .handled }
        .accessibilityLabel(title)
        .accessibilityValue(SimFormat.number(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: update(value + step)
            case .decrement: update(value - step)
            @unknown default: break
            }
        }
    }

    @discardableResult
    private func update(_ input: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, input))
        if value != clamped { value = clamped }
        return clamped
    }
}
