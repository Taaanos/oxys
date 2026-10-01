import AppKit
import Canvas
import Commands
import CoreImage
import Diagnostics
import Imaging
import Library
import Observation
import Synchronization

/// Drives Loupe: loads the current photo off the main thread, hands it to the canvas, and routes the
/// navigation keys through the image pipeline (M-04). M-05 replaces the keymap here with the command table.
@MainActor @Observable
final class LoupeController {
    /// The photo on screen and the error (if any) that replaced its image. Updated together with the frame,
    /// so the info strip never describes a different photo than the one shown.
    private(set) var shown: Photo?
    private(set) var shownPixels: (width: Int, height: Int)?
    private(set) var failure: String?

    @ObservationIgnored weak var canvas: LoupeView?
    @ObservationIgnored private var pendingFrameToken: Perf.Token?
    @ObservationIgnored private var router = KeyRouter(keymap: LoupeController.keymap)
    @ObservationIgnored private var monitor: Any?

    static let keymap = Keymap([
        .init(.position(.rightArrow), command: "nav.next", behavior: .repeating),
        .init(.position(.leftArrow), command: "nav.previous", behavior: .repeating),
        .init(.position(.home), command: "nav.first"),
        .init(.position(.end), command: "nav.last"),
    ])

    // MARK: loading

    /// Default memory budget for decoded frames: 2 GB, or a quarter of the RAM on a smaller Mac (G-3). The
    /// `prefetchBudgetMB` default overrides it.
    static var memoryBudget: Int {
        if let mb = UserDefaults.standard.object(forKey: "prefetchBudgetMB") as? Int, mb > 0 { return mb << 20 }
        return min(2 << 30, Int(ProcessInfo.processInfo.physicalMemory / 4))
    }

    @ObservationIgnored private let thumbnails = DiskThumbnailCache(
        directory: DiskThumbnailCache.standardDirectory(bundleID: Bundle.main.bundleIdentifier ?? "dev.oxys.Oxys"))
    @ObservationIgnored private let pipeline: FramePipeline<LoupeFrame>
    @ObservationIgnored private let plan = PrefetchPlan()
    @ObservationIgnored private var lastIndex: Int?
    @ObservationIgnored private var budgetObserver: Any?

