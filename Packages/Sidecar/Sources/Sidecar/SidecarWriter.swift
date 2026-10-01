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
        let fm = FileManager.default
        var url = target.primary
        if !fm.fileExists(atPath: url.path), let fallback = target.fallback, fm.fileExists(atPath: fallback.path) { url = fallback }
        let token = Perf.begin(.sidecarWrite)
        defer { Perf.end(token) }
        do {
            let existing: Data?
            do { existing = try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { existing = nil }
            if let existing {
                guard existing.count <= SidecarReader.maxBytes else { return .refused(url, reason: "File is too large to be a sidecar") }
                do { _ = try XMPReader.parse(existing) } catch let error as XMPParseError { return .refused(url, reason: error.message) }
            }
            let patched: Data
            do { patched = try XMPPatcher.patch(existing, edit: edit, date: now) }
            catch let error as XMPPatchError { return .refused(url, reason: error.message) }
            if patched == existing { return .written(url) }
            try atomicWrite(patched, to: url)
            return .written(url)
        } catch {
            return .failed(url, reason: error.localizedDescription)
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
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [])) ?? []
        var removed = 0
        for url in entries where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.contains(tempMarker) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < age { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
