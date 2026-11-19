import Foundation

/// One keyboard shortcut (or pointer gesture) the app answers to. `Shortcuts.all` is the single list:
/// the app menu's key equivalents, the stage's and players' key handlers, the ⌘K entries, the hover
/// hints, the in-window shortcut sheet and the README's keyboard table all read it, and the checks
/// keep it free of clashes.
public struct Shortcut: Identifiable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)

        /// In Apple's order: ⌃⌥⇧⌘.
        public var glyphs: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "")
                + (contains(.command) ? "⌘" : "")
        }
    }

    public enum Key: Hashable, Sendable {
        /// A character as typed, lowercase for letters (`k`, `\\`, `+`, `?`).
        case char(String)
        case space, escape, enter, left, right, up, down, home, end

        public var glyph: String {
            switch self {
            case .char(let c): c == "-" ? "−" : c.uppercased()
            case .space: "Space"
            case .escape: "Esc"
            case .enter: "↩"
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            case .home: "Home"
            case .end: "End"
            }
        }
    }

    /// Where a shortcut works, which is also how the shortcut sheet groups them.
    public enum Area: String, CaseIterable, Sendable {
        case anywhere = "Anywhere"
        case map = "Maps and simulators"
        case how = "How it works player"
        case journey = "Journey player"
        case notes = "Notes"
        case lists = "Palette and menus"
    }

    public let id: String
    public let area: Area
    public let title: String
    /// The keys, each doing the job (`← →` steps either way). Empty for a pointer gesture.
    public let keys: [Key]
    public let modifiers: Modifiers
    /// Shown instead of the keys: a pointer gesture ("Double-click") or a sequence ("Esc Esc").
    public let gesture: String?
    /// Matched like `keys` but not shown (`⌘=` zooms in like `⌘+`).
    public let alternates: [Key]

    public init(_ id: String, _ area: Area, _ title: String, keys: [Key] = [], _ modifiers: Modifiers = [],
                gesture: String? = nil, alternates: [Key] = []) {
        self.id = id; self.area = area; self.title = title; self.keys = keys; self.modifiers = modifiers
        self.gesture = gesture; self.alternates = alternates
    }

    /// What the sheet, hints, menus and README show: `⌥⌘L`, `← →`, `Double-click`.
    public var display: String { gesture ?? keys.map { modifiers.glyphs + $0.glyph }.joined(separator: " ") }

    /// A chord with ⌘, ⌃ or ⌥: these must be unique across the whole app.
    public var isChord: Bool { !modifiers.intersection([.command, .control, .option]).isEmpty }
}

public enum Shortcuts {
    // Anywhere (the app menu's key equivalents and the window's own keys).
    public static let palette = Shortcut("palette", .anywhere, "Command palette: find or run anything", keys: [.char("k")], .command)
    public static let switcher = Shortcut("switcher", .anywhere, "Open a note or simulator", keys: [.char("o")], .command)
    public static let newNote = Shortcut("new-note", .anywhere, "New note", keys: [.char("n")], .command)
    public static let search = Shortcut("search", .anywhere, "Search notes", keys: [.char("f")], [.shift, .command])
    public static let back = Shortcut("back", .anywhere, "Back", keys: [.char("[")], .command)
    public static let forward = Shortcut("forward", .anywhere, "Forward", keys: [.char("]")], .command)
    public static let sidebar = Shortcut("sidebar", .anywhere, "Show or hide the sidebar", keys: [.char("\\")], .command)
    public static let inspector = Shortcut("inspector", .anywhere, "Show or hide the inspector", keys: [.char("i")], [.option, .command])
    public static let graph = Shortcut("graph", .anywhere, "Open the graph", keys: [.char("g")], .command)
    public static let home = Shortcut("home", .anywhere, "Go home", keys: [.char("h")], [.shift, .command])
    public static let config = Shortcut("config", .anywhere, "Edit config.yaml", keys: [.char(",")], .command)
    public static let sheet = Shortcut("shortcuts", .anywhere, "Keyboard shortcuts", keys: [.char("/")], .command)
    public static let sheetKey = Shortcut("shortcuts-key", .anywhere, "Keyboard shortcuts, outside text fields", keys: [.char("?")])
    public static let hideWindow = Shortcut("hide-window", .anywhere, "Hide the window", keys: [.char("w")], .command)
    public static let escapeTwice = Shortcut("escape-twice", .anywhere, "Hide the window, when nothing is open", gesture: "Esc Esc")
    public static let hotkey = Shortcut("hotkey", .anywhere, "Show or hide Strata, from any app", gesture: "⌃⌥S")
    public static let quit = Shortcut("quit", .anywhere, "Quit Strata", keys: [.char("q")], .command)

