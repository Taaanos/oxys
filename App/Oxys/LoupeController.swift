import AppKit
import Canvas
import Commands
import CoreImage
import Diagnostics
import Imaging
import Library
import Metadata
import Observation
import Synchronization

/// Drives Loupe: loads the current photo off the main thread, hands it to the canvas, and routes the
/// navigation commands (from the command table, M-05) through the image pipeline (M-04).
@MainActor @Observable
final class LoupeController {
    /// The photo on screen and the error (if any) that replaced its image. Updated together with the frame,
    /// so the info strip never describes a different photo than the one shown.
    private(set) var shown: Photo?
    private(set) var shownPixels: (width: Int, height: Int)?
    private(set) var failure: String?
    /// Zoom level of the frame on screen, for the info strip; nil when there is no frame.
    private(set) var zoomInfo: ZoomInfo?

    /// EXIF of the photo on screen (M-16), formatted; nil while it is being read and for a file without any.
    private(set) var exif: ExifInfo?
    /// How much sits on the image (M-18): `I` steps through the levels. Remembered across launches.
    enum InfoLevel: Int, CaseIterable, Comparable {
        case off, name, exif, histogram
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var next: Self { Self(rawValue: rawValue + 1) ?? .off }
        var title: String {
            switch self {
            case .off: "Off"
            case .name: "Filename"
            case .exif: "EXIF"
            case .histogram: "Histogram"
            }
        }
        var spoken: String {
            switch self {
            case .off: "Info off"
            case .name: "Filename and rating"
            case .exif: "Filename, rating and EXIF"
            case .histogram: "Filename, rating, EXIF and histogram"
            }
        }
    }
    private(set) var infoLevel = InfoLevel(rawValue: UserDefaults.standard.object(forKey: "infoLevel") as? Int ?? 1) ?? .name {
        didSet { UserDefaults.standard.set(infoLevel.rawValue, forKey: "infoLevel") }
    }
    var showExif: Bool { infoLevel >= .exif }
    var showInfoStrip: Bool { infoLevel != .off }

    func cycleInfo() {
        infoLevel = infoLevel.next
        // The last level adds the histogram; stepping on to Off or back to the first level takes it away.
        showHistogram = infoLevel == .histogram || (showHistogram && infoLevel >= .exif)
        announce(infoLevel.spoken)
    }

