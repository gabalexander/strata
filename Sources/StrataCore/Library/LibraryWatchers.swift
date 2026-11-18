import Darwin
import Foundation

struct LibraryInventory: Equatable {
    let builtIn: [URL]
    let users: [URL]
    private let stamps: [URL: FileStamp]

    init(builtIn: URL?, dirs: [URL]) {
        var seen: Set<URL> = []
        self.builtIn = builtIn.map { Self.files(in: [$0], seen: &seen) } ?? []
        self.users = Self.files(in: dirs, seen: &seen)
        self.stamps = Dictionary(uniqueKeysWithValues: (self.builtIn + users).map { ($0, FileStamp($0)) })
    }

    private static func files(in directories: [URL], seen: inout Set<URL>) -> [URL] {
        directories.flatMap { directory in
            ((try? manifests(in: directory)) ?? []).filter { seen.insert($0).inserted }
        }
    }

    static func manifests(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .filter { url in
                ["yaml", "yml", "json"].contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }
}

private struct FileStamp: Equatable {
    let inode: UInt64
    let device: Int32
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init(_ url: URL) {
        var info = stat()
        _ = url.withUnsafeFileSystemRepresentation { stat($0, &info) }
        inode = info.st_ino
        device = info.st_dev
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
    }

    func sameFile(as other: Self) -> Bool { inode == other.inode && device == other.device }
}

@MainActor
final class LibraryWatchers {
    private let directories: [URL]
    private let changed: @MainActor () -> Void
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var sources: [URL: (stamp: FileStamp, source: DispatchSourceFileSystemObject)] = [:]
    private var pending: DispatchWorkItem?

    init(directories: [URL], changed: @escaping @MainActor () -> Void) {
        self.directories = directories
        self.changed = changed
    }

    func start() {
        attach()
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.attach()
            if self?.pending == nil { self?.scheduleRescan() }
        }
        timer.activate()
    }

    deinit {
        pending?.cancel()
        timer.cancel()
        for watch in sources.values { watch.source.cancel() }
    }

    private func attach() {
        for directory in directories {
            let stamp = FileStamp(directory)
            if let watch = sources[directory] {
                if stamp.sameFile(as: watch.stamp) { continue }
                watch.source.cancel()
                sources[directory] = nil
            }
            let fd = directory.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.open($0, O_EVTONLY | O_CLOEXEC) } ?? -1
            }
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke, .link], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRescan() }
            source.setCancelHandler { close(fd) }
            sources[directory] = (stamp, source)
            source.activate()
        }
    }

    private func scheduleRescan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.changed()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }
}
