import AppKit
import SwiftUI
import StrataCore
import StrataUI

// Renders fixture views to PNG without activating or ordering a window on screen.
struct Scene {
    var name: String
    var size: CGSize
    /// Use an offscreen NSHostingView for scenes that use AppKit views or SwiftUI lifecycle.
    var hosted = false
    var prepare: @MainActor () -> AnyView
}

private enum SnapshotError: LocalizedError {
    case noImage(String)
    case noScenes(String)

    var errorDescription: String? {
        switch self {
        case .noImage(let scene): "Could not render \(scene)."
        case .noScenes(let filter): "No scenes match \(filter)."
        }
    }
}

let arguments = CommandLine.arguments
let outDir = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "build/snapshots", isDirectory: true)
let filter = arguments.count > 2 ? arguments[2] : nil

@MainActor private func write(_ image: CGImage, _ name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.noImage(name) }
    let url = outDir.appendingPathComponent(name + ".png")
    try png.write(to: url, options: .atomic)
    print(url.standardized.path)
}

@MainActor private func render(_ scene: Scene) throws {
    let view = scene.prepare()
        .frame(width: scene.size.width, height: scene.size.height)
        .environment(\.colorScheme, .dark)

    if scene.hosted {
        let rect = NSRect(origin: .zero, size: scene.size)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.18)) // Let hosted views and layout tasks settle.
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SnapshotError.noImage(scene.name) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { throw SnapshotError.noImage(scene.name) }
        try write(image, scene.name)
    } else {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw SnapshotError.noImage(scene.name) }
        try write(image, scene.name)
    }
}

MainActor.assumeIsolated {
    do {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let scenes = (shellScenes() + simScenes() + opsScenes() + pressureScenes() + dataScenes() + notesScenes() + manifestScenes()
            + howScenes() + enumScenes() + sqlScenes() + askScenes()).filter { scene in
            filter.map { scene.name.contains($0) } ?? true
        }
        guard !scenes.isEmpty else { throw SnapshotError.noScenes(filter ?? "") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for scene in scenes { try render(scene) }
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