    init() {
        let thumbnails = thumbnails
        pipeline = FramePipeline(budget: Self.memoryBudget) { key in try FrameLoader.load(key, thumbnails: thumbnails) }
        budgetObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyBudget() }
        }
    }

    private func applyBudget() {
        let pipeline = pipeline, budget = Self.memoryBudget
        Task { await pipeline.setBudget(budget) }
    }

    /// A new folder: drop the frames of the old one.
    func reset() {
        lastIndex = nil
        let pipeline = pipeline
        Task { await pipeline.reset() }
    }

    /// Shows `photo`'s preview. A newer call cancels an older one (and the pipeline cancels the old request's
    /// read and decode); the previous frame stays up until something for `photo` is ready, and `shown`
    /// changes with it. While the full preview loads, its disk thumbnail stands in if there is one.
    func load(_ photo: Photo?, in folder: FolderModel) async {
        guard let photo, let canvas else { return }
        let target = FrameLoader.key(for: photo)
        let index = folder.currentIndex
        let direction: PrefetchPlan.Direction = if let index, let last = lastIndex, index < last { .backward } else { .forward }
        lastIndex = index
        let slow = await pipeline.isSlow
        let neighbors = index.map {
            plan.indices(current: $0, count: folder.photos.count, direction: direction, slow: slow)
                .map { FrameLoader.key(for: folder.photos[$0]) }
        } ?? []

        let pipeline = pipeline, thumbnails = thumbnails
        let finished = Mutex(false)
        let full = Task { () -> Result<LoupeFrame?, any Error> in
            defer { finished.withLock { $0 = true } }
            do { return .success(try await pipeline.frame(for: target, prefetch: neighbors)) } catch { return .failure(error) }
        }
        if !(await pipeline.isCached(target)) {
            let stand = await Task.detached(priority: .userInitiated) {
                FrameLoader.placeholder(for: target, thumbnails: thumbnails)
            }.value
            if let stand, !finished.withLock({ $0 }), isCurrent(photo, in: folder) {
                shown = photo
                shownPixels = nil
                failure = nil
                canvas.setAccessibilityLabel(photo.name)
                canvas.show(stand)
                FrameLog.record(cursor: folder.currentURL, displayed: photo.url, kind: "thumbnail")
            }
        }
        let result = await full.value
        guard isCurrent(photo, in: folder) else { return }
        let frame: LoupeFrame
        switch result {
        case .failure(let error):
            showFailure(error, photo: photo, canvas: canvas)
            return
        case .success(nil):
            return   // superseded inside the pipeline
        case .success(let loaded?):
            frame = loaded
        }
        let token = takeToken()
        shown = photo
        folder.setPreview(PreviewInfo(pixelWidth: frame.width, pixelHeight: frame.height), for: photo.url)
        shownPixels = (frame.width, frame.height)
        failure = nil
        canvas.setAccessibilityLabel("\(photo.name), \(frame.width) by \(frame.height) pixels")
        canvas.show(frame.image, keyToFrame: token)
        FrameLog.record(cursor: folder.currentURL, displayed: photo.url, kind: "preview")
    }

    /// Whether `photo` is still the one the cursor is on and this request has not been superseded. Checked
    /// right before anything is shown, with no suspension in between, so a stale frame can never reach the canvas.
    private func isCurrent(_ photo: Photo, in folder: FolderModel) -> Bool {
        !Task.isCancelled && folder.currentURL == photo.url
    }

    private func showFailure(_ error: any Error, photo: Photo, canvas: LoupeView) {
        let token = takeToken()
        let message = (error as? PreviewError)?.localizedDescription ?? error.localizedDescription
        shown = photo
        shownPixels = nil
        failure = message
        canvas.setAccessibilityLabel("\(photo.name). \(message)")
        canvas.show(nil, keyToFrame: token)
        FrameLog.record(cursor: photo.url, displayed: photo.url, kind: "error")
    }

    private func takeToken() -> Perf.Token? {
        defer { pendingFrameToken = nil }
        return pendingFrameToken
    }

    // MARK: keys

    /// Installs the key monitor. `folder` is read at each key press.
    func start(folder: FolderModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread, but the closure type is not isolated.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.route(event, folder: folder) == true }
            return consumed ? nil : event
        }
    }

    private func route(_ event: NSEvent, folder: FolderModel) -> Bool {
        guard folder.content == .photos, event.window?.isKeyWindow == true,
              let input = KeyInput(event: event, layout: KeyLayout.asciiCapable())
        else { return false }
        let focus: KeyFocus = if let tv = event.window?.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor {
            .textInput
        } else { .canvas }
        let result = router.handle(input, mode: .loupe, focus: focus)
        for case .perform(let id) in result.actions {
            if let step = Self.step(for: id) { navigate(step, folder: folder) }
        }
        return result.consumed
    }

    static func step(for id: CommandID) -> FolderModel.Step? {
        switch id.rawValue {
        case "nav.next": .next
        case "nav.previous": .previous
        case "nav.first": .first
        case "nav.last": .last
        default: nil
        }
    }

    /// The menu items and the keys both come here. The key-to-frame interval starts now and ends when the
    /// canvas has presented the frame; a move that changes nothing (at either end) ends it at once.
    func navigate(_ step: FolderModel.Step, folder: FolderModel) {
        let token = Perf.begin(.keyToFrame)
        if folder.move(step) {
            if let stale = pendingFrameToken { Perf.end(stale) }
            pendingFrameToken = token
        } else {
            Perf.end(token)
        }
    }
}
