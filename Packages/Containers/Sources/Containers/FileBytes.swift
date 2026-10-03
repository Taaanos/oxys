import Foundation

/// Loads a file's bytes without exposing the process to SIGBUS (B-3).
///
/// A memory-mapped file that disappears under the mapping (a card pulled out, a network share lost, a file
/// truncated by another program) faults the process on the next touch of a missing page. A plain read fails with
/// an error instead. So a file is mapped only when its volume is internal and fixed; on anything removable,
/// ejectable, remote or unknown, the whole file is read into memory once. The cost is one full read of the file
/// from a slow volume; the benefit is that a pulled card shows an error, never a crash.
public enum FileBytes {
    /// The bytes of `url`, mapped when that is safe, read otherwise. Throws when the file cannot be read.
    public static func load(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: isSafeToMap(url) ? .alwaysMapped : [])
    }

    /// True only for a local, internal volume that cannot be ejected. Any value the system does not report counts as unsafe.
    public static func isSafeToMap(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        return values.volumeIsLocal == true && values.volumeIsInternal == true
            && values.volumeIsRemovable != true && values.volumeIsEjectable != true
    }
}
