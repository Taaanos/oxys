import Darwin
import Foundation

/// Copies a file's own attributes onto its extracted copy (V-13): extended attributes (Finder tags and comments,
/// where-from, quarantine, resource fork), permissions, and the creation and modification dates.
public enum FileAttributes {
    /// Returns what could not be copied, in words; empty when everything was.
    public static func copy(from source: URL, to target: URL) -> [String] {
        var failed: [String] = []
        // Extended attributes first: copying them can change the times, so the dates come last.
        if copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_XATTR)) != 0 { failed.append("extended attributes") }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else {
            return failed + ["permissions and dates"]
        }
        var wanted: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.posixPermissions, .creationDate, .modificationDate] {
            if let value = attributes[key] { wanted[key] = value }
        }
        do { try FileManager.default.setAttributes(wanted, ofItemAtPath: target.path) } catch { failed.append("permissions and dates") }
        return failed
    }
}
