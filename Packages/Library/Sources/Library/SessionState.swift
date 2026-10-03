import Foundation

/// Which folder a session belongs to (V-15/Q1). The path is the main key; the volume's UUID and the path below the
/// volume's root find the folder again when a card is renamed, so it is not "a new folder".
public struct FolderIdentity: Sendable, Equatable, Codable {
    public var path: String
    public var volumeUUID: String?
    public var volumeRelativePath: String?

    public init(path: String, volumeUUID: String? = nil, volumeRelativePath: String? = nil) {
        self.path = path
        self.volumeUUID = volumeUUID
        self.volumeRelativePath = volumeRelativePath
    }

    public init(_ url: URL) {
        let folder = url.standardizedFileURL
        let values = try? folder.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        path = folder.path
        volumeUUID = values?.volumeUUIDString
        if let root = values?.volume?.standardizedFileURL.path, folder.path.hasPrefix(root) {
            volumeRelativePath = String(folder.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// True when `other` is this folder seen again: the same path, or the same volume and the same place on it.
    public func matches(_ other: FolderIdentity) -> Bool {
        if path == other.path { return true }
        guard let id = volumeUUID, id == other.volumeUUID, let rel = volumeRelativePath, rel == other.volumeRelativePath
        else { return false }
        return true
    }
}

/// A decision that was made but never reached its sidecar (M-11). Kept so a relaunch can try the write again.
public struct UnsavedDecision: Sendable, Equatable, Codable {
    public var name: String
    public var rating: Int
    public var label: ColorLabel?

    public init(name: String, decision: Decision) {
        self.name = name
        rating = decision.rating
        label = decision.label
    }

    public var decision: Decision { Decision(rating: rating, label: label) }
}

/// What reopening a folder brings back (V-15): the current photo, mode, filter, sort, selection and the decisions
/// not yet on disk. Photos are named by file name, so a moved folder still resolves. Lives in Application Support,
/// never in the photo folder.
public struct SessionState: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public var version = SessionState.currentVersion
    public var identity: FolderIdentity
    public var savedAt: Date
    /// "grid" or "loupe" (Compare is saved as Loupe, since a pair needs the live selection).
    public var mode: String
    public var currentName: String?
    public var filter: PhotoFilter
    public var selected: [String]
    public var selectionAnchor: String?
    public var unsaved: [UnsavedDecision]

    public init(identity: FolderIdentity, savedAt: Date = Date(), mode: String = "grid", currentName: String? = nil,
                filter: PhotoFilter = PhotoFilter(), selected: [String] = [], selectionAnchor: String? = nil,
                unsaved: [UnsavedDecision] = []) {
        self.identity = identity
        self.savedAt = savedAt
        self.mode = mode
        self.currentName = currentName
        self.filter = filter
        self.selected = selected
        self.selectionAnchor = selectionAnchor
        self.unsaved = unsaved
    }

    /// The same session apart from when it was saved; the store skips a write when nothing else changed.
    public func sameContent(as other: SessionState) -> Bool {
        var copy = other
        copy.savedAt = savedAt
        return copy == self
    }
}
