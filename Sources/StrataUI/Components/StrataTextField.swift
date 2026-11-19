import AppKit
import SwiftUI

/// A plain single-line field whose editing commands stay in the window.
@MainActor
struct StrataTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    let overlays: Overlays
    var size: CGFloat = 13
    var weight: NSFont.Weight = .regular
    var placeholderColor: Color?
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] field in
            coordinator?.reportFocus(of: field)
        }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.configuration = self
        field.overlays = overlays
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        field.font = font
        field.textColor = NSColor(Theme.text)
        let promptColor = placeholderColor.map(NSColor.init) ?? .placeholderTextColor
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: promptColor,
        ])
        field.setAccessibilityLabel(placeholder)
        field.setText(text)

        if focused, !field.isFocused {
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, coordinator?.configuration.focused == true, !field.isFocused else { return }
                field.selectText(nil)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Field, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var configuration: StrataTextField

        init(_ configuration: StrataTextField) { self.configuration = configuration }

        func reportFocus(of field: Field) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                if configuration.focused != field.isFocused { configuration.focused = field.isFocused }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? Field, let editor = field.currentEditor() else { return }
            configuration.text = editor.string
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                guard let submit = configuration.onSubmit else { return false }
                configuration.text = textView.string
                submit()
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape leaves the field first (the innermost thing), so the next one reaches the screen.
                guard let escape = configuration.onEscape else {
                    control.window?.makeFirstResponder(nil)
                    if let field = control as? Field { reportFocus(of: field) }
                    return true
                }
                escape()
            default: return false
            }
            return true
        }
    }

    final class Field: NSTextField {
        private lazy var editor: FieldEditor = {
            let editor = FieldEditor(frame: .zero)
            editor.field = self
            editor.isFieldEditor = true
            editor.configure()
            return editor
        }()
        weak var overlays: Overlays?
        var focusChanged: ((Field) -> Void)?
        var isFocused: Bool { window?.firstResponder === editor }

        init() {
            super.init(frame: .zero)
            cell = FieldCell(textCell: "")
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            isEditable = true
            isSelectable = true
            isAutomaticTextCompletionEnabled = false
            allowsCharacterPickerTouchBarItem = false
            cell?.usesSingleLineMode = true
            cell?.isScrollable = true
            cell?.wraps = false
            cell?.allowsUndo = true
        }

        required init?(coder: NSCoder) { nil }

        func setText(_ text: String) {
            if isFocused {
                if editor.string != text, !editor.hasMarkedText() { editor.string = text }
            } else if stringValue != text {
                stringValue = text
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            showEditingMenu(for: event)
            return nil
        }

        override func rightMouseDown(with event: NSEvent) { showEditingMenu(for: event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { showEditingMenu(for: event) }
            else { super.mouseDown(with: event) }
        }

        func showEditingMenu(for event: NSEvent) {
            guard let overlays, let point = event.contentLocation(in: window) else { return }
            if !isFocused { window?.makeFirstResponder(self) }
            guard isFocused else { return }
            let hasSelection = editor.selectedRange().length > 0
            let canPaste = NSPasteboard.general.availableType(from: [.string]) != nil
            overlays.showMenu([
                MenuItem("Cut", icon: "scissors", shortcut: "⌘X", enabled: hasSelection) { [weak editor] in editor?.cut(nil) },
                MenuItem("Copy", icon: "doc.on.doc", shortcut: "⌘C", enabled: hasSelection) { [weak editor] in editor?.copy(nil) },
                MenuItem("Paste", icon: "clipboard", shortcut: "⌘V", enabled: canPaste) { [weak editor] in editor?.paste(nil) },
                MenuItem("Select All", icon: "selection.pin.in.out", shortcut: "⌘A", enabled: !editor.string.isEmpty) { [weak editor] in
                    editor?.selectAll(nil)
                },
            ], at: point)
        }

        private final class FieldCell: NSTextFieldCell {
            override func fieldEditor(for controlView: NSView) -> NSTextView? {
                (controlView as? Field)?.editor
            }

            override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
                let editor = super.setUpFieldEditorAttributes(textObj)
                (editor as? FieldEditor)?.configure()
                return editor
            }
        }
    }

    private final class FieldEditor: NSTextView {
        weak var field: Field?

        func configure() {
            writingToolsBehavior = .none
            insertionPointColor = NSColor(Theme.accent)
            isContinuousSpellCheckingEnabled = false
            isGrammarCheckingEnabled = false
            isAutomaticSpellingCorrectionEnabled = false
            isAutomaticQuoteSubstitutionEnabled = false
            isAutomaticDashSubstitutionEnabled = false
            isAutomaticTextReplacementEnabled = false
            isAutomaticTextCompletionEnabled = false
            isAutomaticLinkDetectionEnabled = false
            isAutomaticDataDetectionEnabled = false
            allowsCharacterPickerTouchBarItem = false
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted, let field { field.focusChanged?(field) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted, let field { field.focusChanged?(field) }
            return accepted
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            field?.showEditingMenu(for: event)
            return nil
        }

        override func rightMouseDown(with event: NSEvent) { field?.showEditingMenu(for: event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { field?.showEditingMenu(for: event) }
            else { super.mouseDown(with: event) }
        }

        override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                     returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
        override func quickLook(with event: NSEvent) {}
        override func quickLookPreviewItems(_ sender: Any?) {}
        override func showGuessPanel(_ sender: Any?) {}
        override func orderFrontSubstitutionsPanel(_ sender: Any?) {}
        override func complete(_ sender: Any?) {}
    }
}
