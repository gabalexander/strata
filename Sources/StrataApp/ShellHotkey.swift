import Carbon.HIToolbox
import Foundation

struct Hotkey {
    static let defaultSpec = "ctrl+option+s"
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    // Carbon registers ANSI virtual key positions, independent of the active input source.
    private static let keys: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    static func parse(_ spec: String) -> Hotkey? {
        let aliases = ["enter": "return", "esc": "escape", "backspace": "delete", "minus": "-"]
        var modifiers: UInt32 = 0
        var key: String?
        for part in spec.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            switch token {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "option", "alt", "opt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            default:
                guard key == nil else { return nil }
                key = aliases[token] ?? token
            }
        }
        guard modifiers != 0, let key, let keyCode = keys[key] else { return nil }
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        let names = ["space": "Space", "escape": "⎋", "return": "↩", "tab": "⇥", "delete": "⌫",
                     "left": "←", "right": "→", "down": "↓", "up": "↑"]
        return Hotkey(keyCode: keyCode, modifiers: modifiers, display: symbols + (names[key] ?? key.uppercased()))
    }
}

@MainActor
final class HotkeyRegistration {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(_ key: Hotkey, action: @escaping () -> Void) -> OSStatus {
        unregister()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x53545241, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let registration = Unmanaged<HotkeyRegistration>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { registration.action?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return status }
        let id = EventHotKeyID(signature: 0x53545241, id: 1) // STRA
        let registered = RegisterEventHotKey(key.keyCode, key.modifiers, id, target, 0, &registration)
        if registered == noErr { self.action = action } else { unregister() }
        return registered
    }

    func unregister() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        action = nil
    }
}
