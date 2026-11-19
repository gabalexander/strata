import Foundation
import StrataCore

// Hover hints (placement and timing) and the one list of keyboard shortcuts (docs/design.md, Hints and
// Shortcut sheet).
func uxChecks() -> [CheckCase] {
    let window = CGSize(width: 1150, height: 820)
    let bubble = CGSize(width: 180, height: 24)
    return [
        CheckCase(name: "hint sits below its control, centred, clear of it") {
            let anchor = CGRect(x: 500, y: 60, width: 28, height: 28)
            let frame = HintPlacement.frame(size: bubble, anchor: anchor, bounds: window)
            check(frame.minY == anchor.maxY + HintPlacement.gap, "below the control: \(frame)")
            check(abs(frame.midX - anchor.midX) < 0.5, "centred on the control: \(frame)")
            check(!frame.intersects(anchor), "never over the control")
        },
        CheckCase(name: "hint flips above a control at the bottom of the window") {
            let anchor = CGRect(x: 300, y: 790, width: 28, height: 22)
            let frame = HintPlacement.frame(size: bubble, anchor: anchor, bounds: window)
            check(frame.maxY == anchor.minY - HintPlacement.gap, "above the control: \(frame)")
            check(!frame.intersects(anchor), "never over the control")
        },
        CheckCase(name: "hint prefers above when asked, and falls back below") {
            let top = CGRect(x: 300, y: 10, width: 16, height: 16)
            let mid = CGRect(x: 300, y: 300, width: 16, height: 16)
            check(HintPlacement.frame(size: bubble, anchor: mid, bounds: window, preferAbove: true).maxY <= mid.minY, "above a stage glyph")
            check(HintPlacement.frame(size: bubble, anchor: top, bounds: window, preferAbove: true).minY >= top.maxY,
                  "below when there is no room above")
        },
        CheckCase(name: "hint is clamped to the window at its edges") {
            for anchor in [CGRect(x: 0, y: 40, width: 28, height: 28), CGRect(x: 1130, y: 40, width: 20, height: 28),
                           CGRect(x: 1140, y: 800, width: 10, height: 20), CGRect(x: -20, y: 400, width: 30, height: 10)] {
                let frame = HintPlacement.frame(size: bubble, anchor: anchor, bounds: window)
                let m = HintPlacement.margin
                check(frame.minX >= m - 0.01 && frame.maxX <= window.width - m + 0.01, "inside horizontally: \(frame) for \(anchor)")
                check(frame.minY >= m - 0.01 && frame.maxY <= window.height - m + 0.01, "inside vertically: \(frame) for \(anchor)")
                check(!frame.intersects(anchor), "clear of \(anchor): \(frame)")
            }
        },
        CheckCase(name: "hint goes beside a control as tall as the window, and shrinks to a tiny one") {
            let tall = CGRect(x: 100, y: 0, width: 40, height: window.height)
            let side = HintPlacement.frame(size: bubble, anchor: tall, bounds: window)
            check(side.minX >= tall.maxX, "right of a full-height control: \(side)")
            let tiny = HintPlacement.frame(size: CGSize(width: 900, height: 24), anchor: CGRect(x: 10, y: 10, width: 10, height: 10),
                                           bounds: CGSize(width: 300, height: 200))
            check(tiny.width <= 300 - HintPlacement.margin * 2 + 0.01, "never wider than the window: \(tiny)")
        },
        CheckCase(name: "hint timing: a rest first, then instant along a toolbar, then a rest again") {
            var timing = HintTiming()
            let t0 = Date(timeIntervalSinceReferenceDate: 1000)
            check(timing.wait(at: t0) == HintTiming.delay, "the first hint waits")
            timing.shown()
            check(timing.wait(at: t0) == 0, "while one shows, the next is instant")
            timing.hidden(at: t0)
            check(timing.wait(at: t0.addingTimeInterval(0.2)) == 0, "just after one hid, the next is instant")
            check(timing.wait(at: t0.addingTimeInterval(HintTiming.warmth + 0.1)) == HintTiming.delay, "later, it waits again")
            timing.shown()
            timing.cooled()
            check(timing.wait(at: t0) == HintTiming.delay, "a click or scroll cools hints down")
            check(HintTiming.delay >= 0.4 && HintTiming.delay <= 0.5, "the rest is 400–500 ms")
        },
        CheckCase(name: "shortcuts have unique ids and no clashes") {
            let ids = Shortcuts.all.map(\.id)
            check(Set(ids).count == ids.count, "duplicate ids: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
            for (a, b) in Shortcuts.clashes() { check(false, "\(a.display) is both “\(a.title)” and “\(b.title)”") }
            for shortcut in Shortcuts.all {
                check(!shortcut.display.isEmpty && !shortcut.title.isEmpty, "\(shortcut.id) shows keys and a title")
                check(shortcut.gesture != nil || !shortcut.keys.isEmpty, "\(shortcut.id) has keys or a gesture")
            }
        },
        CheckCase(name: "clash finder catches a repeated chord and a repeated plain key in one area") {
            let a = Shortcut("a", .map, "A", keys: [.char("l")], .command)
            let b = Shortcut("b", .notes, "B", keys: [.char("l")], .command)
            let c = Shortcut("c", .how, "C", keys: [.space])
            let d = Shortcut("d", .journey, "D", keys: [.space])
            let e = Shortcut("e", .how, "E", keys: [.space])
            check(Shortcuts.clashes(in: [a, b]).count == 1, "⌘L twice clashes across areas")
            check(Shortcuts.clashes(in: [c, d]).isEmpty, "Space in two players is fine")
            check(Shortcuts.clashes(in: [c, e]).count == 1, "Space twice in one area clashes")
        },
        CheckCase(name: "shortcut display follows Apple's modifier order") {
            check(Shortcuts.search.display == "⇧⌘F", "⇧⌘F, got \(Shortcuts.search.display)")
            check(Shortcuts.tidy.display == "⌥⌘L", "⌥⌘L, got \(Shortcuts.tidy.display)")
            check(Shortcuts.zoomOut.display == "⌘−", "⌘−, got \(Shortcuts.zoomOut.display)")
            check(Shortcuts.howStep.display == "← →", "← →, got \(Shortcuts.howStep.display)")
        },
        CheckCase(name: "README keyboard table lists every shortcut") {
            guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8),
                  let start = readme.range(of: "## Keyboard") else { check(false, "README.md with a Keyboard section, run from the repo root"); return }
            let rest = readme[start.upperBound...]
            let section = String(rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest)
            // Each area has its own table under a bold heading (**Notes**); a shortcut must be in its area's.
            for area in Shortcut.Area.allCases {
                guard let heading = section.range(of: "**\(area.rawValue)**") else {
                    check(false, "README's keyboard section has a **\(area.rawValue)** table"); continue
                }
                let line = section[heading.upperBound...]
                let afterLine = line.range(of: "\n").map { line[$0.upperBound...] } ?? line
                let table = afterLine.range(of: "\n**").map { afterLine[..<$0.lowerBound] } ?? afterLine
                for shortcut in Shortcuts.all where shortcut.area == area && shortcut.id != Shortcuts.hotkey.id {
                    check(table.contains(shortcut.display), "README's \(area.rawValue) table has \(shortcut.display) (\(shortcut.title))")
                }
            }
        },
    ]
}
