import AppKit
import SwiftUI

@MainActor
struct CommandPalette: View {
    let catalog: ShellCatalog
    let switching: Bool
    @Binding var recent: [String]
    @State private var query: String
    @State private var selection = 0
    @State private var focused = true

    init(catalog: ShellCatalog, switching: Bool, recent: Binding<[String]>) {
        self.catalog = catalog
        self.switching = switching
        self._recent = recent
        self._query = State(initialValue: catalog.fixturePaletteQuery)
    }

    var body: some View {
        let entries = PaletteResults(catalog: catalog, switching: switching).entries()
        let sections = PaletteResults.search(entries, query: query, recent: recent)
        let rows = sections.flatMap(\.entries)
        let selected = rows.indices.contains(selection) ? rows[selection].id : rows.first?.id

        ZStack(alignment: .top) {
            Rectangle()
                .fill(Theme.bg.opacity(0.72))
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            GeometryReader { geometry in
                panel(sections, selected: selected)
                    .frame(width: min(640, geometry.size.width - 32))
                    .frame(maxWidth: .infinity)
                    .padding(.top, max(24, (geometry.size.height - 445) / 2 - 24))
            }
        }
        .background {
            WindowEvents(matching: .keyDown) { event, view in
                guard catalog.model.overlays.menu == nil, !event.hasCommandModifiers,
                      (view.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                switch event.keyCode {
                case 53: if !event.isARepeat { dismiss() }
                case 36, 76:
                    if !event.isARepeat, let entry = rows.first(where: { $0.id == selected }) { choose(entry) }
                case 125: move(1, count: rows.count)
                case 126: move(-1, count: rows.count)
                default: return event
                }
                return nil
            }
            .accessibilityHidden(true)
        }
        .onChange(of: query) { selection = 0 }
        .onChange(of: rows.count) { selection = min(selection, max(0, rows.count - 1)) }
    }

    private func panel(_ sections: [PaletteResults.Section], selected: String?) -> some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle().fill(Theme.border).frame(height: 1)
            if sections.isEmpty {
                Text(query.isEmpty ? "No notes or simulators yet" : "No results")
                    .font(Theme.ui())
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
            } else {
                results(sections, selected: selected)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: Theme.radius + 2))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius + 2))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius + 2)
                .strokeBorder(Theme.borderStrong)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(switching ? "Note and simulator switcher" : "Command palette")
    }

    private var searchBar: some View {
        let prompt = switching ? "Open a note or simulator…" : "Search or run a command…"
        return HStack(spacing: 12) {
            Image(systemName: switching ? "arrow.right.square" : "magnifyingglass")
                .font(Theme.ui(17, .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            StrataTextField(placeholder: prompt, text: $query, focused: $focused, overlays: catalog.model.overlays,
                            size: 16, placeholderColor: Theme.muted)
            Button(action: dismiss) { StrataKeycap("Esc") }
                .buttonStyle(.plain)
                .accessibilityLabel("Close palette")
        }
        .padding(.horizontal, 16)
        .frame(height: 55)
    }

    private func results(_ sections: [PaletteResults.Section], selected: String?) -> some View {
        let rows = sections.reduce(0) { $0 + $1.entries.count }
        let height = CGFloat(8 + rows * 35 + sections.count * 28)
        return ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(sections, id: \.group) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            StrataSectionLabel(section.group.rawValue)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 3)
                            ForEach(section.entries) { entry in
                                row(entry, selected: selected == entry.id)
                                    .id(entry.id)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: min(352, height))
            .defaultScrollAnchor(.top)
            .onChange(of: selected) {
                if let selected { scroll.scrollTo(selected) }
            }
        }
    }

    private func row(_ entry: PaletteEntry, selected: Bool) -> some View {
        Button {
            choose(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                    .frame(width: 20)
                Text(entry.title).font(Theme.ui(13, selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 6)
                if let subtitle = entry.subtitle {
                    Text(subtitle).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
                }
                if let shortcut = entry.shortcut { StrataKeycap(shortcut) }
                else if selected { Image(systemName: "return").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 10)
            .frame(height: 33)
            .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 6) {
            StrataKeycap("↑")
            StrataKeycap("↓")
            Text("Navigate").padding(.trailing, 8)
            StrataKeycap("↩")
            Text("Select")
            Spacer()
        }
        .font(Theme.small)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func choose(_ entry: PaletteEntry) {
        recent.removeAll { $0 == entry.id }
        recent.insert(entry.id, at: 0)
        if recent.count > 16 { recent.removeLast() }
        dismiss()
        entry.action()
    }

    private func dismiss() {
        catalog.model.overlays.dismissMenu()
        catalog.model.paletteOpen = false
        catalog.model.switcherOpen = false
    }
}
