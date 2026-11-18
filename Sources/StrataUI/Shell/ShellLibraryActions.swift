import AppKit
import StrataCore

@MainActor
struct LibraryActions {
    let model: AppModel

    func menu(for entry: Library.Entry) -> [MenuItem] {
        var items = [
            MenuItem.header(entry.title),
            MenuItem("Open", icon: "arrow.up.right", shortcut: "↩", enabled: entry.manifest != nil) {
                model.open(.sim(entry.id, path: []))
            }
        ]
        if entry.builtIn {
            items.append(MenuItem("Duplicate to edit", icon: "plus.square.on.square") {
                guard let copy = model.library.duplicate(entry.id) else {
                    model.overlays.toast("Could not duplicate \(entry.title)")
                    return
                }
                model.openCode(copy.path, repo: nil)
            })
        }
        items += [
            MenuItem("Reveal file", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) },
            .separator,
            MenuItem("Copy ID", icon: "number") { copy(entry.id, message: "Copied ID") },
            MenuItem("Copy open command", icon: "terminal") {
                let supported = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
                let argument = entry.id.unicodeScalars.allSatisfy(supported.contains)
                    ? entry.id : "'" + entry.id.replacingOccurrences(of: "'", with: "'\\''") + "'"
                copy("strata open \(argument)", message: "Copied open command")
            }
        ]
        if !entry.builtIn {
            items += [.separator, MenuItem("Move to Trash", icon: "trash", role: .destructive) { trash(entry) }]
        }
        return items
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        model.overlays.toast(message)
    }

    private func trash(_ entry: Library.Entry) {
        guard let current = model.library.entries.first(where: { $0.url == entry.url && $0.id == entry.id }),
              !current.builtIn else {
            model.overlays.toast("The library entry changed")
            return
        }
        do {
            try FileManager.default.trashItem(at: current.url, resultingItemURL: nil)
            model.library.reload()
            if model.library.manifest(entry.id) == nil, case .sim(let id, _) = model.route, id == entry.id {
                model.replace(.home)
            }
            model.overlays.toast("Moved \(entry.title) to Trash")
        } catch {
            model.overlays.toast(error.localizedDescription)
        }
    }
}