    /// `⇧I`, independent of the level. Turning it on while info is off brings up the strip too.
    func toggleHistogram() {
        showHistogram.toggle()
        if showHistogram, infoLevel == .off { infoLevel = .name }
    }
    /// Label of the focused value, set by `↑`/`↓` or a click; `⌘C` copies it.
    var focusedExifField: String?
    /// Histogram of the frame on screen (M-17); nil while a stand-in or no frame is shown.
    private(set) var histogram: Histogram?
    /// Whether the histogram is on the image; remembered across launches. The inspector reuses the same view.
    var showHistogram = UserDefaults.standard.object(forKey: "showHistogram") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showHistogram, forKey: "showHistogram") }
    }
    @ObservationIgnored private let exifCache = ExifCache()

    /// Sticky zoom (M-15): zoom and spot carry over to the next photo. On by default; `⌥Z` toggles it.
    var stickyZoom = UserDefaults.standard.object(forKey: "stickyZoom") as? Bool ?? true {
        didSet {
            canvas?.stickyZoom = stickyZoom
            UserDefaults.standard.set(stickyZoom, forKey: "stickyZoom")
        }
    }
    /// Longer side of the last full preview, to size a thumbnail stand-in's zoom (see `LoupeView.show`).
    @ObservationIgnored private var lastPreviewLongSide: CGFloat?

    /// What the canvas shows of the photo on screen (V-02): its embedded preview, a decode of the RAW under way
    /// (the preview stays up), or the developed RAW.
    enum DevelopState: Equatable { case preview, developing, raw }
    private(set) var developState = DevelopState.preview
    /// Photos the user switched to RAW with `R`. A photo comes back as RAW while its decode is still in the
    /// cache (V-02/Q1); one that was evicted comes back as the preview.
    @ObservationIgnored private var rawWanted: Set<URL> = []
    @ObservationIgnored private var developingURL: URL?
    @ObservationIgnored private var developTask: Task<Void, Never>?
    /// At most 5 developed RAWs, within the frame budget (V-02).
    @ObservationIgnored private let rawCache = RawFrameCache<LoupeFrame>(maxCount: 5, maxBytes: LoupeController.memoryBudget)

    /// The confirmation over the canvas after a cull key; nil when it has timed out.
    struct Badge: Equatable {
        let id: Int
        let decision: Decision
        /// Set when `⇧` moved on, so the badge says which photo it is about.
        let photoName: String?
    }
    private(set) var badge: Badge?
    @ObservationIgnored private var badgeCount = 0
    @ObservationIgnored private var badgeTimeout: Task<Void, Never>?

    /// Loupe's screen builds a new canvas each time it is entered from Grid, and its load task can run before
    /// that (the load then drew on the old canvas or none). Whenever the canvas changes, load the last
    /// request again so the new one is never blank; the frame is usually cached, so this is instant.
    @ObservationIgnored weak var canvas: LoupeView? {
        didSet {
            canvas?.onZoomChange = { [weak self] info in self?.zoomInfo = info }
            canvas?.stickyZoom = stickyZoom
            guard let canvas, canvas !== oldValue, let last = lastRequest else { return }
            Task { await load(last.photo, in: last.folder) }
        }
    }
    @ObservationIgnored private var lastRequest: (photo: Photo, folder: FolderModel)?
    /// Grid's view, which hosts the announcements and the frame tick while Loupe's canvas is not on screen.
    @ObservationIgnored weak var fallbackHost: NSView?
    /// Loupe's screen stays alive behind Grid (a fresh Metal layer on every entry sometimes never reached the
    /// screen), so "has a window" no longer means "is showing". Set by the screen.
    @ObservationIgnored private(set) var isActive = false
    private var host: NSView? {
        if isActive, let canvas, canvas.window != nil { canvas } else { fallbackHost }
    }

    /// Loupe came to the front or went behind Grid. Going behind blanks the canvas so the next entry never
    /// flashes the photo Loupe last showed.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if !active {
            stopDeveloping()
            developState = .preview
            shown = nil
            setExif(nil)
            histogram = nil
            shownPixels = nil
            failure = nil
            canvas?.show(nil)
        }
    }
    @ObservationIgnored private var pendingFrameToken: Perf.Token?

    // MARK: loading

    /// Default memory budget for decoded frames: 2 GB, or a quarter of the RAM on a smaller Mac (G-3). The
    /// `prefetchBudgetMB` default overrides it.
    static var memoryBudget: Int {
        if let mb = UserDefaults.standard.object(forKey: "prefetchBudgetMB") as? Int, mb > 0 { return mb << 20 }
        return automaticBudget
    }

    /// What "automatic" means: 2 GB, or a quarter of the RAM when that is less. Settings shows it (M-22).
    static var automaticBudget: Int { min(2 << 30, Int(ProcessInfo.processInfo.physicalMemory / 4)) }

    @ObservationIgnored private let thumbnails = FrameLoader.sharedThumbnails
    @ObservationIgnored private let pipeline: FramePipeline<LoupeFrame>
    @ObservationIgnored private let plan = PrefetchPlan()
    @ObservationIgnored private var lastIndex: Int?
    @ObservationIgnored private var budgetObserver: Any?

    init() {
        let thumbnails = thumbnails
        // One load holds the decoded image and the upload buffer beside the texture: about 2.5 times its cost.
        pipeline = FramePipeline(budget: Self.memoryBudget, transientFactor: 2.5) { key in try FrameLoader.load(key, thumbnails: thumbnails) }
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
        lastPreviewLongSide = nil
        stopDeveloping()
        rawWanted = []
        rawCache.removeAll()
        developState = .preview
        canvas?.resetZoom()
        let pipeline = pipeline
        Task { await pipeline.reset() }
    }

    /// Shows `photo`'s preview. A newer call cancels an older one (and the pipeline cancels the old request's
    /// read and decode); the previous frame stays up until something for `photo` is ready, and `shown`
    /// changes with it. While the full preview loads, its disk thumbnail stands in if there is one.
    func load(_ photo: Photo?, in folder: FolderModel) async {
        guard let photo, isActive else { return }
        lastRequest = (photo, folder)
        guard let canvas else { return }
        let target = FrameLoader.key(for: photo)
        // Moving on cancels the decode of the photo left behind (V-02).
        if developingURL != photo.url { stopDeveloping() }
        let index = folder.currentIndex
        let direction: PrefetchPlan.Direction = if let index, let last = lastIndex, index < last { .backward } else { .forward }
        lastIndex = index
        let slow = await pipeline.isSlow
        let neighborIndices = index.map {
            plan.indices(current: $0, count: folder.visible.count, direction: direction, slow: slow)
        } ?? []
        let neighbors = neighborIndices.map { FrameLoader.key(for: folder.visible[$0]) }
        warmExif([photo.url] + neighborIndices.map { folder.visible[$0].url })

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
                let same = shown?.url == photo.url
                shown = photo
                previewShown(of: photo)
                updateExif(for: photo)
                histogram = nil
                shownPixels = nil
                failure = nil
                canvas.setAccessibilityLabel(photo.name)
                let long = max(stand.displaySize.width, stand.displaySize.height)
                let factor = lastPreviewLongSide.map { long > 0 ? $0 / long : 1 } ?? 1
                canvas.show(stand, sameZoom: same, zoomSizeFactor: factor)
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
        let same = shown?.url == photo.url && failure == nil
        shown = photo
        previewShown(of: photo)
        updateExif(for: photo)
        folder.setPreview(PreviewInfo(pixelWidth: frame.width, pixelHeight: frame.height), for: photo.url)
        histogram = frame.histogram
        shownPixels = (frame.width, frame.height)
        lastPreviewLongSide = CGFloat(max(frame.width, frame.height))
        failure = nil
        canvas.setAccessibilityLabel("\(photo.name), \(frame.width) by \(frame.height) pixels")
        canvas.show(frame.image, keyToFrame: token, sameZoom: same)
        FrameLog.record(cursor: folder.currentURL, displayed: photo.url, kind: "preview")
        // Back on a photo that was in RAW mode: its decode is still cached, or the mode lapses (V-02/Q1).
        if rawWanted.contains(photo.url) {
            if let developed = rawCache.cached(target) {
                present(developed, of: photo, canvas: canvas)
            } else {
                rawWanted.remove(photo.url)
            }
        }
    }

    // MARK: develop (V-02)

    /// A preview (or its stand-in) of `photo` went on screen. The state goes back to "preview" unless this
    /// photo's RAW is being developed, in which case the preview simply stays up until the RAW replaces it.
    private func previewShown(of photo: Photo) {
        if developState == .developing, developingURL == photo.url { return }
        developState = .preview
    }

    /// `R`: the RAW over the preview, and back. Pressed while it decodes, it cancels.
    func toggleRaw() {
        guard isActive, let canvas, canvas.window != nil, let photo = shown, failure == nil else { return }
        guard photo.format.isRaw else {
            announce("\(photo.name) is not a RAW file")
            return
        }
        switch developState {
        case .preview:
            rawWanted.insert(photo.url)
            develop(photo)
        case .developing:
            rawWanted.remove(photo.url)
            stopDeveloping()
            developState = .preview
            announce("RAW cancelled, showing the preview")
        case .raw:
            rawWanted.remove(photo.url)
            showPreviewAgain(of: photo, canvas: canvas)
        }
    }

    private func develop(_ photo: Photo) {
        guard let canvas else { return }
        stopDeveloping()
        developState = .developing
        developingURL = photo.url
        announce("Developing")
        let key = FrameLoader.key(for: photo)
        let minLongEdge = max(512, shownPixels.map { max($0.width, $0.height) } ?? 0)
        let cache = rawCache
        developTask = Task { [weak self] in
            let result: Result<LoupeFrame?, any Error>
            do {
                result = .success(try await cache.develop(key) { try FrameLoader.develop($0, minLongEdge: minLongEdge) })
            } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, developingURL == photo.url, shown?.url == photo.url else { return }
            developingURL = nil
            switch result {
            case .success(let frame?):
                present(frame, of: photo, canvas: canvas)
            case .success(nil):
                developState = .preview
            case .failure:
                rawWanted.remove(photo.url)
                developState = .preview
                announce("This RAW cannot be developed. Showing the preview")
            }
        }
    }

    /// Cancels the decode in flight, if any. Its result is dropped when it lands.
    private func stopDeveloping() {
        developTask?.cancel()
        developTask = nil
        developingURL = nil
        rawCache.cancelInflight()
    }

    private func present(_ frame: LoupeFrame, of photo: Photo, canvas: LoupeView) {
        developState = .raw
        histogram = frame.histogram
        shownPixels = (frame.width, frame.height)
        canvas.setAccessibilityLabel("\(photo.name), RAW, \(frame.width) by \(frame.height) pixels")
        // Same photo, more pixels: the view keeps its place on screen.
        canvas.show(frame.image, sameZoom: true, keepView: true)
        announce("RAW")
    }

    private func showPreviewAgain(of photo: Photo, canvas: LoupeView) {
        let key = FrameLoader.key(for: photo)
        let pipeline = pipeline
        developState = .preview
        Task { [weak self] in
            // The preview is normally still cached; if the budget pushed it out, load it again.
            var cached = await pipeline.cachedFrame(key)
            if cached == nil { cached = try? await pipeline.frame(for: key, prefetch: []) }
            guard let frame = cached else { return }
            guard let self, shown?.url == photo.url, developState == .preview else { return }
            histogram = frame.histogram
            shownPixels = (frame.width, frame.height)
            canvas.setAccessibilityLabel("\(photo.name), \(frame.width) by \(frame.height) pixels")
            canvas.show(frame.image, sameZoom: true, keepView: true)
            announce("Preview")
        }
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
        updateExif(for: photo)
        histogram = nil
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

    // MARK: EXIF

    /// Shows `photo`'s EXIF: at once when the cache has it (it was read with the prefetch), otherwise after a
    /// background read. A read that finishes after the photo changed is dropped.
    private func updateExif(for photo: Photo) {
        if let hit = exifCache.cached(photo.url) {
            setExif(hit)
            return
        }
        setExif(nil)
        let cache = exifCache, url = photo.url
        Task { [weak self] in
            let info = await Task.detached(priority: .userInitiated) { cache.info(for: url) }.value
            guard let self, shown?.url == url else { return }
            setExif(info)
        }
    }

    /// Keeps the canvas's AF anchor (V-01) in step with the EXIF on screen, so `Z` goes to the point the camera focused on.
    private func setExif(_ info: ExifInfo?) {
        exif = info
        canvas?.focusAnchor = info?.maker?.focusAnchor.map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// EXIF of any photo, for the inspector when Grid is in front (M-18). Shares the cache with the Loupe panel.
    func exifInfo(for url: URL) async -> ExifInfo? {
        if let hit = exifCache.cached(url) { return hit }
        let cache = exifCache
        return await Task.detached(priority: .userInitiated) { cache.info(for: url) }.value
    }

    /// Reads the EXIF of the photos the prefetch is about to load, so stepping to them has the values ready.
    private func warmExif(_ urls: [URL]) {
        let cache = exifCache
        Task.detached(priority: .utility) {
            for url in urls { _ = cache.info(for: url) }
        }
    }

    /// `↑` and `↓` through the values; the first press lands on the first or last one.
    func moveExifFocus(_ step: Int) {
        let labels = (exif?.fields ?? []).map(\.label)
        guard !labels.isEmpty else { return }
        let current = focusedExifField.flatMap { labels.firstIndex(of: $0) }
        let next = current.map { min(max($0 + step, 0), labels.count - 1) } ?? (step > 0 ? 0 : labels.count - 1)
        focusedExifField = labels[next]
        announce("\(labels[next]), \(exif?.fields[next].value ?? "")")
    }

    /// The focused value, or every value as "Label: value" lines when none is focused.
    func copyExif() {
        guard let fields = exif?.fields, !fields.isEmpty else { return }
        let text: String
        if let label = focusedExifField, let field = fields.first(where: { $0.label == label }) {
            text = field.value
        } else {
            text = fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        announce("Copied")
    }

    func showInMaps() {
        if let url = exif?.gps?.mapsURL { NSWorkspace.shared.open(url) }
    }

    // MARK: navigation

    /// The menu items and the keys both come here. The key-to-frame interval starts now and ends when the
    /// canvas has presented the frame; a move that changes nothing (at either end) ends it at once.
    func navigate(_ step: FolderModel.Step, folder: FolderModel) {
        // From Grid (⇧ with a cull key) there is no canvas to present a frame, so no interval to time.
        guard isActive, canvas?.window != nil else {
            folder.move(step)
            return
        }
        let token = Perf.begin(.keyToFrame)
        if folder.move(step) {
            if let stale = pendingFrameToken { Perf.end(stale) }
            pendingFrameToken = token
        } else {
            Perf.end(token)
        }
    }

    // MARK: zoom

    /// Zoom commands act on the frame on screen; the `zoom` interval ends when the scaled frame is presented.
    func setZoom(_ level: ZoomLevel) {
        guard isActive, let canvas, canvas.window != nil else { return }
        canvas.setZoom(level, token: Perf.begin(.zoom))
    }

    func stepZoom(_ direction: ZoomDirection) {
        guard isActive, let canvas, canvas.window != nil else { return }
        canvas.stepZoom(direction, token: Perf.begin(.zoom))
    }

    func pan(_ direction: PanDirection, page: Bool) {
        guard isActive, let canvas, canvas.window != nil else { return }
        canvas.pan(direction, page: page)
    }

    func toggleZoom() {
        guard isActive, let canvas, canvas.window != nil else { return }
        canvas.toggleZoom(token: Perf.begin(.zoom))
    }

    // MARK: cull

    /// Applies a cull key (Loupe acts on the active photo only; Grid passes its selection, G-5), confirms it with
    /// the badge and a VoiceOver phrase, and with `⇧` moves to the next frame. The in-memory decision is
    /// the only effect until M-08 saves it.
    func cull(_ action: CullAction, advance: Bool, folder: FolderModel, targets: [URL]? = nil) {
        let token = Perf.begin(.cullFeedback)
        let urls = targets ?? folder.currentURL.map { [$0] } ?? []
        guard let photo = folder.currentPhoto, let decision = folder.apply(action, toAll: urls) else {
            Perf.end(token)
            return
        }
        if urls.count > 1 {
            let phrase = "\(urls.count) photos, \(decision.summary)"
            confirm(decision, photoName: "\(urls.count) photos", phrase: phrase, token: token)
        } else {
            confirm(decision, photoName: advance ? photo.name : nil, phrase: advance ? "\(photo.name), \(decision.summary)" : decision.summary, token: token)
        }
        if advance { navigate(.next, folder: folder) }
    }

    /// ⌘Z and ⇧⌘Z. The restored decision is saved like any other; the photo it belongs to is shown, so the
    /// photographer sees what changed (M-09/Q2).
    func undo(folder: FolderModel) {
        guard let name = folder.undoName else { return }
        restored("Undid \(name)", url: folder.undo(), folder: folder)
    }

    func redo(folder: FolderModel) {
        guard let name = folder.redoName else { return }
        restored("Redid \(name)", url: folder.redo(), folder: folder)
    }

    private func restored(_ verb: String, url: URL?, folder: FolderModel) {
        guard let url, let photo = folder.photos.first(where: { $0.url == url }) else { return }
        let token = Perf.begin(.cullFeedback)
        // The current photo changed under the canvas; the view's load task follows `currentURL`.
        confirm(photo.decision, photoName: photo.name, phrase: "\(verb). \(photo.name), \(photo.decision.summary)", token: token)
    }

    private func confirm(_ decision: Decision, photoName: String?, phrase: String, token: Perf.Token) {
        badgeCount += 1
        badge = Badge(id: badgeCount, decision: decision, photoName: photoName)
        endAtNextDisplayFrame(token)
        announce(phrase)
        let id = badgeCount
        badgeTimeout?.cancel()
        badgeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, badge?.id == id else { return }
            badge = nil
        }
    }

    private func announce(_ phrase: String) {
        guard let host else { return }
        NSAccessibility.post(element: host, notification: .announcementRequested, userInfo: [
            .announcement: phrase, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Ends the interval on the first display-link tick after the state change, i.e. the next display frame.
    private func endAtNextDisplayFrame(_ token: Perf.Token) {
        guard let host, host.window != nil else { Perf.end(token); return }
        let ticker = FrameTicker(token)
        ticker.link = host.displayLink(target: ticker, selector: #selector(FrameTicker.tick(_:)))
        ticker.link?.add(to: .main, forMode: .common)
    }
}

/// A one-shot display link: ends a signpost interval on its first tick, then stops itself.
@MainActor
private final class FrameTicker: NSObject {
    var link: CADisplayLink?
    private var token: Perf.Token?
    private var keepAlive: FrameTicker?

    init(_ token: Perf.Token) {
        self.token = token
        super.init()
        keepAlive = self
    }

    @objc func tick(_ link: CADisplayLink) {
        if let token { Perf.end(token) }
        token = nil
        link.invalidate()
        self.link = nil
        keepAlive = nil
    }
}
