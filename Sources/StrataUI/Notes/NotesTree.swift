import SwiftUI
import UniformTypeIdentifiers
import StrataCore

/// The sidebar's vault section.
@MainActor
public struct NotesTree: View {
    let model: AppModel
    @State private var renaming: String?
    @State private var name = ""
    @FocusState private var focusedRow: String?
    @State private var focusedName = false

    public init(model: AppModel) { self.model = model }

    private var workspace: NoteWorkspace { .of(model) }
    private var selected: String? {
        if case .note(let path) = model.route { return path }
        return nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Notes").font(Theme.label).foregroundStyle(Theme.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                NoteIconButton(title: "New note", symbol: "plus") { create(in: nil, folder: false) }
            }
            .padding(.leading, 7)
            .onRightClick { _, point in model.overlays.showMenu(creationItems(in: nil), at: point) }

            ForEach(visibleRows) { row in
                if renaming == row.id {
                    nameField(row)
                } else if row.item.isFolder {
                    treeRow(row).dropDestination(for: VaultDrag.self) { data, _ in drop(data, in: row.id) }
                } else {
                    treeRow(row).draggable(VaultDrag(root: model.vault.root.path, path: row.id))
                }
            }
            Color.clear
                .frame(height: visibleRows.isEmpty ? 42 : 20)
                .overlay(alignment: .topLeading) {
                    if visibleRows.isEmpty {
                        Text("No notes yet").font(Theme.small).foregroundStyle(Theme.faint).padding(7)
                    }
                }
                .contentShape(Rectangle())
                .onRightClick { _, point in model.overlays.showMenu(creationItems(in: nil), at: point) }
                .dropDestination(for: VaultDrag.self) { data, _ in drop(data, in: nil) }
        }
        .padding(.horizontal, 6)
        .onChange(of: selected, initial: true) { _, path in
            if let path { workspace.expandAncestors(of: path) }
        }
    }

    private var visibleRows: [Row] {
        func rows(_ items: [VaultItem], depth: Int) -> [Row] {
            items.flatMap { item in
                let row = Row(item: item, depth: depth)
                return workspace.expanded.contains(item.path) ? [row] + rows(item.children, depth: depth + 1) : [row]
            }
        }
        return rows(model.vault.items, depth: 0)
    }

    private struct Row: Identifiable {
        let item: VaultItem
        let depth: Int
        var id: String { item.path }
        var indent: CGFloat { CGFloat(min(depth, 12)) * 13 + 5 }
    }

    private func treeRow(_ row: Row) -> some View {
        let open = workspace.expanded.contains(row.id)
        let isSelected = selected == row.id
        return VaultRow(item: row.item, open: open, selected: isSelected, indent: row.indent) {
            focusedRow = row.id
            if row.item.isFolder {
                if open { workspace.expanded.remove(row.id) }
                else { workspace.expanded.insert(row.id) }
            } else {
                model.open(.note(row.id))
            }
        }
        .focusable()
        .focused($focusedRow, equals: row.id)
        .focusEffectDisabled()
        .onKeyPress(.return) { startRename(row.item); return .handled }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(row.item) })
        .onRightClick { _, point in model.overlays.showMenu(menu(for: row.item), at: point) }
        .accessibilityAction(named: "Rename") { startRename(row.item) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func nameField(_ row: Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.item.isFolder ? "folder" : "doc.text")
                .font(Theme.ui(12)).foregroundStyle(Theme.accent)
                .frame(width: 15)
            StrataTextField(placeholder: "Name", text: $name, focused: $focusedName, overlays: model.overlays,
                            onSubmit: { commitRename(row.item) },
                            onEscape: { renaming = nil; focusedRow = row.id })
                .padding(.horizontal, 5)
                .frame(height: 23)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.accent.opacity(0.42)))
        }
        .padding(.leading, row.indent + 14)
        .padding(.trailing, 3)
        .frame(height: 28)
    }

    private func startRename(_ item: VaultItem) {
        name = item.name
        renaming = item.path
        focusedName = true
    }

    private func commitRename(_ item: VaultItem) {
        guard workspace.session?.flush() != false else { return }
        if let moved = model.vault.rename(item.path, to: name) {
            renaming = nil
            workspace.remap(item.path, to: moved, model: model)
            focusedRow = moved
        } else {
            model.overlays.toast("Couldn’t rename \(item.isFolder ? "folder" : "note")")
        }
    }

    private func creationItems(in folder: String?) -> [MenuItem] {
        [
            MenuItem("New note", icon: "square.and.pencil") { create(in: folder, folder: false) },
            MenuItem("New folder", icon: "folder.badge.plus") { create(in: folder, folder: true) }
        ]
    }

    private func menu(for item: VaultItem) -> [MenuItem] {
        let folder = item.isFolder ? item.path : (item.path as NSString).deletingLastPathComponent
        return creationItems(in: folder) + [
            .separator,
            MenuItem("Rename", icon: "pencil", shortcut: "↩") { startRename(item) },
            MenuItem("Reveal in Finder", icon: "folder") { model.vault.reveal(item.path) },
            MenuItem("Copy [[link]]", icon: "link", enabled: !item.isFolder) {
                NoteLinks.copy("[[\(NoteLinks.label(item.path))]]")
                model.overlays.toast("Link copied")
            },
            .separator,
            MenuItem("Move to Trash", icon: "trash", role: .destructive) { trash(item) }
        ]
    }

    private func create(in path: String?, folder: Bool) {
        let created = folder ? model.vault.createFolder(in: path, name: "New folder") : model.vault.createNote(in: path, name: "Untitled")
        guard !created.isEmpty else { model.overlays.toast("Couldn’t create \(folder ? "folder" : "note")"); return }
        workspace.expandAncestors(of: created)
        if !folder {
            model.open(.note(created))
            startRename(VaultItem(path: created, name: NoteLinks.title(created), isFolder: false))
        } else {
            startRename(VaultItem(path: created, name: (created as NSString).lastPathComponent, isFolder: true))
        }
    }

    private func drop(_ data: [VaultDrag], in folder: String?) {
        guard let dragged = data.first, dragged.root == model.vault.root.path,
              workspace.session?.flush() != false else { return }
        guard let moved = model.vault.move(dragged.path, toFolder: folder) else {
            model.overlays.toast("Couldn’t move note")
            return
        }
        if let folder { workspace.expanded.insert(folder) }
        workspace.remap(dragged.path, to: moved, model: model)
    }

    private func trash(_ item: VaultItem) {
        guard workspace.session?.flush() != false else { return }
        do {
            try model.vault.moveToTrash(item.path)
            if renaming == item.path || renaming?.hasPrefix(item.path + "/") == true { renaming = nil }
            workspace.remap(item.path, to: nil, model: model)
            model.overlays.toast("Moved to Trash")
        } catch {
            model.overlays.toast("Couldn’t move \(item.isFolder ? "folder" : "note") to Trash")
        }
    }
}

private struct VaultRow: View {
    let item: VaultItem
    let open: Bool
    let selected: Bool
    let indent: CGFloat
    let activate: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(Theme.ui(8, .semibold)).foregroundStyle(Theme.faint)
                    .frame(width: 9)
                    .opacity(item.isFolder ? 1 : 0)
                    .accessibilityHidden(true)
                Image(systemName: item.isFolder ? (open ? "folder.fill" : "folder") : "doc.text")
                    .font(Theme.ui(12))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                    .frame(width: 15)
                    .accessibilityHidden(true)
                Text(item.name)
                    .font(Theme.ui(13, selected ? .medium : .regular))
                    .foregroundStyle(selected || hovered ? Theme.text : Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .padding(.trailing, 5)
            .frame(height: 27)
            .background(selected ? Theme.accent.opacity(0.11) : hovered ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct VaultDrag: Codable, Transferable {
    let root: String
    let path: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.strata.vault-note"))
    }
}
