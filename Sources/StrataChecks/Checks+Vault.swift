import Foundation
import StrataCore

@MainActor func vaultChecks() -> [CheckCase] {
    [
        CheckCase(name: "vault create and tree") {
            try withVault { vault in
                let folder = vault.createFolder(in: nil, name: "Systems")
                check(folder == "Systems", "create folder")
                check(vault.createFolder(in: nil, name: "Systems") == "Systems 2", "unique folder")
                check(vault.createNote(in: folder, name: "Orders.md", text: "draft") == "Systems/Orders.md", "create note")
                check(vault.createNote(in: folder, name: "Orders") == "Systems/Orders 2.md", "unique note")
                check(vault.createNote(in: nil, name: "A") == "A.md", "create at root")
                vault.write("Systems/Orders.md", "saved")
                vault.write("Sims/shop/orders/db.md", "node note")
                check(vault.nodeNotePath(sim: "shop", levelPath: ["orders"], node: "db") == "Sims/shop/orders/db.md", "node path")
                check(vault.hasNote("Sims/shop/orders/db.md"), "node indexed")
                check(vault.items.map(\.name) == ["Sims", "Systems", "Systems 2", "A"], "folders before notes, alphabetical")
                check(vault.items.first?.children.first?.children.first?.children.first?.name == "db", "nested tree")
                check(vault.read("Systems/Orders.md") == "saved", "updated on disk")
                check(!vault.save("../escaped.md", "no"), "path traversal rejected")
            }
        },
        CheckCase(name: "vault exact creation preserves files missing from the index") {
            try withVault { vault in
                let path = "Sims/shop/db.md"
                let url = vault.root.appendingPathComponent(path)
                check(vault.readNote(path) == .missing, "absent path is reported as missing")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "外部のメモ".write(to: url, atomically: true, encoding: .utf16)
                check(!vault.hasNote(path), "external file is ahead of the index")
                check(vault.readNote(path).text == "外部のメモ", "UTF-16 file opens")
                check(!vault.createNote(at: path, text: "template"), "exclusive creation rejects an existing note")
                let original = try String(contentsOf: url, encoding: .utf16)
                check(original == "外部のメモ", "original bytes are preserved")
                let blocked = "Blocked.md"
                try FileManager.default.createDirectory(at: vault.root.appendingPathComponent(blocked), withIntermediateDirectories: false)
                check(vault.readNote(blocked) == .unreadable, "existing non-file is reported as unreadable")
                check(!vault.createNote(at: blocked), "exclusive creation rejects an existing directory")
                let hidden = vault.root.appendingPathComponent("Unreadable.md")
                try Data("private".utf8).write(to: hidden)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
                if geteuid() != 0 {
                    let rescanned = Vault(root: vault.root)
                    check(rescanned.hasNote("Unreadable.md"), "an unreadable file remains in the tree")
                    check(rescanned.readNote("Unreadable.md") == .unreadable, "permission failure is not a missing note")
                }
                check(vault.createNote(at: "Empty.md"), "can create a missing note")
                check(vault.read("Empty.md") == "", "new empty note opens")
            }
        },
        CheckCase(name: "vault rejects edits based on a stale note version") {
            try withVault { vault in
                let path = "Versioned.md"
                let url = vault.root.appendingPathComponent(path)
                vault.write(path, "original")
                guard let version = vault.readNote(path).version else {
                    check(false, "the readable note has a version")
                    return
                }
                let encoded = try JSONEncoder().encode(version)
                let restored = try JSONDecoder().decode(NoteVersion.self, from: encoded)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let modified = attrs[.modificationDate] as? Date else {
                    check(false, "the readable note has a modification date")
                    return
                }
                try "external".write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                if case .changed(let disk) = vault.saveEdit(path, text: "local draft", basedOn: restored) {
                    check(disk.text == "external", "the content hash catches an external edit with the same mtime")
                } else {
                    check(false, "saving a stale draft reports a conflict")
                }
                check(vault.read(path) == "external", "the external note survives")
                if let current = vault.readNote(path).version {
                    try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(30)], ofItemAtPath: url.path)
                    if case .changed = vault.saveEdit(path, text: "local draft", basedOn: current) {} else {
                        check(false, "a new mtime also changes the version")
                    }
                }
            }
        },
        CheckCase(name: "vault resolve and backlinks") {
            try withVault { vault in
                vault.write("Group/Guide.md", "# First")
                vault.write("Guide.md", "# Root")
                vault.write("Source.md", """
                [[Group/Guide#First|group guide]] links to [[guide]].
                `[[Guide]]` is literal.
                """)
                check(vault.resolve(link: "Group/Guide#First|group guide") == "Group/Guide.md", "exact path with fragment and alias")
                check(vault.resolve(link: "gUiDe.MD") == "Guide.md", "folded note name")
                check(vault.resolve(link: "Group/guide") == nil, "full paths require exact spelling")
                check(vault.resolve(link: "checkout") == nil, "unresolved IDs remain available to the library")
                check(vault.backlinks(to: "Group/Guide.md") == ["Source.md"], "explicit path backlink")
                check(vault.backlinks(to: "Guide.md") == ["Source.md"], "bare name backlink")
                check(vault.outgoingLinks(from: "Source.md").map(\.label) == ["group guide", "guide"], "aliases and literal code")
                check(vault.backlinkExcerpt(from: "Source.md", to: "Guide.md")?.contains("links to") == true, "source excerpt")
            }
        },
        CheckCase(name: "vault rename and move rewrite links") {
            try withVault { vault in
                vault.write("Services/Old.md", "[[Old#Root]]")
                vault.write("Source.md", "🧪 [[ Old |alias]] [[Services/Old.md#Heading]]\r\n`[[Old]]`\r\n")
                vault.write("Archive/New.md", "another note")
                check(vault.rename("Services/Old.md", to: "New") == "Services/New.md", "rename")
                check(vault.read("Source.md") == "🧪 [[ Services/New |alias]] [[Services/New.md#Heading]]\r\n`[[Old]]`\r\n", "preserve aliases, headings, CRLF, and literal code")
                check(vault.read("Services/New.md") == "[[Services/New#Root]]", "update a self link")
                check(vault.createFolder(in: nil, name: "Current") == "Current", "create destination")
                check(vault.move("Services/New.md", toFolder: "Current") == "Current/New.md", "move note")
                check(vault.rename("Current", to: "Platform") == "Platform", "rename containing folder")
                check(vault.backlinks(to: "Platform/New.md") == ["Source.md"], "backlinks follow folder renames")
                check(vault.rename("Platform/New.md", to: "new") == "Platform/new.md", "rename case only")
                check(!vault.hasNote("Platform/New.md") && vault.hasNote("Platform/new.md"), "tree uses new spelling")
            }
        },
        CheckCase(name: "vault moves folders by drag and refuses to nest them in themselves") {
            try withVault { vault in
                vault.write("Team/Runbook.md", "# Runbook")
                vault.write("Team/Deep/Notes.md", "[[Runbook]]")
                vault.write("Index.md", "[[Team/Runbook]] [[Team/Deep/Notes|deep]]")
                check(vault.createFolder(in: nil, name: "Archive") == "Archive", "create destination")
                check(vault.move("Team", toFolder: "Team/Deep") == nil, "a folder cannot move into its own child")
                check(vault.move("Team", toFolder: "Team") == nil, "a folder cannot move into itself")
                check(vault.move("Team", toFolder: "Archive") == "Archive/Team", "move a folder")
                check(vault.hasNote("Archive/Team/Runbook.md") && vault.hasNote("Archive/Team/Deep/Notes.md"), "children move along")
                check(vault.read("Index.md") == "[[Archive/Team/Runbook]] [[Archive/Team/Deep/Notes|deep]]", "links follow the folder")
                vault.write("Runbook.md", "# Another")
                check(vault.move("Archive/Team/Runbook.md", toFolder: nil) == nil, "a name clash at the destination fails")
            }
        },
        CheckCase(name: "vault rename preserves resolution of unrelated short links") {
            try withVault { vault in
                vault.write("Z/Guide.md", "# Guide")
                vault.write("A/Runbook.md", "# Runbook")
                vault.write("Source.md", "[[Guide#Start|original]] [[Runbook]]")
                check(vault.resolve(link: "Guide") == "Z/Guide.md", "initial short link resolves to the guide")
                check(vault.rename("A/Runbook.md", to: "Guide") == "A/Guide.md", "rename to a colliding basename")
                check(vault.read("Source.md") == "[[Z/Guide#Start|original]] [[A/Guide]]", "both targets survive the collision")
                check(vault.backlinks(to: "Z/Guide.md") == ["Source.md"], "unrelated note retains its backlink")
                check(vault.backlinks(to: "A/Guide.md") == ["Source.md"], "renamed note retains its backlink")
            }
        },
        CheckCase(name: "vault rename reconciles unindexed backlinks") {
            try withVault { vault in
                vault.write("Tracked.md", "# Tracked")
                vault.write("Updated.md", "unrelated")
                let root = vault.root
                try "[[Tracked]]".write(to: root.appendingPathComponent("New.md"), atomically: true, encoding: .utf16)
                try "[[Tracked.md#Heading]]".write(to: root.appendingPathComponent("Updated.md"), atomically: true, encoding: .utf8)
                check(!vault.hasNote("New.md") && vault.backlinks(to: "Tracked.md").isEmpty, "both disk edits precede watcher delivery")
                check(vault.rename("Tracked.md", to: "Renamed") == "Renamed.md", "rename succeeds")
                check(vault.read("New.md") == "[[Renamed]]", "newly created backlink was rewritten")
                check(vault.read("Updated.md") == "[[Renamed.md#Heading]]", "new backlink in an existing note was rewritten")
                check(vault.backlinks(to: "Renamed.md") == ["New.md", "Updated.md"], "index reflects the rewrites")
            }
        },
        CheckCase(name: "vault search ranking and excerpts") {
            try withVault { vault in
                vault.write("A.md", "# A\n\(String(repeating: "short line padding ", count: 14))QUORUM stays visible")
                vault.write("Quorum.md", "Replication settings")
                let hits = vault.search("quorum")
                check(hits.map(\.path) == ["Quorum.md", "A.md"], "title first even when another note sorts earlier")
                check(hits.last?.line == 2 && hits.last?.excerpt.contains("QUORUM") == true, "1-based line and centered excerpt")
                check(vault.search("  ").isEmpty, "blank query")
            }
        },
        CheckCase(name: "vault background startup and search") {
            try withVault { fixture in
                fixture.write("A.md", String(repeating: "a quorum of replicas\n", count: 385))
                fixture.write("Quorum.md", "replication settings")
                let vault = Vault(root: fixture.root, loadImmediately: false)
                check(vault.allNotes.isEmpty, "deferred startup returns before reading the vault")
                vault.startWatching()
                vault.write("B.md", "a local edit during startup")
                check(waitForChange { vault.allNotes.count == 3 }, "worker publishes the full index and keeps the concurrent local write")

                var result: Result<[NoteSearchGroup], Error>?
                let cancelled = Task { try await vault.searchNotes("replicas") }
                cancelled.cancel()
                let latest = Task { @MainActor in
                    do {
                        do {
                            _ = try await cancelled.value
                            check(false, "a cancelled search must not return hits")
                        } catch is CancellationError {}
                        result = .success(try await vault.searchNotes("QUORUM"))
                    } catch { result = .failure(error) }
                }
                defer { latest.cancel() }
                check(waitForChange { result != nil }, "the latest query completes")
                if let groups = try result?.get() {
                    check(groups.map(\.path) == ["Quorum.md", "A.md"], "background search keeps title-first ranking")
                    check(groups.last?.hits.last?.line == 385, "search includes matches across multiple line batches")
                }
            }
        },
        CheckCase(name: "vault seed and embed extraction") {
            try withVault { vault in
                vault.seedIfEmpty()
                check(vault.hasNote("Welcome.md") && vault.hasNote("Sims/README.md"), "seed copied from resources")
                check(vault.embeddedSimIDs(in: "Welcome.md") == ["checkout"], "seed embed reference")
                vault.write("Fence.md", """
                ---
                title: '[[Welcome]]'
                ---
                ~~~strata
                sim: 'checkout' # local fixture
                view: [orders]
                ~~~
                ```yaml
                sim: ignored
                [[Welcome]]
                ```
                """)
                check(vault.embeddedSimIDs(in: "Fence.md") == ["checkout"], "only strata fences contribute")
                check(vault.outgoingLinks(from: "Fence.md").isEmpty, "frontmatter and code are excluded")
                vault.write("Welcome.md", "My notes")
                vault.seedIfEmpty()
                check(vault.read("Welcome.md") == "My notes", "existing vault is preserved")
            }
        },
        CheckCase(name: "vault trash") {
            try withVault { vault in
                let path = vault.createNote(in: nil, name: "Strata check \(UUID().uuidString)", text: "recoverable")
                do {
                    let destination = try vault.moveToTrash(path)
                    defer { if let destination { try? FileManager.default.removeItem(at: destination) } }
                    let recoverable = destination.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    check(recoverable == "recoverable", "note is recoverable in Trash")
                    check(!vault.hasNote(path) && vault.read(path) == nil, "removed from disk and index")
                } catch let error as CocoaError where error.code == .fileWriteNoPermission {
                    print("vault trash: macOS denied Trash access, checking that the note is preserved")
                    check(vault.hasNote(path) && vault.read(path) == "recoverable", "permission failure preserves the note")
                }
            }
        },
        CheckCase(name: "vault recursive external edits") {
            try withVault { vault in
                vault.startWatching()
                let folder = vault.root.appendingPathComponent("Agent/Labs")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let note = folder.appendingPathComponent("Trace.md")
                try "# Trace\n[[Welcome]]".write(to: note, atomically: true, encoding: .utf8)
                check(waitForChange { vault.hasNote("Agent/Labs/Trace.md") }, "noticed a note in a new nested folder")
                let revision = vault.revision
                try "Updated trace".write(to: note, atomically: true, encoding: .utf8)
                check(waitForChange { vault.revision > revision && vault.search("Updated trace").count == 1 }, "reindexed an external atomic replacement")
                try FileManager.default.removeItem(at: folder)
                check(waitForChange { !vault.hasNote("Agent/Labs/Trace.md") }, "noticed folder removal")
            }
        }
    ]
}

@MainActor private func withVault(_ run: (Vault) throws -> Void) throws {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("strata-vault-\(UUID().uuidString)")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let previous = ProcessInfo.processInfo.environment["STRATA_HOME"]
    setenv("STRATA_HOME", directory.path, 1)
    defer {
        if let previous { setenv("STRATA_HOME", previous, 1) }
        else { unsetenv("STRATA_HOME") }
        try? files.removeItem(at: directory)
    }
    try run(Vault(root: StrataPaths.vault))
}

@MainActor private func waitForChange(_ changed: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(0.5)
    while !changed(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.015))
    }
    return changed()
}
