import CoreServices
import Foundation

/// One file-level stream covers the whole vault, including folders created after startup.
final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private var fallback: DispatchSourceTimer?
    private let receive: @MainActor ([String], Bool) -> Void

    init(root: URL, receive: @escaping @MainActor ([String], Bool) -> Void) {
        self.receive = receive
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let options = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        if let stream = FSEventStreamCreate(nil, { _, context, count, events, flags, _ in
            guard let context else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(context).takeUnretainedValue()
            let paths = Unmanaged<NSArray>.fromOpaque(events).takeUnretainedValue() as? [String] ?? []
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            let fullScan = (0..<count).contains { flags[$0] & rescan != 0 }
            MainActor.assumeIsolated { watcher.receive(paths, fullScan) }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(options)) {
            FSEventStreamSetDispatchQueue(stream, .main)
            if FSEventStreamStart(stream) {
                self.stream = stream
                return
            }
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        // Some sandboxes deny access to the FSEvents daemon. Compare metadata on a
        // worker queue in that environment so only changed content reaches the index.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "strata.vault.metadata"))
        var previous: [String: Stamp]?
        timer.setEventHandler {
            let current = Self.metadata(in: root)
            let baseline = previous
            previous = current
            guard let baseline else {
                DispatchQueue.main.async { receive([], true) }
                return
            }
            let removed = Set(baseline.keys).subtracting(current.keys)
            let changed = current.keys.filter { current[$0] != baseline[$0] }
            let paths = Array(removed) + changed
            guard !paths.isEmpty else { return }
            DispatchQueue.main.async { receive(paths, false) }
        }
        timer.schedule(deadline: .now() + .milliseconds(180), repeating: .milliseconds(180), leeway: .milliseconds(20))
        fallback = timer
        timer.resume()
    }

    deinit {
        fallback?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private enum Stamp: Equatable {
        case folder
        case note(Date?, Int?, NSObject?)
    }

    private static func metadata(in root: URL) -> [String: Stamp] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        guard let contents = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                             options: .skipsHiddenFiles) else { return [:] }
        var result: [String: Stamp] = [:]
        for case let url as URL in contents {
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                contents.skipDescendants()
                continue
            }
            if values.isDirectory == true { result[url.path] = .folder }
            else if values.isRegularFile == true, url.pathExtension.lowercased() == "md" {
                result[url.path] = .note(values.contentModificationDate, values.fileSize, values.fileResourceIdentifier as? NSObject)
            }
        }
        return result
    }
}
