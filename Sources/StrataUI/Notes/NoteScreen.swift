import Observation
import SwiftUI
import StrataCore

/// Live Markdown, reading view, and the note inspector.
@MainActor
public struct NoteScreen: View {
    let model: AppModel
    let path: String
    private let initiallyReading: Bool

    public init(model: AppModel, path: String) {
        self.init(model: model, path: path, initiallyReading: false)
    }

    public init(model: AppModel, path: String, initiallyReading: Bool) {
        self.model = model
        self.path = path
        self.initiallyReading = initiallyReading
    }

    public var body: some View {
        NoteContent(model: model, path: path, initiallyReading: initiallyReading).id(path)
    }
}

@MainActor
private struct NoteContent: View {
    let model: AppModel
    let path: String
    let workspace: NoteWorkspace
    let initiallyReading: Bool
    @State private var session: NoteSession
    @State private var owner = UUID()
    @State private var renaming = false
    @State private var name = ""
    @State private var titleFocused = false
    @State private var jump: NoteWorkspace.Destination?
    @State private var editorJump: (id: UUID, line: Int)?

    init(model: AppModel, path: String, initiallyReading: Bool) {
        self.model = model
        self.path = path
        self.initiallyReading = initiallyReading
        workspace = NoteWorkspace.of(model)
        _session = State(initialValue: NoteSession(model: model, path: path))
    }