    // Maps and simulators (the stage's key handler, SimWorkspace.key).
    public static let play = Shortcut("play", .map, "Play or pause", keys: [.space])
    public static let step = Shortcut("step", .map, "Step once (pauses)", keys: [.char(".")])
    public static let reset = Shortcut("reset", .map, "Reset the simulation", keys: [.char("r")], .command)
    public static let fit = Shortcut("fit", .map, "Fit the view", keys: [.char("0")], .command)
    public static let zoomIn = Shortcut("zoom-in", .map, "Zoom in", keys: [.char("+")], .command, alternates: [.char("=")])
    public static let zoomOut = Shortcut("zoom-out", .map, "Zoom out", keys: [.char("-")], .command, alternates: [.char("−")])
    public static let up = Shortcut("up", .map, "Up a level, out of a deep dive", keys: [.up], .command)
    public static let escape = Shortcut("escape", .map, "Close the innermost thing first", keys: [.escape])
    public static let dock = Shortcut("dock", .map, "Show or hide the dock", keys: [.char("j")], .command)
    public static let ask = Shortcut("ask", .map, "Ask the map", keys: [.char("l")], .command)
    public static let tidy = Shortcut("tidy", .map, "Tidy a manual layout", keys: [.char("l")], [.option, .command])
    public static let flip = Shortcut("flip", .map, "Run the map top to bottom or left to right", keys: [.char("v")], [.option, .command])
    public static let showAllLinks = Shortcut("show-all-links", .map, "Show all links, nothing faded",
                                              keys: [.char("a")], [.option, .command])
    public static let click = Shortcut("click", .map, "Select a card, link or flow", gesture: "Click")
    public static let doubleClick = Shortcut("double-click", .map, "Dive into a card's deep dive", gesture: "Double-click")
    public static let rightClick = Shortcut("right-click", .map, "The actions for anything on the stage", gesture: "Right-click")
    public static let drag = Shortcut("drag", .map, "Pan the stage", gesture: "Drag")
    public static let zoomGesture = Shortcut("zoom-gesture", .map, "Zoom, or pinch", gesture: "⌘ scroll")

    // How it works player (SimHowState.key).
    public static let howPlay = Shortcut("how-play", .how, "Play or pause", keys: [.space])
    public static let howStep = Shortcut("how-step", .how, "Step back or forward", keys: [.left, .right])
    public static let howDetail = Shortcut("how-detail", .how, "Open or close the step detail", keys: [.enter])
    public static let howEnds = Shortcut("how-ends", .how, "Jump to the start or the end", keys: [.home, .end])
    public static let howEscape = Shortcut("how-escape", .how, "Close the step detail, then the player", keys: [.escape])

    // Journey player (SimJourneyState.key).
    public static let journeyPlay = Shortcut("journey-play", .journey, "Play or pause", keys: [.space])
    public static let journeyStep = Shortcut("journey-step", .journey, "Previous or next step", keys: [.left, .right])
    public static let journeyEnds = Shortcut("journey-ends", .journey, "Jump to the start or the end", keys: [.home, .end])
    public static let journeyEscape = Shortcut("journey-escape", .journey, "Close the op detail, then the journey", keys: [.escape])

    // Notes (the editor's key handler).
    public static let reading = Shortcut("reading", .notes, "Edit or read the note", keys: [.char("e")], [.shift, .command])
    public static let bold = Shortcut("bold", .notes, "Bold", keys: [.char("b")], .command)
    public static let italic = Shortcut("italic", .notes, "Italic", keys: [.char("i")], .command)
    public static let code = Shortcut("code", .notes, "Inline code", keys: [.char("e")], .command)
    public static let find = Shortcut("find", .notes, "Find in the note", keys: [.char("f")], .command)
    public static let followLink = Shortcut("follow-link", .notes, "Follow a [[link]]", gesture: "⌘-click")

    // The palette, the switcher and in-window menus.
    public static let listMove = Shortcut("list-move", .lists, "Move through the results", keys: [.up, .down])
    public static let listOpen = Shortcut("list-open", .lists, "Run or open the highlighted one", keys: [.enter])
    public static let listClose = Shortcut("list-close", .lists, "Close", keys: [.escape])

    public static let all: [Shortcut] = [
        palette, switcher, newNote, search, back, forward, sidebar, inspector, graph, home, config, sheet, sheetKey,
        hideWindow, escapeTwice, hotkey, quit,
        play, step, reset, fit, zoomIn, zoomOut, up, escape, dock, ask, tidy, flip, showAllLinks,
        click, doubleClick, rightClick, drag, zoomGesture,
        howPlay, howStep, howDetail, howEnds, howEscape,
        journeyPlay, journeyStep, journeyEnds, journeyEscape,
        reading, bold, italic, code, find, followLink,
        listMove, listOpen, listClose,
    ]

    public static func id(_ id: String) -> Shortcut? { all.first { $0.id == id } }

    /// Pairs that answer to the same key: chords (⌘, ⌥, ⌃) anywhere in the app, plain keys within one area.
    /// The players' plain keys (Space, arrows, Esc) take over the stage's while they are open, by design.
    public static func clashes(in list: [Shortcut] = all) -> [(Shortcut, Shortcut)] {
        var found: [(Shortcut, Shortcut)] = []
        for (i, a) in list.enumerated() {
            for b in list[(i + 1)...] where a.modifiers == b.modifiers && (a.isChord || a.area == b.area) {
                let keysA = Set(a.keys + a.alternates), keysB = Set(b.keys + b.alternates)
                if !keysA.isDisjoint(with: keysB) { found.append((a, b)) }
            }
        }
        return found
    }
}
