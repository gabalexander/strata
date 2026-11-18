import AppKit
import SwiftUI
import StrataCore

@MainActor
final class NoteEditorStyle {
    private enum Kind: Hashable { case frontmatter, fence(String) }

    private struct Block: Hashable {
        let kind: Kind
        let range: NSRange
        let opening: NSRange
        let closing: NSRange?
    }

    static let font = NSFont.systemFont(ofSize: 15)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.55
        return style
    }()
    static var base: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor(Theme.text), .paragraphStyle: paragraph]
    }

    private static let strong = try! NSRegularExpression(pattern: #"(?<!\\)(?:\*\*(?=\S).+?(?<=\S)\*\*|__(?=\S).+?(?<=\S)__)"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![\\*])\*(?![\s*])[^*]+?(?<!\s)\*(?!\*)|(?<![\\\w_])_(?![\s_])[^_]+?(?<!\s)_(?![\w_])"#)
    private static let heading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})[ \t]+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)
    private static let embedChip = "live sim  ▶"

    private var blocks: [Block] = []
    var liveSimOpeners: [NSRange] { blocks.filter { $0.kind == .fence("strata") }.map(\.opening) }

    func reset(_ storage: NSTextStorage) {
        let source = storage.string as NSString
        blocks = scan(source)
        restyle(NSRange(location: 0, length: source.length), in: storage)
    }

    func update(_ storage: NSTextStorage, edited: NSRange, delta: Int) {
        let source = storage.string as NSString
        guard NSMaxRange(edited) <= source.length else { reset(storage); return }
        let oldEdit = NSRange(location: edited.location, length: max(0, edited.length - delta))
        let shifted = blocks.map { block in
            Block(kind: block.kind, range: shift(block.range, across: oldEdit, delta: delta),
                  opening: shift(block.opening, across: oldEdit, delta: delta),
                  closing: block.closing.map { shift($0, across: oldEdit, delta: delta) })
        }
        let before = max(0, edited.location - 1)
        let after = min(source.length, NSMaxRange(edited) + 1)
        var affected = source.lineRange(for: NSRange(location: before, length: after - before))
        let oldBounds = NSRange(location: max(0, oldEdit.location - 1), length: oldEdit.length + (oldEdit.location > 0 ? 2 : 1))
        let touchedBoundary = blocks.contains { block in
            NSIntersectionRange(oldBounds, block.opening).length > 0
                || block.closing.map { NSIntersectionRange(oldBounds, $0).length > 0 } == true
        }
        let hasBoundary = source.substring(with: affected).components(separatedBy: .newlines).contains {
            NoteSyntax.fence(in: $0) != nil || $0.trimmingCharacters(in: .whitespaces) == "---"
        }
        if touchedBoundary || hasBoundary {
            blocks = scan(source)
            for block in Set(shifted).symmetricDifference(Set(blocks)) {
                affected = NSUnionRange(affected, block.range)
            }
            affected = NSIntersectionRange(affected, NSRange(location: 0, length: source.length))
        } else {
            blocks = shifted
        }
        restyle(affected, in: storage)
    }

    func wikiLink(at index: Int, in source: NSString) -> NoteSyntax.WikiLink? {
        guard index < source.length, block(at: index) == nil else { return nil }
        let range = source.lineRange(for: NSRange(location: index, length: 0))
        return NoteSyntax.wikiLinks(in: source.substring(with: range)).first { NSLocationInRange(index - range.location, $0.range) }
    }

    func acceptsCompletion(at index: Int, in source: NSString) -> Bool {
        guard block(at: index) == nil else { return false }
        let range = source.lineRange(for: NSRange(location: index, length: 0))
        return !NoteSyntax.inlineCode(in: source.substring(with: range)).contains { NSLocationInRange(index - range.location, $0) }
    }

    func allowsListEditing(at index: Int) -> Bool { block(at: index) == nil }

    static func drawChip(at end: NSPoint, in visible: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.accent)]
        let size = Self.embedChip.size(withAttributes: attributes)
        let origin = NSPoint(x: end.x + 12, y: end.y - 2)
        let rect = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 4)
        guard rect.maxX < visible.maxX, rect.intersects(visible) else { return }
        NSColor(Theme.accent.opacity(0.12)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()
        Self.embedChip.draw(at: NSPoint(x: origin.x + 6, y: origin.y + 2), withAttributes: attributes)
    }

    private func scan(_ source: NSString) -> [Block] {
        guard source.length > 0 else { return [] }
        let whole = NSRange(location: 0, length: source.length)
        var blocks: [Block] = []
        var start = 0
        let first = source.lineRange(for: NSRange(location: 0, length: 0))
        if source.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines) == "---", NSMaxRange(first) < source.length {
            let remaining = NSRange(location: NSMaxRange(first), length: source.length - NSMaxRange(first))
            source.enumerateSubstrings(in: remaining, options: .byLines) { line, _, range, stop in
                guard line?.trimmingCharacters(in: .whitespaces) == "---" else { return }
                blocks.append(Block(kind: .frontmatter, range: NSUnionRange(first, range), opening: first, closing: range))
                start = NSMaxRange(range)
                stop.pointee = true
            }
        }
        var opening: (fence: NoteSyntax.Fence, range: NSRange)?
        source.enumerateSubstrings(in: NSRange(location: start, length: whole.length - start), options: .byLines) { line, _, range, _ in
            guard let line, let fence = NoteSyntax.fence(in: line) else { return }
            if let current = opening {
                if fence.closes(current.fence) {
                    blocks.append(Block(kind: .fence(current.fence.language), range: NSUnionRange(current.range, range),
                                        opening: current.range, closing: range))
                    opening = nil
                }
            } else {
                opening = (fence, range)
            }
        }
        if let opening {
            blocks.append(Block(kind: .fence(opening.fence.language),
                                range: NSRange(location: opening.range.location, length: source.length - opening.range.location),
                                opening: opening.range, closing: nil))
        }
        return blocks
    }

    private func shift(_ range: NSRange, across edited: NSRange, delta: Int) -> NSRange {
        let start = range.location
        let end = NSMaxRange(range)
        if end <= edited.location { return range }
        if start >= NSMaxRange(edited) { return NSRange(location: start + delta, length: range.length) }
        let first = min(start, edited.location)
        return NSRange(location: first, length: max(0, max(end, NSMaxRange(edited)) + delta - first))
    }

    private func block(at index: Int) -> Block? {
        blocks.first { NSLocationInRange(index, $0.range) }
    }

    private func restyle(_ range: NSRange, in storage: NSTextStorage) {
        guard range.length > 0 else { return }
        let source = storage.string as NSString
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(Self.base, range: range)
        source.enumerateSubstrings(in: range, options: .byLines) { line, textRange, wholeLine, _ in
            guard let line, textRange.length > 0 else { return }
            if let block = self.block(at: textRange.location) {
                switch block.kind {
                case .frontmatter:
                    storage.addAttributes([.font: Self.codeFont, .foregroundColor: NSColor(Theme.faint)], range: textRange)
                case .fence:
                    let marker = block.opening.location == wholeLine.location || block.closing?.location == wholeLine.location
                    storage.addAttributes([.font: Self.codeFont, .foregroundColor: NSColor(marker ? Theme.faint : Theme.text),
                                           .backgroundColor: NSColor(Theme.raised)], range: textRange)
                }
            } else {
                self.style(line, in: textRange, storage: storage)
            }
        }
    }

    private func style(_ line: String, in range: NSRange, storage: NSTextStorage) {
        let localRange = NSRange(location: 0, length: range.length)
        func absolute(_ local: NSRange) -> NSRange { NSRange(location: range.location + local.location, length: local.length) }
        func dim(_ local: NSRange) {
            storage.addAttribute(.foregroundColor, value: NSColor(Theme.faint), range: absolute(local))
        }

        if let heading = Self.heading.firstMatch(in: line, range: localRange) {
            let level = heading.range(at: 1).length
            let size: CGFloat = level == 1 ? 28 : level == 2 ? 21 : 17
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: range)
            dim(heading.range(at: 1))
        } else if NoteDocument.isRule(line) {
            dim(localRange)
        } else if let quote = Self.quote.firstMatch(in: line, range: localRange) {
            storage.addAttribute(.foregroundColor, value: NSColor(Theme.muted), range: range)
            dim(quote.range)
        } else if let list = NoteDocument.listMatch(in: line) {
            dim(list.range(at: 2))
            let check = list.range(at: 3)
            if check.location != NSNotFound { dim(NSRange(location: check.location - 1, length: 3)) }
        }

        let codes = NoteSyntax.inlineCode(in: line)
        let links = NoteSyntax.wikiLinks(in: line)
        let protected = codes + links.map(\.range)
        for (pattern, trait) in [(Self.strong, NSFontTraitMask.boldFontMask), (Self.emphasis, .italicFontMask)] {
            for match in pattern.matches(in: line, range: localRange) where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                let current = storage.attribute(.font, at: range.location + match.range.location, effectiveRange: nil) as? NSFont ?? Self.font
                storage.addAttribute(.font, value: NSFontManager.shared.convert(current, toHaveTrait: trait), range: absolute(match.range))
            }
        }
        for code in codes {
            storage.addAttributes([.font: Self.codeFont, .backgroundColor: NSColor(Theme.raised)], range: absolute(code))
        }
        for link in links {
            storage.addAttribute(.foregroundColor, value: NSColor(Theme.accent), range: absolute(link.range))
        }
    }
}
