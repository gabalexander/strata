import AppKit
import SwiftUI
import StrataCore

@MainActor
struct NoteEditor: NSViewRepresentable {
    let model: AppModel
    let path: String
    let text: String
    let jump: (id: UUID, line: Int)?
    let onEdit: (String) -> Void
    let toggleReading: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NoteEditorHost {
        let host = NoteEditorHost()
        context.coordinator.attach(host)
        context.coordinator.refresh(self)
        return host
    }

    func updateNSView(_ host: NoteEditorHost, context: Context) {
        context.coordinator.refresh(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private var editor: NoteEditor
        private weak var host: NoteEditorHost?
        private let style = NoteEditorStyle()
        private var updating = false
        private var pending: (NSRange, Int)?
        private var composed = false
        private var lastJump: UUID?
        private var suggestions: [LinkSuggestion] = []
        private var selectedSuggestion = 0
        private var completionRange: NSRange?
        private var notesOnly = false

        init(_ editor: NoteEditor) { self.editor = editor }

        func attach(_ host: NoteEditorHost) {
            self.host = host
            let view = host.textView
            view.markdownStyle = style
            view.delegate = self
            view.textStorage?.delegate = self
            view.key = { [weak self] event in self?.handleKey(event) ?? false }
            view.menuRequest = { [weak self] event in self?.showMenu(event) }
            view.commandClick = { [weak self] event in self?.openLink(event) ?? false }
            view.dismissCompletion = { [weak self] in self?.closeCompletion() }
        }

        func refresh(_ editor: NoteEditor) {
            self.editor = editor
            guard let view = host?.textView, let storage = view.textStorage else { return }
            if storage.string != editor.text, !view.hasMarkedText() {
                updating = true
                let selection = view.selectedRange()
                view.undoManager?.removeAllActions(withTarget: view)
                view.string = editor.text
                style.reset(storage)
                view.typingAttributes = NoteEditorStyle.base
                view.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
                updating = false
                closeCompletion()
            }
            if let jump = editor.jump, lastJump != jump.id {
                lastJump = jump.id
                DispatchQueue.main.async { [weak self] in self?.goToLine(jump.line) }
            }
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            MainActor.assumeIsolated {
                if !updating, editedMask.contains(.editedCharacters) { pending = (editedRange, delta) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = host?.textView, let storage = view.textStorage else { return }
            if view.hasMarkedText() {
                composed = true
                return
            }
            let undo = view.undoManager
            undo?.disableUndoRegistration()
            if composed { style.reset(storage) }
            else if let (range, delta) = pending { style.update(storage, edited: range, delta: delta) }
            undo?.enableUndoRegistration()
            pending = nil
            composed = false
            view.typingAttributes = NoteEditorStyle.base
            view.needsDisplay = true
            editor.onEdit(storage.string)
            updateCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if completionRange != nil, !updating { updateCompletion() }
        }

        private func goToLine(_ line: Int) {
            guard let view = host?.textView else { return }
            let source = view.string as NSString
            var range = NSRange(location: source.length, length: 0)
            var number = 0
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { _, lineRange, _, stop in
                number += 1
                if number == max(1, line) {
                    range = lineRange
                    stop.pointee = true
                }
            }
            view.setSelectedRange(range)
            view.scrollRangeToVisible(range)
            view.window?.makeFirstResponder(view)
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == [.command, .shift], key == "e" {
                editor.toggleReading()
                return true
            }
            if modifiers == [.command] {
                switch key {
                case "b": wrap("**"); return true
                case "i": wrap("*"); return true
                case "e": wrap("`"); return true
                default: return false
                }
            }
            if !suggestions.isEmpty, modifiers.isEmpty {
                switch event.keyCode {
                case 125: selectSuggestion(min(suggestions.count - 1, selectedSuggestion + 1)); return true
                case 126: selectSuggestion(max(0, selectedSuggestion - 1)); return true
                case 36, 76, 48: accept(suggestions[selectedSuggestion]); return true
                case 53: closeCompletion(); return true
                default: break
                }
            }
            if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 { return continueList() }
            if modifiers.isEmpty || modifiers == [.shift], event.keyCode == 48 { return indentList(outdent: modifiers.contains(.shift)) }
            return false
        }

        private func wrap(_ marker: String) {
            guard let view = host?.textView else { return }
            let range = view.selectedRange()
            let text = (view.string as NSString).substring(with: range)
            let replacement = marker + text + marker
            replace(range, with: replacement, selection: NSRange(location: range.location + marker.utf16.count, length: range.length))
        }

        private func continueList() -> Bool {
            guard let view = host?.textView else { return false }
            let range = view.selectedRange()
            let source = view.string as NSString
            guard range.length == 0, style.allowsListEditing(at: range.location) else { return false }
            let lineRange = source.lineRange(for: range)
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            guard let match = NoteDocument.listMatch(in: line), !NoteDocument.isRule(line) else { return false }
            let data = line as NSString
            let body = match.range(at: 4)
            guard range.location >= lineRange.location + body.location else { return false }
            if data.substring(with: body).trimmingCharacters(in: .whitespaces).isEmpty {
                let prefix = NSRange(location: lineRange.location, length: data.length)
                replace(prefix, with: "")
                return true
            }
            let indent = data.substring(with: match.range(at: 1))
            let marker = data.substring(with: match.range(at: 2))
            var next = marker
            if let integer = Int(marker.dropLast()), integer < Int.max {
                next = String(integer + 1) + marker.suffix(1)
            }
            let task = match.range(at: 3).location != NSNotFound ? "[ ] " : ""
            replace(range, with: "\n" + indent + next + " " + task)
            return true
        }

        private func indentList(outdent: Bool) -> Bool {
            guard let view = host?.textView else { return false }
            let selected = view.selectedRange()
            let source = view.string as NSString
            let spanning = NSRange(location: selected.location, length: max(0, selected.length - 1))
            let range = source.lineRange(for: spanning)
            var changes: [(NSRange, String)] = []
            var matched = false
            source.enumerateSubstrings(in: range, options: .byLines) { line, content, _, _ in
                guard let line, self.style.allowsListEditing(at: content.location), !NoteDocument.isRule(line),
                      let match = NoteDocument.listMatch(in: line) else { return }
                matched = true
                let indent = (line as NSString).substring(with: match.range(at: 1))
                if outdent {
                    let length = indent.hasPrefix("\t") ? 1 : min(indent.prefix(while: { $0 == " " }).count, 2)
                    if length > 0 { changes.append((NSRange(location: content.location, length: length), "")) }
                } else {
                    changes.append((NSRange(location: content.location, length: 0), "  "))
                }
            }
            guard matched, !changes.isEmpty else { return matched }
            let text = NSMutableString(string: source.substring(with: range))
            var start = selected.location
            var end = NSMaxRange(selected)
            for (change, replacement) in changes.reversed() {
                text.replaceCharacters(in: NSRange(location: change.location - range.location, length: change.length), with: replacement)
                let delta = replacement.utf16.count - change.length
                if change.location <= start { start = max(change.location, start + delta) }
                if change.location <= end { end = max(change.location, end + delta) }
            }
            replace(range, with: text as String, selection: NSRange(location: start, length: max(0, end - start)))
            return true
        }

        private func replace(_ range: NSRange, with value: String, selection: NSRange? = nil) {
            guard let view = host?.textView, view.shouldChangeText(in: range, replacementString: value) else { return }
            updating = true
            view.textStorage?.replaceCharacters(in: range, with: value)
            view.setSelectedRange(selection ?? NSRange(location: range.location + value.utf16.count, length: 0))
            updating = false
            pending = (NSRange(location: range.location, length: value.utf16.count), value.utf16.count - range.length)
            view.didChangeText()
        }

        private func openLink(_ event: NSEvent) -> Bool {
            guard let view = host?.textView else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            let index = view.characterIndexForInsertion(at: point)
            guard let link = style.wikiLink(at: index, in: view.string as NSString) else { return false }
            closeCompletion()
            NoteLinks.open(link.target, heading: link.heading, from: editor.path, model: editor.model)
            return true
        }

        private func showMenu(_ event: NSEvent) {
            guard let view = host?.textView, let window = view.window, let root = window.contentView else { return }
            closeCompletion()
            let p = root.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: p.x, y: root.isFlipped ? p.y : root.bounds.height - p.y)
            let local = view.convert(event.locationInWindow, from: nil)
            let at = view.characterIndexForInsertion(at: local)
            let selection = view.selectedRange()
            if !NSLocationInRange(at, selection), at <= (view.string as NSString).length {
                view.setSelectedRange(NSRange(location: at, length: 0))
            }
            window.makeFirstResponder(view)
            let selected = view.selectedRange().length > 0
            let sims = editor.model.library.entries.map { entry in
                MenuItem(entry.title, icon: "play.rectangle") { [weak self] in
                    self?.insert("\n\n```strata\nsim: \(entry.id)\n```\n")
                }
            }
            editor.model.overlays.showMenu([
                MenuItem("Cut", icon: "scissors", shortcut: "⌘X", enabled: selected) { [weak view] in view?.cut(nil) },
                MenuItem("Copy", icon: "document.on.document", shortcut: "⌘C", enabled: selected) { [weak view] in view?.copy(nil) },
                MenuItem("Paste", icon: "clipboard", shortcut: "⌘V", enabled: NSPasteboard.general.string(forType: .string) != nil) { [weak view] in view?.pasteAsPlainText(nil) },
                .separator,
                MenuItem("Bold", icon: "bold", shortcut: "⌘B") { [weak self] in self?.wrap("**") },
                MenuItem("Italic", icon: "italic", shortcut: "⌘I") { [weak self] in self?.wrap("*") },
                MenuItem("Code", icon: "chevron.left.forwardslash.chevron.right", shortcut: "⌘E") { [weak self] in self?.wrap("`") },
                .separator,
                MenuItem("Insert link to note…", icon: "link") { [weak self] in self?.insertNoteLink() },
                sims.isEmpty ? MenuItem("Insert sim embed", icon: "play.rectangle", enabled: false) : .submenu("Insert sim embed", icon: "play.rectangle", sims),
                .separator,
                MenuItem("Toggle reading view", icon: "book", shortcut: "⇧⌘E") { [weak self] in self?.editor.toggleReading() }
            ], at: point)
        }

        private func insert(_ text: String) {
            guard let view = host?.textView else { return }
            view.window?.makeFirstResponder(view)
            replace(view.selectedRange(), with: text)
        }

        private func insertNoteLink() {
            notesOnly = true
            insert("[[")
        }

        private func updateCompletion() {
            guard let view = host?.textView, !view.hasMarkedText() else { closeCompletion(); return }
            let caret = view.selectedRange()
            let source = view.string as NSString
            guard caret.length == 0, caret.location <= source.length, style.acceptsCompletion(at: caret.location, in: source) else {
                closeCompletion()
                return
            }
            let line = source.lineRange(for: caret)
            let before = NSRange(location: line.location, length: caret.location - line.location)
            let opening = source.range(of: "[[", options: .backwards, range: before)
            guard opening.location != NSNotFound else { closeCompletion(); return }
            let query = source.substring(with: NSRange(location: NSMaxRange(opening), length: caret.location - NSMaxRange(opening)))
            guard query.rangeOfCharacter(from: CharacterSet(charactersIn: "[]#|\r\n")) == nil else { closeCompletion(); return }
            let tail = NSRange(location: caret.location, length: NSMaxRange(line) - caret.location)
            let closing = source.range(of: "]]", range: tail)
            let end = closing.location == NSNotFound ? caret.location : NSMaxRange(closing)
            let nextRange = NSRange(location: opening.location, length: end - opening.location)
            let items = LinkSuggestion.matches(query, model: editor.model, notesOnly: notesOnly)
            if items != suggestions || completionRange?.location != nextRange.location { selectedSuggestion = 0 }
            completionRange = nextRange
            suggestions = items
            displayCompletion()
        }

        private func selectSuggestion(_ index: Int) {
            selectedSuggestion = index
            displayCompletion()
        }

        private func displayCompletion() {
            guard completionRange != nil, let host else { return }
            let panel = LinkSuggestionView(items: suggestions, selected: selectedSuggestion) { [weak self] in self?.accept($0) }
            host.showSuggestion(panel, at: host.textView.selectedRange())
        }

        private func accept(_ suggestion: LinkSuggestion) {
            guard let range = completionRange else { return }
            closeCompletion()
            insert(suggestion, replacing: range)
        }

        private func insert(_ suggestion: LinkSuggestion, replacing range: NSRange) {
            host?.window?.makeFirstResponder(host?.textView)
            replace(range, with: "[[\(suggestion.target)]]")
        }

        private func closeCompletion() {
            completionRange = nil
            notesOnly = false
            suggestions = []
            selectedSuggestion = 0
            host?.hideSuggestion()
        }
    }
}

@MainActor
final class NoteEditorHost: NSView {
    let textView = NoteTextView(usingTextLayoutManager: true)
    private let scroll = NSScrollView()
    private var panel: NSHostingView<LinkSuggestionView>?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = textView
        addSubview(scroll)
        textView.configure()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    func showSuggestion(_ root: LinkSuggestionView, at range: NSRange) {
        guard let window else { return }
        let raw = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let caret = convert(window.convertFromScreen(raw), from: nil)
        guard caret.intersects(bounds) || bounds.contains(caret.origin) else { hideSuggestion(); return }
        let panel = panel ?? NSHostingView(rootView: root)
        panel.rootView = root
        if self.panel == nil { addSubview(panel, positioned: .above, relativeTo: scroll) }
        self.panel = panel
        let width = min(310, bounds.width - 16)
        guard width > 0 else { hideSuggestion(); return }
        let height = CGFloat(max(1, root.items.count)) * 34 + 10
        let x = min(max(8, caret.minX), bounds.width - width - 8)
        let down = caret.maxY + 5
        let y = down + height < bounds.height ? down : max(4, caret.minY - height - 5)
        panel.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    func hideSuggestion() {
        panel?.removeFromSuperview()
        panel = nil
    }
}

@MainActor
final class NoteTextView: NSTextView {
    var key: ((NSEvent) -> Bool)?
    var menuRequest: ((NSEvent) -> Void)?
    var commandClick: ((NSEvent) -> Bool)?
    var dismissCompletion: (() -> Void)?
    weak var markdownStyle: NoteEditorStyle?

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        insertionPointColor = NSColor(Theme.accent)
        selectedTextAttributes = [.backgroundColor: NSColor(Theme.accent.opacity(0.24)), .foregroundColor: NSColor(Theme.text)]
        textContainerInset = NSSize(width: 34, height: 26)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        typingAttributes = NoteEditorStyle.base
        defaultParagraphStyle = NoteEditorStyle.paragraph
        font = NoteEditorStyle.font
        textColor = NSColor(Theme.text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), key?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() || key?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        dismissCompletion?()
        if event.modifierFlags.contains(.control) { menuRequest?(event); return }
        if event.modifierFlags.contains(.command), commandClick?(event) == true { return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { menuRequest?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func scrollWheel(with event: NSEvent) {
        dismissCompletion?()
        super.scrollWheel(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layout = textLayoutManager, let manager = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let documentStart = manager.documentRange.location
        let first = manager.offset(from: documentStart, to: viewport.location)
        let last = manager.offset(from: documentStart, to: viewport.endLocation)
        for opening in markdownStyle?.liveSimOpeners ?? [] where opening.location >= first && opening.location < last {
            let line = (string as NSString).substring(with: opening).trimmingCharacters(in: .newlines)
            let end = opening.location + line.utf16.count
            guard let location = manager.location(documentStart, offsetBy: end),
                  let range = NSTextRange(location: location, end: location) else { continue }
            layout.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired, .upstreamAffinity]) { _, rect, _, _ in
                let origin = NSPoint(x: rect.maxX + self.textContainerOrigin.x, y: rect.minY + self.textContainerOrigin.y)
                NoteEditorStyle.drawChip(at: origin, in: self.visibleRect)
                return false
            }
        }
    }
}

struct LinkSuggestion: Equatable, Identifiable {
    let target: String
    let title: String
    let detail: String
    let sim: Bool
    var id: String { (sim ? "sim:" : "note:") + target }

    @MainActor
    static func matches(_ query: String, model: AppModel, notesOnly: Bool) -> [LinkSuggestion] {
        let notes = model.vault.allNotes.map { path in
            LinkSuggestion(target: NoteLinks.label(path), title: NoteLinks.title(path),
                           detail: (path as NSString).deletingLastPathComponent, sim: false)
        }
        let sims = notesOnly ? [] : model.library.entries.map {
            LinkSuggestion(target: $0.id, title: $0.title, detail: "Simulator", sim: true)
        }
        let needle = query.lowercased()
        return (notes + sims).compactMap { item -> (Int, LinkSuggestion)? in
            let title = item.title.lowercased()
            let target = item.target.lowercased()
            if needle.isEmpty { return (4, item) }
            if title == needle || target == needle { return (0, item) }
            if title.hasPrefix(needle) || target.hasPrefix(needle) { return (1, item) }
            if title.contains(needle) || target.contains(needle) { return (2, item) }
            var remaining = needle[...]
            for character in (title + " " + target) where remaining.first == character { remaining = remaining.dropFirst() }
            return remaining.isEmpty ? (3, item) : nil
        }
        .sorted { first, second in
            if first.0 != second.0 { return first.0 < second.0 }
            if first.1.sim != second.1.sim { return !first.1.sim }
            let order = first.1.title.localizedStandardCompare(second.1.title)
            return order == .orderedSame ? first.1.target < second.1.target : order == .orderedAscending
        }.prefix(7).map(\.1)
    }
}

struct LinkSuggestionView: View {
    let items: [LinkSuggestion]
    let selected: Int
    let accept: (LinkSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("No matching links").font(Theme.ui()).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 34).padding(.horizontal, 8)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { accept(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.sim ? "play.rectangle" : "doc.text")
                            .foregroundStyle(index == selected ? Theme.accent : Theme.muted)
                        Text(item.title).font(Theme.ui()).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(index == selected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .card(Theme.overlay)
    }
}