    private var reading: Bool { workspace.reading.contains(path) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            if session.exists {
                HStack(spacing: 0) {
                    Group {
                        if reading {
                            NoteReader(model: model, path: path, document: session.document,
                                       jump: jump, toggleTask: session.toggleTask)
                        } else {
                            NoteEditor(model: model, path: path, text: session.text, jump: editorJump,
                                       onEdit: session.edit, toggleReading: toggleReading)
                                .frame(maxWidth: 828)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if model.inspectorVisible {
                        Rectangle().fill(Theme.border).frame(width: 1)
                        NoteInspector(model: model, path: path, document: session.document) { line in
                            workspace.open(path, at: .line(line), model: model)
                        }
                        .frame(width: Theme.inspectorWidth)
                    }
                }
            } else {
                unavailable
            }
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear {
            workspace.session = session
            session.refreshFromDisk()
            session.resumeDraft()
            if initiallyReading { workspace.reading.insert(path) }
            receiveDestination()
            publishCommands()
        }
        .onDisappear {
            session.flush()
            if workspace.commandOwner == owner {
                workspace.commandOwner = nil
                model.screenCommands = []
            }
            if workspace.session === session { workspace.session = nil }
        }
        .onChange(of: model.vault.revision) { _, _ in session.refreshFromDisk() }
        .onChange(of: workspace.destination?.id) { _, _ in receiveDestination() }
        .onChange(of: session.exists) { _, _ in publishCommands() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").font(Theme.ui(16)).foregroundStyle(Theme.muted)
                .frame(width: 30, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                if renaming {
                    StrataTextField(placeholder: "Note title", text: $name, focused: $titleFocused, overlays: model.overlays,
                                    size: 15, weight: .semibold, onSubmit: commitRename, onEscape: { renaming = false })
                        .padding(.horizontal, 5)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.accent.opacity(0.35)))
                        .frame(maxWidth: 360)
                } else {
                    Text(NoteLinks.title(path))
                        .font(Theme.ui(15, .semibold))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: startRename)
                        .accessibilityAction(named: "Rename note", startRename)
                }
                let folder = (path as NSString).deletingLastPathComponent
                Text(folder.isEmpty ? "Vault" : folder.replacingOccurrences(of: "/", with: "  /  "))
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if session.exists {
                HStack(spacing: 2) {
                    modeButton("Edit", symbol: "square.and.pencil", selected: !reading)
                    modeButton("Read", symbol: "book", selected: reading)
                }
                .padding(3)
                .card(Theme.bg, radius: Theme.radiusSmall)
                NoteIconButton(title: model.inspectorVisible ? "Hide inspector" : "Show inspector",
                               symbol: "sidebar.right", active: model.inspectorVisible) {
                    withAnimation(Theme.snappy) { model.inspectorVisible.toggle() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 59)
        .background(Theme.surface)
    }

    @ViewBuilder
    private func modeButton(_ title: String, symbol: String, selected: Bool) -> some View {
        let button = Button {
            if !selected { toggleReading() }
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.ui(11, .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(selected ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        if selected { button }
        else { button.keyboardShortcut("e", modifiers: [.command, .shift]) }
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: session.unreadable ? "doc.text" : "doc.badge.plus")
                .font(Theme.ui(24, .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 54, height: 54)
                .card(Theme.raised)
                .accessibilityHidden(true)
            Text(session.unreadable ? "Can’t read this note" : "Note not found")
                .font(Theme.title)
            Text(session.unreadable ? "Strata couldn’t open the file at this location." : "Create a Markdown file at this location in your vault.")
                .font(Theme.ui())
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if !session.unreadable {
                Button {
                    session.create()
                } label: {
                    Label("Create this note", systemImage: "plus")
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 13)
                        .frame(height: 31)
                        .card(Theme.accent.opacity(0.11), radius: Theme.radiusSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 5)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func publishCommands() {
        guard model.route == .note(path) else { return }
        workspace.commandOwner = owner
        model.screenCommands = session.exists ? [
            MenuItem("Toggle reading view", icon: "book", shortcut: "⇧⌘E", action: toggleReading),
            MenuItem("Rename note", icon: "pencil", action: startRename),
            MenuItem("Reveal in Finder", icon: "folder") { [weak vault = model.vault] in vault?.reveal(path) },
            MenuItem("Move to Trash", icon: "trash", role: .destructive) { [weak session] in session?.trash() }
        ] : []
    }

    private func toggleReading() {
        guard session.exists else { return }
        session.flush()
        session.updateDocument()
        if reading { workspace.reading.remove(path) }
        else { workspace.reading.insert(path) }
    }

    private func startRename() {
        guard session.exists else { return }
        name = NoteLinks.title(path)
        renaming = true
        titleFocused = true
    }

    private func commitRename() {
        guard let newPath = session.rename(to: name) else { return }
        renaming = false
        workspace.remap(path, to: newPath, model: model)
    }

    private func receiveDestination() {
        guard let destination = workspace.destination, destination.path == path, session.exists,
              let line = NoteDocument(session.text).line(for: destination.location) else { return }
        if reading { jump = destination }
        else { editorJump = (destination.id, line) }
        workspace.destination = nil
    }
}

@MainActor
@Observable
final class NoteSession {
    private weak var model: AppModel?
    let path: String
    var text: String
    var document: NoteDocument
    private var disk: NoteRead
    var exists: Bool { disk.text != nil }
    var unreadable: Bool { disk == .unreadable }
    @ObservationIgnored private var base: NoteVersion?
    @ObservationIgnored private var hasPendingDraft: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var parsedText: String

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
        let disk = model.vault.readNote(path)
        let draft = NoteWorkspace.of(model).draft(for: path)
        let source = draft?.text ?? disk.text ?? ""
        self.disk = disk
        base = draft?.base ?? disk.version
        hasPendingDraft = draft != nil
        text = source
        document = NoteDocument(source)
        parsedText = source
    }

    func resumeDraft() {
        if hasPendingDraft { flush() }
    }

    func edit(_ updated: String) {
        guard text != updated else { return }
        text = updated
        scheduleSave()
    }

    func toggleTask(_ task: NoteDocument.TaskMarker) {
        let source = NSMutableString(string: text)
        guard task.offset < source.length else { return }
        let range = NSRange(location: task.offset, length: 1)
        guard source.substring(with: range) == task.character else { return }
        source.replaceCharacters(in: range, with: task.checked ? " " : "x")
        text = source as String
        flush()
    }

    func create() {
        guard let model, !isDirty else { return }
        if model.vault.readNote(path) == .missing { model.vault.createNote(at: path) }
        let current = model.vault.readNote(path)
        replaceFromDisk(current)
        if current == .missing { model.overlays.toast("Couldn’t create note") }
    }

    func rename(to name: String) -> String? {
        guard let model, flush() else { return nil }
        guard let renamed = model.vault.rename(path, to: name) else {
            model.overlays.toast("Couldn’t rename note")
            return nil
        }
        return renamed
    }

    func trash() {
        guard let model, flush() else { return }
        do {
            try model.vault.moveToTrash(path)
            model.overlays.toast("Moved to Trash")
            NoteWorkspace.of(model).remap(path, to: nil, model: model)
        } catch { model.overlays.toast("Couldn’t move note to Trash") }
    }

    func refreshFromDisk() {
        guard let model, !isDirty else { return }
        let current = model.vault.readNote(path)
        if current != disk { replaceFromDisk(current) }
    }

    func updateDocument() {
        if parsedText != text {
            parsedText = text
            document = NoteDocument(text)
        }
    }

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard let model else { return false }
        updateDocument()
        guard isDirty, let base else { return true }
        let workspace = NoteWorkspace.of(model)
        switch model.vault.saveEdit(path, text: text, basedOn: base) {
        case .saved(let saved):
            workspace.clearDraft(for: path)
            replaceFromDisk(saved)
            return true
        case .changed(let disk):
            let copy = model.vault.createNote(in: nil, name: NoteLinks.title(path) + " (local edits)", text: text)
            if !copy.isEmpty {
                workspace.clearDraft(for: path)
                replaceFromDisk(disk)
                model.overlays.toast("Note changed on disk. Local edits saved to \(NoteLinks.title(copy)).")
                return exists
            }
        case .failed:
            break
        }
        hasPendingDraft = true
        let kept = workspace.retainDraft(NoteDraft(text: text, base: base), for: path)
        model.overlays.toast(kept ? "Couldn’t save note. Draft kept for recovery." : "Couldn’t save note or keep a recovery draft.")
        return false
    }

    private var isDirty: Bool { hasPendingDraft || text != (disk.text ?? "") }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { self?.flush() }
        }
    }

    private func replaceFromDisk(_ current: NoteRead) {
        disk = current
        base = current.version
        hasPendingDraft = false
        text = current.text ?? ""
        updateDocument()
    }
}
