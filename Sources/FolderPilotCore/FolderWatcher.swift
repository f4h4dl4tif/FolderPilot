import CoreServices
import Foundation

/// Thin wrapper over FSEvents that reports file paths that were created, renamed into place, or modified.
public final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let handler: ([String]) -> Void

    public init(queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    public func start(paths: [String]) {
        stop()
        let existing = paths.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] else { return }
            let interesting = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
            var result: [String] = []
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, f & interesting != 0 {
                    result.append(paths[i])
                }
            }
            if !result.isEmpty { watcher.handler(result) }
        }

        let createFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil, callback, &context, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, createFlags)
        else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
