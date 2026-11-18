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
