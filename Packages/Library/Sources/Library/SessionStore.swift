import CryptoKit
import Foundation

/// Per-folder session files in Application Support (V-15). One small JSON file per folder, plus the last folder
/// opened. Old files go: more than 90 days unused, or beyond the 500 most recent (V-15/Q3).
public final class SessionStore: Sendable {
    public static let maxAge: TimeInterval = 90 * 24 * 3600
    public static let maxCount = 500

    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `~/Library/Application Support/Oxys/Sessions`.
    public static var standard: SessionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(directory: support.appendingPathComponent("Oxys/Sessions", isDirectory: true))
    }

    private func file(forPath path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("s-\(digest).json")
    }

    private var lastFile: URL { directory.appendingPathComponent("last-folder.json") }

    private func read(_ url: URL) -> SessionState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SessionState.self, from: data), state.version == SessionState.currentVersion
        else { return nil }
        return state
    }

    private func isFresh(_ state: SessionState) -> Bool { now().timeIntervalSince(state.savedAt) <= Self.maxAge }

    /// The saved session for `folder`: first by path, then by volume and place on it. Nil when none, too old, or unreadable.
    public func load(for folder: URL) -> SessionState? {
        let identity = FolderIdentity(folder)
        if let state = read(file(forPath: identity.path)), isFresh(state) { return state }
        guard identity.volumeUUID != nil else { return nil }
        for url in sessionFiles() {
            if let state = read(url), isFresh(state), state.identity.matches(identity) { return state }
        }
        return nil
    }

    /// Writes the session (atomically) and prunes. Returns false when the disk refused; a session is a convenience, so callers ignore that.
    @discardableResult
    public func save(_ state: SessionState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: file(forPath: state.identity.path), options: .atomic)
        } catch { return false }
        setLastFolder(state.identity)
        if sessionFiles().count > Self.maxCount { prune() }
        return true
    }

    /// The folder open when the app last saved, if it is still there (a card that is gone is not reopened, V-15/Q2).
    public var lastFolder: URL? {
        guard let data = try? Data(contentsOf: lastFile), let identity = try? JSONDecoder().decode(FolderIdentity.self, from: data)
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: identity.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: identity.path, isDirectory: true)
    }

    /// Remembers the folder to reopen at the next launch.
    public func setLastFolder(_ identity: FolderIdentity) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(identity).write(to: lastFile, options: .atomic)
    }

    /// Forgets the last folder, for a folder that failed to open.
    public func clearLastFolder() { try? FileManager.default.removeItem(at: lastFile) }

    private func sessionFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("s-") && $0.pathExtension == "json" }
    }

    /// Removes sessions older than 90 days, then the oldest beyond 500. Called at launch and when a save passes the count.
    public func prune() {
        var kept: [(URL, Date)] = []
        for url in sessionFiles() {
            guard let state = read(url), isFresh(state) else { try? FileManager.default.removeItem(at: url); continue }
            kept.append((url, state.savedAt))
        }
        guard kept.count > Self.maxCount else { return }
        for (url, _) in kept.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxCount) { try? FileManager.default.removeItem(at: url) }
    }
}
