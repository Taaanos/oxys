import Foundation

/// Developer hook for the "never a stale frame" check (M-04): with `OXYS_FRAME_LOG=<file>` set, every frame
/// handed to the canvas appends `cursor<TAB>displayed<TAB>kind` (file names), so a held key can be audited
/// afterwards: the two columns must match on every line.
enum FrameLog {
    private static let handle: FileHandle? = {
        guard let path = DevHooks.environment["OXYS_FRAME_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func record(cursor: URL?, displayed: URL, kind: String) {
        guard let handle else { return }
        let line = "\(cursor?.lastPathComponent ?? "-")\t\(displayed.lastPathComponent)\t\(kind)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
