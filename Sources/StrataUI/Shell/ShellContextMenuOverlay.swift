import AppKit
import SwiftUI

@MainActor
struct ContextMenuOverlay: View {
    let menu: Overlays.Menu
    let overlays: Overlays
    let size: CGSize

    @State private var branches: [UUID] = []
    @State private var selection: [Int: UUID] = [:]
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var hoverTask: Task<Void, Never>?

    private let margin: CGFloat = 8
    private let insets: CGFloat = 5

    private struct Column {
        let items: [MenuItem]
        let frame: CGRect
        let scrollable: Bool
    }

    var body: some View {
        let columns = placeColumns()
        ZStack(alignment: .topLeading) {
            ForEach(columns.indices, id: \.self) { depth in
                let column = columns[depth]
                panel(column, depth: depth)
                    .position(x: column.frame.midX, y: column.frame.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            WindowEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { event, _ in
                if event.type == .keyDown { return handleKey(event, columns: columns) }
                if event.type == .scrollWheel {
                    let scrollable = event.contentLocation.flatMap { point in
                        columns.last { $0.frame.contains(point) }?.scrollable
                    } ?? false
                    if !scrollable { overlays.dismissMenu() }
                    return event
                }
                if let point = event.contentLocation, !columns.contains(where: { $0.frame.contains(point) }) {
                    overlays.dismissMenu()
                    return nil
                }
                return event
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context menu")
        .accessibilityAction(.escape) { overlays.dismissMenu() }
    }

    private func placeColumns() -> [Column] {
        let width = min(246, max(0, size.width - margin * 2))
        let maxHeight = max(0, size.height - margin * 2)
        var columns: [Column] = []

        func append(_ items: [MenuItem], at point: CGPoint) {
            let fullHeight = items.reduce(insets * 2) { $0 + rowHeight($1) }
            let height = min(fullHeight, maxHeight)
            let x = min(max(margin, point.x), max(margin, size.width - width - margin))
            let y = min(max(margin, point.y), max(margin, size.height - height - margin))
            columns.append(Column(items: items, frame: CGRect(x: x, y: y, width: width, height: height),
                                  scrollable: fullHeight > maxHeight))
        }
        append(menu.items, at: menu.at)
        for branch in branches {
            guard let parent = columns.last, let index = parent.items.firstIndex(where: { $0.id == branch }) else { break }
            let item = parent.items[index]
            let right = parent.frame.maxX - 2
            let left = parent.frame.minX - width + 2
            let fitsRight = right + width + margin <= size.width
            let fallbackY = parent.frame.minY + parent.items.prefix(index).reduce(0) { $0 + rowHeight($1) }
            let y = rowFrames[branch].map { $0.minY - insets } ?? fallbackY
            append(item.submenu, at: CGPoint(x: fitsRight || left < margin && right < size.width - width ? right : left,
                                             y: max(parent.frame.minY, min(y, parent.frame.maxY - rowHeight(item)))))
        }
        return columns
    }

    private func panel(_ column: Column, depth: Int) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(column.items) { item in
                        row(item, depth: depth)
                            .id(item.id)
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                                if !item.submenu.isEmpty { rowFrames[item.id] = frame }
                            }
                    }
                }
                .padding(insets)
            }
            .scrollDisabled(!column.scrollable)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection[depth]) {
                if let item = selection[depth], column.scrollable { scroll.scrollTo(item) }
            }
        }
        .frame(width: column.frame.width, height: column.frame.height)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.borderStrong)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 12)
        .onHover { inside in if inside && depth > 0 { hoverTask?.cancel() } }
    }

    @ViewBuilder
    private func row(_ item: MenuItem, depth: Int) -> some View {
        if item.isSeparator {
            Rectangle()
                .fill(Theme.borderStrong)
                .frame(height: 1)
                .padding(.horizontal, 5)
                .frame(height: rowHeight(item))
                .accessibilityHidden(true)
        } else if item.isHeader {
            Text(item.title)
                .font(Theme.label)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: rowHeight(item))
                .accessibilityAddTraits(.isHeader)
        } else {
            let selected = selection[depth] == item.id || branches.indices.contains(depth) && branches[depth] == item.id
            let tint = item.role == .destructive ? Theme.bad : Theme.text
            Button {
                activate(item, depth: depth)
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if item.checked {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        } else if let icon = item.icon {
                            Image(systemName: icon).foregroundStyle(item.role == .destructive ? Theme.bad : Theme.muted)
                        }
                    }
                    .frame(width: 15)
                    Text(item.title).foregroundStyle(tint).lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcut = item.shortcut {
                        Text(shortcut).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    if !item.submenu.isEmpty {
                        Image(systemName: "chevron.right").font(Theme.ui(9, .semibold)).foregroundStyle(Theme.muted)
                    }
                }
                .font(Theme.ui())
                .padding(.horizontal, 8)
                .frame(height: rowHeight(item))
                .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .opacity(item.enabled ? 1 : 0.44)
            }
            .buttonStyle(.plain)
            .disabled(!item.enabled)
            .onHover { inside in if inside && item.enabled { hover(item, depth: depth) } }
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func rowHeight(_ item: MenuItem) -> CGFloat {
        if item.isSeparator { return 9 }
        return item.isHeader ? 23 : 26
    }

    private func hover(_ item: MenuItem, depth: Int) {
        hoverTask?.cancel()
        selection[depth] = item.id
        if branches.indices.contains(depth), branches[depth] == item.id { return }
        if branches.count == depth, item.submenu.isEmpty { return }
        hoverTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                openBranch(item, depth: depth, selectFirst: false)
            } catch {}
        }
    }

    private func openBranch(_ item: MenuItem, depth: Int, selectFirst: Bool) {
        branches = Array(branches.prefix(depth))
        selection = selection.filter { $0.key <= depth }
        if !item.submenu.isEmpty {
            branches.append(item.id)
            if selectFirst { selection[depth + 1] = actions(in: item.submenu).first?.id }
        }
    }

    private func activate(_ item: MenuItem, depth: Int) {
        hoverTask?.cancel()
        if !item.submenu.isEmpty {
            selection[depth] = item.id
            openBranch(item, depth: depth, selectFirst: true)
        } else {
            overlays.dismissMenu()
            item.action?()
        }
    }

    private func actions(in items: [MenuItem]) -> [MenuItem] {
        items.filter { $0.enabled && !$0.isHeader && !$0.isSeparator }
    }

    private func handleKey(_ event: NSEvent, columns: [Column]) -> NSEvent? {
        guard !event.hasCommandModifiers, let column = columns.last else { return event }
        let depth = columns.count - 1
        let items = actions(in: column.items)
        let index = items.firstIndex { $0.id == selection[depth] }
        switch event.keyCode {
        case 53:
            if !event.isARepeat { overlays.dismissMenu() }
        case 123:
            hoverTask?.cancel()
            if depth > 0 {
                branches.removeLast()
                selection[depth] = nil
            }
        case 124:
            if let index, !items[index].submenu.isEmpty { activate(items[index], depth: depth) }
        case 125, 126:
            hoverTask?.cancel()
            if !items.isEmpty {
                let down = event.keyCode == 125
                let next = index.map { ($0 + (down ? 1 : -1) + items.count) % items.count } ?? (down ? 0 : items.count - 1)
                selection[depth] = items[next].id
            }
        case 36, 76:
            if !event.isARepeat, let item = index.map({ items[$0] }) ?? items.first { activate(item, depth: depth) }
        default: return event
        }
        return nil
    }
}
