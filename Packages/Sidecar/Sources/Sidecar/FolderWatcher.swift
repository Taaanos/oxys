import CoreServices
import Foundation

/// A file-level FSEvents stream on one folder (M-10). It reports the names of the files that changed, batched
/// over a short latency, with the events of subfolders dropped. The handler runs on a private queue.
public final class FolderWatcher: @unchecked Sendable {
    private let folderPath: String
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "dev.oxys.folder-watcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// `latency` is how long FSEvents gathers changes before reporting; the acceptance bound is 1 s.
    public init(folder: URL, latency: TimeInterval = 0.2, handler: @escaping @Sendable ([String]) -> Void) {
        // FSEvents reports real paths (/private/var, not /var), so compare against the real path.
        if let real = realpath(folder.path, nil) {
            folderPath = String(cString: real)
            free(real)
        } else {
            folderPath = folder.path
        }
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.deliver(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [self.folderPath] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        lock.withLock { self.stream = stream }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops the stream and waits for a callback that is running. Safe to call twice; `deinit` calls it too.
    /// After it returns, no callback touches this object (B-4): the context holds no retain, so this wait
    /// is what keeps a running callback from using freed memory.
    public func stop() {
        guard let stream = lock.withLock({ () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Called from the queue itself (a handler that drops the last reference): waiting would deadlock.
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }

    deinit { stop() }

    private func deliver(_ paths: [String]) {
        var seen = Set<String>()
        var names: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            // Direct children only: subfolders are not part of the open folder.
            guard url.deletingLastPathComponent().path == folderPath, seen.insert(url.lastPathComponent).inserted else { continue }
            names.append(url.lastPathComponent)
        }
        if !names.isEmpty { handler(names) }
    }
}

/// The identity of a file as our own write left it: inode, modification time and size. An event for a file
/// that still has the signature we produced is our own write echoing back (M-10).
public struct FileSignature: Sendable, Hashable {
    public var inode: UInt64
    public var modified: Int64   // nanoseconds
    public var size: Int64

    public init?(of url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        inode = UInt64(info.st_ino)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        size = Int64(info.st_size)
    }
}
