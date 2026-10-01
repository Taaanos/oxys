import Foundation
import Observation

/// The open folder: its photos, in order, and whether it is still loading capture times.
@MainActor @Observable
public final class FolderModel {
    public enum Content: Equatable {
        case none
        case opening(URL)
        case photos
        case empty(hasSubfolderPhotos: Bool)
        case failed(String)
    }

    public private(set) var folder: URL?
    public private(set) var photos: [Photo] = []
    public private(set) var content: Content = .none
    public private(set) var isReadingCaptureTimes = false

    private var generation = 0
    private var loading: Task<Void, Never>?

    public init() {}

    /// Replaces the open folder. The list is published as soon as the directory is read; capture times follow
    /// and re-sort it once. A newer `open` cancels an older one still reading.
    public func open(_ url: URL) {
        loading?.cancel()
        generation += 1
        let mine = generation
        folder = url
        photos = []
        content = .opening(url)
        isReadingCaptureTimes = false

        loading = Task { [weak self] in
            let scanned = await Task.detached { Result { try FolderScanner.scan(url) } }.value
            guard let self, mine == generation else { return }
            switch scanned {
            case .failure(let error):
                content = .failed(error.localizedDescription)
            case .success(let result) where result.photos.isEmpty:
                content = .empty(hasSubfolderPhotos: result.subfolderHasPhotos)
            case .success(let result):
                photos = result.photos
                content = .photos
                await readCaptureTimes(generation: mine)
            }
        }
    }

    private func readCaptureTimes(generation mine: Int) async {
        isReadingCaptureTimes = true
        let snapshot = photos
        let times = await FolderScanner.captureTimes(for: snapshot)
        guard mine == generation, !Task.isCancelled else { return }
        var updated = snapshot
        for index in updated.indices { updated[index].captureTime = times[index] }
        updated.sort(by: Photo.isOrderedBefore)
        photos = updated
        isReadingCaptureTimes = false
    }
}
