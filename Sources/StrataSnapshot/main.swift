import AppKit
import SwiftUI
import StrataCore
import StrataUI

// Renders views with fixture data to PNGs, no screen permission needed (the real window is
// hidden from capture). `swift run StrataSnapshot <out-dir> [scene-name-substring]`.
// Each area adds scenes in its own file (Scenes+Sim.swift, Scenes+Notes.swift, Scenes+Shell.swift).

struct Scene {
    var name: String
    var size: CGSize
    /// true: render through a real NSHostingView in an offscreen window (needed for NSViewRepresentable
    /// such as the NSTextView editor). false: SwiftUI ImageRenderer (crisper, Canvas-friendly).
    var hosted = false
    /// Sim time to advance before rendering (scenes can also drive their models directly).
    var prepare: @MainActor () -> AnyView
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/snapshots"
let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

@MainActor func write(_ cg: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    let path = (outDir as NSString).appendingPathComponent(name + ".png")
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print(URL(fileURLWithPath: path).standardized.path)
}

@MainActor func render(_ s: Scene) {
    let view = s.prepare()
        .frame(width: s.size.width, height: s.size.height)
        .environment(\.colorScheme, .dark)
    if s.hosted {
        let host = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: s.size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: s.size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))   // let NSViewRepresentables lay out
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("failed: \(s.name)"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let cg = rep.cgImage { write(cg, s.name) } else { print("failed: \(s.name)") }
    } else {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { print("failed: \(s.name)"); return }
        write(cg, s.name)
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let all = shellScenes() + simScenes() + notesScenes()
    for s in all where filter.map({ s.name.contains($0) }) ?? true { render(s) }
}
