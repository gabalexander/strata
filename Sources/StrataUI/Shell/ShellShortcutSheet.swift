import AppKit
import SwiftUI
import StrataCore

/// The keyboard shortcut sheet (docs/design.md, Shortcut sheet): every shortcut by area, drawn inside the
/// window like the palette, never a system window. ⌘/ (the app menu) or ? outside a text field opens it;
/// Esc, ⌘/, ?, the close button or a click outside closes it. It reads `Shortcuts.all`, the same list the
/// handlers match, so it can't drift from what the keys do.
@MainActor
struct ShortcutSheetHost: View {
    let model: AppModel

    var body: some View {
        ZStack {
            if model.shortcutSheetOpen {
                Color.black.opacity(0.42)
                    .contentShape(Rectangle())
                    .onTapGesture { model.shortcutSheetOpen = false }
                    .transition(.opacity)
                GeometryReader { proxy in
                    ShortcutSheet(model: model, size: proxy.size)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(Theme.snappy, value: model.shortcutSheetOpen)
        .background {
            WindowEvents(matching: .keyDown) { event, _ in
                guard !model.paletteOpen, !model.switcherOpen, model.overlays.menu == nil else { return event }
                if model.shortcutSheetOpen, Shortcuts.escape.matches(event) || Shortcuts.sheetKey.matches(event) {
                    if !event.isARepeat { model.shortcutSheetOpen = false }
                    return nil
                }
                // `?` opens it anywhere but in a text field, where it is a question mark.
                if !model.shortcutSheetOpen, Shortcuts.sheetKey.matches(event), !(event.window?.firstResponder is NSText) {
                    model.overlays.closeTerm()
                    model.shortcutSheetOpen = true
                    return nil
                }
                return event
            }
        }
    }
}

@MainActor
private struct ShortcutSheet: View {
    let model: AppModel
    let size: CGSize

    /// Three columns when the window has room, else two; the sheet scrolls when it is still too tall.
    private var columns: [[Shortcut.Area]] {
        size.width >= 1080
            ? [[.anywhere], [.map], [.how, .journey, .notes, .lists]]
            : [[.anywhere, .notes, .lists], [.map, .how, .journey]]
    }

    var body: some View {
        let columns = self.columns
        let width = min(size.width - 48, CGFloat(columns.count) * 318 + 40)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, areas in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(areas, id: \.self) { area in section(area) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: max(0, width))
        .frame(maxHeight: max(0, size.height - 64))
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        .contentShape(Rectangle())
        .onTapGesture {}   // a click inside never reaches the backdrop
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").font(Theme.ui(14, .medium)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard shortcuts").font(Theme.heading).foregroundStyle(Theme.text)
                Text("Hover a control for what it does; right-click anything for its actions.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            StrataKeycap("Esc")
            SimButton(title: "Close", icon: "xmark", iconOnly: true, shortcut: Shortcuts.escape) { model.shortcutSheetOpen = false }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private func section(_ area: Shortcut.Area) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(area.rawValue).font(Theme.ui(11, .semibold)).foregroundStyle(Theme.accent)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            let rows = Shortcuts.all.filter { $0.area == area }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, shortcut in
                // Pointer gestures after the keys, a little apart.
                if index > 0, shortcut.gesture != nil, !shortcut.gesture!.hasPrefix("Esc"), shortcut.id != Shortcuts.hotkey.id,
                   rows[index - 1].gesture == nil {
                    Spacer().frame(height: 6)
                }
                row(shortcut)
            }
        }
    }

    private func row(_ shortcut: Shortcut) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(shortcut.title).font(Theme.ui(12)).foregroundStyle(Theme.text.opacity(0.88))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            keys(shortcut)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func keys(_ shortcut: Shortcut) -> some View {
        if shortcut.id == Shortcuts.hotkey.id {
            StrataKeycap(Self.hotkey(model.config.hotkey))
        } else if let gesture = shortcut.gesture {
            if gesture.hasPrefix("Esc") {
                HStack(spacing: 3) { StrataKeycap("Esc"); StrataKeycap("Esc") }
            } else {
                Text(gesture).font(Theme.ui(11, .medium)).foregroundStyle(Theme.muted).fixedSize()
            }
        } else {
            HStack(spacing: 3) {
                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                    StrataKeycap(shortcut.modifiers.glyphs + key.glyph)
                }
            }
        }
    }

    /// `ctrl+option+s` as `⌃⌥S`.
    static func hotkey(_ spec: String) -> String {
        let glyphs = ["ctrl": "⌃", "control": "⌃", "option": "⌥", "opt": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        let mods = parts.dropLast().compactMap { glyphs[$0] }
        let order = ["⌃", "⌥", "⇧", "⌘"].filter(mods.contains)
        return order.joined() + (parts.last?.uppercased() ?? "")
    }
}
