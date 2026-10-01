import Foundation
import Diagnostics
import Observation
import Sidecar

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
    public private(set) var isReadingSidecars = false

    /// The configured naming style (PRD "Sidecar naming"). Reads fall back to the other style.
    public var sidecarNaming: SidecarNaming = .stem

    /// The photo Loupe shows. Tracked by URL so the capture-time re-sort cannot change which frame is current.
    public private(set) var currentURL: URL?

    /// The latest write that could not be completed (M-11 turns this into UI). Refusals, where the sidecar on
    /// disk cannot be patched safely, also mark the photo's `sidecar.problem`.
    public private(set) var lastWriteFailure: String?

    /// What ⌘Z and ⇧⌘Z step through. Cleared when another folder opens (M-09/Q3).
    public private(set) var undoStack = UndoStack()

    private var generation = 0
    private var loading: Task<Void, Never>?
    @ObservationIgnored private var writer: SidecarWriteQueue!

    public init(writer: SidecarWriteQueue? = nil) {
        self.writer = writer ?? SidecarWriteQueue(onOutcome: { [weak self] outcome in
            Task { @MainActor in self?.handle(outcome) }
        })
    }

    /// Blocks until every decision made so far is on disk. Called on quit.
    public func flushSidecarWrites() { writer.flush() }

    private func handle(_ outcome: SidecarWriteOutcome) {
        switch outcome {
        case .written(let url):
            // A redo can write a sidecar an undo just removed: the photo knows its file again.
            for index in photos.indices where photos[index].sidecar.file == nil && primaryURL(for: photos[index]) == url {
                photos[index].sidecar.file = url
            }
        case .removed(let url):
            for index in photos.indices where photos[index].sidecar.file == url { photos[index].sidecar.file = nil }
        case .refused(let url, let reason):
            lastWriteFailure = "Not saved to \(url.lastPathComponent): \(reason)"
            for index in photos.indices where photos[index].sidecar.file == url { photos[index].sidecar.problem = reason }
        case .failed(let url, let reason):
            lastWriteFailure = "Could not write \(url.lastPathComponent): \(reason)"
        }
    }

    /// Replaces the open folder. The list is published as soon as the directory is read; capture times follow
    /// and re-sort it once. A newer `open` cancels an older one still reading.
    public func open(_ url: URL) {
        loading?.cancel()
        generation += 1
        let mine = generation
        folder = url
        photos = []
        currentURL = nil
        undoStack.removeAll()
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
                currentURL = photos.first?.url
                content = .photos
                // Both passes start now and run off the main thread; neither holds up the first image.
                let sidecars = Task { await self.readSidecars(generation: mine) }
                await readCaptureTimes(generation: mine)
                await sidecars.value
            }
        }
    }

    private func readCaptureTimes(generation mine: Int) async {
        isReadingCaptureTimes = true
        let snapshot = photos
        let times = await FolderScanner.captureTimes(for: snapshot)
        guard mine == generation, !Task.isCancelled else { return }
        // Merge into the live list: decisions and previews recorded while the times were read must survive.
        var updated = photos
        let byURL = Dictionary(uniqueKeysWithValues: zip(snapshot.map(\.url), times))
        for index in updated.indices { updated[index].captureTime = byURL[updated[index].url] ?? nil }
        updated.sort(by: Photo.isOrderedBefore)
        photos = updated
        isReadingCaptureTimes = false
    }

    /// Reads every sidecar (or embedded rating) with a few files in flight and applies the results chunk by chunk,
    /// so stars fill in while the photographer already works. A decision made meanwhile is never overwritten.
    private func readSidecars(generation mine: Int) async {
        guard let folder, !photos.isEmpty else { return }
        isReadingSidecars = true
        defer { if mine == generation { isReadingSidecars = false } }
        let token = Perf.begin(.sidecarRead)
        defer { Perf.end(token) }
        let targets = photos.map { (url: $0.url, embedded: $0.format.hasEmbeddedXMP) }
        let naming = sidecarNaming
        let chunkSize = 64
        let chunks = stride(from: 0, to: targets.count, by: chunkSize).map { Array(targets[$0..<min($0 + chunkSize, targets.count)]) }
        let index = await Task.detached {
            // A crash can leave a hidden temporary file from an atomic write behind (G-9).
            SidecarWriter.removeStaleTemps(in: folder)
            return SidecarIndex(folder: folder)
        }.value
        await withTaskGroup(of: [(URL, SidecarReadResult)].self) { group in
            var next = 0
            func addNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    chunk.map { ($0.url, SidecarReader.read(photo: $0.url, embeddedFallback: $0.embedded, index: index, naming: naming)) }
                }
            }
            for _ in 0..<min(4, chunks.count) { addNext() }
            while let results = await group.next() {
                guard mine == generation, !Task.isCancelled else { group.cancelAll(); return }
                applySidecarResults(results)
                addNext()
            }
        }
    }

    private func applySidecarResults(_ results: [(URL, SidecarReadResult)]) {
        // The list may have been re-sorted by capture time since the chunk started, so look photos up by URL.
        var positions: [URL: Int] = [:]
        positions.reserveCapacity(photos.count)
        for (i, photo) in photos.enumerated() { positions[photo.url] = i }
        for (url, result) in results {
            guard let i = positions[url] else { continue }
            var (info, decision) = SidecarInfo.resolve(result)
            if let decision, photos[i].decision.isUndecided {
                photos[i].decision = decision
            } else if !photos[i].decision.isUndecided {
                // The photographer already decided: their label, not the file's custom one, is what we keep.
                info.unknownLabel = nil
            }
            photos[i].sidecar = info
        }
    }

    public var currentIndex: Int? {
        guard let currentURL else { return nil }
        return photos.firstIndex { $0.url == currentURL }
    }

    public func decision(for url: URL) -> Decision? {
        photos.first { $0.url == url }?.decision
    }

    public var currentPhoto: Photo? { currentIndex.map { photos[$0] } }

    public enum Step: Sendable { case next, previous, first, last }

    /// Moves the current photo. Stops at either end (no wrap-around). Returns whether the photo changed.
    @discardableResult
    public func move(_ step: Step) -> Bool {
        guard !photos.isEmpty else { return false }
        let from = currentIndex ?? 0
        let to = switch step {
        case .next: min(from + 1, photos.count - 1)
        case .previous: max(from - 1, 0)
        case .first: 0
        case .last: photos.count - 1
        }
        guard to != from || currentURL == nil else { return false }
        currentURL = photos[to].url
        return true
    }

    /// Records what the preview reader found for `url`. Ignored if the photo is no longer in the folder.
    public func setPreview(_ info: PreviewInfo, for url: URL) {
        guard let index = photos.firstIndex(where: { $0.url == url }) else { return }
        photos[index].preview = info
    }

    /// Applies a cull key to the photo at `url` (the current one when nil). Returns the new decision, or nil
    /// when the photo is not in the folder.
    @discardableResult
    public func apply(_ action: CullAction, to url: URL? = nil) -> Decision? {
        guard let url = url ?? currentURL else { return nil }
        return apply(action, toAll: [url])
    }

    /// Applies a cull key to several photos as one undo step (G-5). Returns the first photo's new decision, or
    /// nil when none of them is in the folder.
    @discardableResult
    public func apply(_ action: CullAction, toAll urls: [URL]) -> Decision? {
        var changes: [DecisionChange] = []
        var first: Decision?
        var name = ""
        for url in urls {
            guard let index = photos.firstIndex(where: { $0.url == url }) else { continue }
            let before = photos[index].decision
            let decision = action.applied(to: before)
            first = first ?? decision
            guard decision != before else { continue }
            let unknownBefore = photos[index].sidecar.unknownLabel
            if decision.label != before.label { photos[index].sidecar.unknownLabel = nil }
            photos[index].decision = decision
            changes.append(DecisionChange(url: url, before: before, after: decision,
                                          unknownLabelBefore: unknownBefore, unknownLabelAfter: photos[index].sidecar.unknownLabel))
            if name.isEmpty { name = action.undoName(from: before, to: decision) }
            persist(at: index)
        }
        undoStack.record(UndoStep(name: name, changes: changes))
        return first
    }

    // MARK: undo and redo

    public var undoName: String? { undoStack.undoName }
    public var redoName: String? { undoStack.redoName }

    /// Takes back the last action, saves the restored decisions, and moves to the photo it changed so the
    /// photographer sees it (M-09/Q2). Returns that photo's URL, or nil when there was nothing to undo.
    @discardableResult
    public func undo() -> URL? {
        guard let step = undoStack.popUndo() else { return nil }
        return restore(step, forward: false)
    }

    @discardableResult
    public func redo() -> URL? {
        guard let step = undoStack.popRedo() else { return nil }
        return restore(step, forward: true)
    }

    private func restore(_ step: UndoStep, forward: Bool) -> URL? {
        var shown: URL?
        for change in step.changes {
            guard let index = photos.firstIndex(where: { $0.url == change.url }) else { continue }
            let decision = forward ? change.after : change.before
            photos[index].decision = decision
            photos[index].sidecar.unknownLabel = forward ? change.unknownLabelAfter : change.unknownLabelBefore
            persist(at: index, restoring: true)
            shown = shown ?? change.url
        }
        if let shown { currentURL = shown }
        return shown
    }

    private func primaryURL(for photo: Photo) -> URL? {
        folder?.appendingPathComponent(sidecarNaming.fileName(for: photo.name))
    }

    /// Queues the photo's decision for its sidecar. Never blocks: the write happens off the main thread.
    private func persist(at index: Int, restoring: Bool = false) {
        guard let folder else { return }
        let photo = photos[index]
        // M-08/Q3: a sidecar we could not parse is never overwritten; the decision stays in memory.
        guard photo.sidecar.problem == nil else { return }
        let primary = photo.sidecar.file ?? folder.appendingPathComponent(sidecarNaming.fileName(for: photo.name))
        // Before the sidecar read reaches this photo an existing file under the other style is not known yet.
        let fallback = photo.sidecar.isRead ? nil : folder.appendingPathComponent(sidecarNaming.other.fileName(for: photo.name))
        let label: SidecarEdit.LabelChange = photo.decision.label.map { .set($0.name) }
            ?? (photo.sidecar.unknownLabel != nil ? .keep : .remove)
        writer.submit(SidecarEdit(rating: photo.decision.rating, label: label),
                      to: SidecarTarget(primary: primary, fallback: fallback),
                      // Back to "nothing decided": a sidecar we created for this photo goes away again (M-09/Q1).
                      removeIfCreatedByUs: restoring && photo.decision.isUndecided && photo.sidecar.unknownLabel == nil)
        if photo.sidecar.file == nil, photo.sidecar.isRead { photos[index].sidecar.file = primary }
    }
}
