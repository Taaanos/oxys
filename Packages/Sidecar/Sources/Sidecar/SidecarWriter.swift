import Darwin
import Diagnostics
import Foundation

/// Where one photo's sidecar goes. The fallback is for a photo whose sidecar lookup has not finished: if the
/// primary does not exist but the fallback does, the fallback is the existing sidecar and gets patched.
public struct SidecarTarget: Sendable, Hashable {
    public var primary: URL
    public var fallback: URL?

    public init(primary: URL, fallback: URL? = nil) {
        self.primary = primary
        self.fallback = fallback
    }
}

public enum SidecarWriteOutcome: Sendable, Hashable {
    case written(URL)
    /// An undo took back the creation of a sidecar and the file we created was deleted (M-09/Q1).
    case removed(URL)
    /// The existing file could not be parsed or patched safely, so it was left untouched (M-08/Q3).
    case refused(URL, reason: String)
    case failed(URL, reason: String)
}

/// Read, patch, write: always from the file as it is now, so edits made by another program since we last
/// looked are kept. The write is atomic: a temporary file in the same folder, fsync, then rename over the original.
public enum SidecarWriter {
    /// Hidden temporary files carry this marker so a crash's leftovers can be found again (G-9).
    public static let tempMarker = ".oxys-tmp-"

    public static func write(_ edit: SidecarEdit, to target: SidecarTarget, now: Date = Date()) -> SidecarWriteOutcome {
        writeReturningBytes(edit, to: target, now: now).outcome
    }

    /// The file a target resolves to: the primary, or the fallback when only that one exists.
    static func resolve(_ target: SidecarTarget) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.primary.path), let fallback = target.fallback, fm.fileExists(atPath: fallback.path) {
            return fallback
        }
        return target.primary
    }

    /// Like `write`, also giving the bytes the file holds afterwards (nil when nothing was written).
    static func writeReturningBytes(_ edit: SidecarEdit, to target: SidecarTarget, now: Date) -> (outcome: SidecarWriteOutcome, bytes: Data?) {
        let url = resolve(target)
        let token = Perf.begin(.sidecarWrite)
        defer { Perf.end(token) }
        do {
            // A sidecar that is a link is never replaced or written through (B-1, Q-5): refuse, leave it alone.
            var linkInfo = stat()
            if lstat(url.path, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFLNK {
                return (.refused(url, reason: "Sidecar is a link"), nil)
            }
            let existing: Data?
            do { existing = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { existing = nil }
            if let existing {
                guard existing.count <= SidecarReader.maxBytes else { return (.refused(url, reason: "File is too large to be a sidecar"), nil) }
                do { _ = try XMPReader.parse(existing) } catch let error as XMPParseError { return (.refused(url, reason: error.message), nil) }
            }
            let patched: Data
            do { patched = try XMPPatcher.patch(existing, edit: edit, date: now) }
            catch let error as XMPPatchError { return (.refused(url, reason: error.message), nil) }
            if patched == existing { return (.written(url), patched) }
            try atomicWrite(patched, to: url)
            return (.written(url), patched)
        } catch {
            return (.failed(url, reason: error.localizedDescription), nil)
        }
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent)\(tempMarker)\(UUID().uuidString.prefix(8))")
        let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.uint16Value
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode ?? 0o644))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += n
                }
            }
            // F_FULLFSYNC makes the bytes durable before the rename makes them visible.
            if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
            // open() applies the umask; restore the original file's exact permissions.
            if let mode { fchmod(fd, mode_t(mode)) }
            close(fd)
            guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            close(fd)
            unlink(temp.path)
            throw error
        }
    }

    /// Deletes temporary files an earlier crash left in `folder`. Only ones older than a minute, so another
    /// running writer's file is never taken away.
    @discardableResult
    public static func removeStaleTemps(in folder: URL, olderThan age: TimeInterval = 60) -> Int {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                   options: [])) ?? []
        var removed = 0
        for url in entries where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.contains(tempMarker) {
            // Regular files only: this is the one delete that runs in a photographer's folder (B-6).
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < age { continue }
            if unlink(url.path) == 0 { removed += 1 }
        }
        return removed
    }
}
