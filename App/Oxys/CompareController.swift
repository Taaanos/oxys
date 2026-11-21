import AppKit
import Canvas
import Commands
import Diagnostics
import Imaging
import Library
import Metadata
import Observation

/// What one side of Compare shows: its photo, the frame, the zoom on screen and the EXIF. Like Loupe's state, it
/// changes together with the frame, so the info under a pane never describes another photo than the pane shows.
@MainActor @Observable
final class ComparePane {
    /// What this pane currently displays. Keeps the photo, preview frame, pixel dimensions, failure message,
    /// develop state and lens correction in lockstep so illegal combinations are unrepresentable.
    enum Content {
        case empty
        case preview(photo: Photo, frame: LoupeFrame, developing: Bool = false)
        case raw(photo: Photo, previewFrame: LoupeFrame, pixels: LoupeController.PixelSize, lensCorrection: LensCorrection)
        case failed(photo: Photo, message: String)

        var photo: Photo? {
            switch self {
            case .empty: nil
            case .preview(let p, _, _), .raw(let p, _, _, _), .failed(let p, _): p
            }
        }

        var pixels: LoupeController.PixelSize? {
            switch self {
            case .empty, .failed: nil
            case .preview(_, let frame, _): LoupeController.PixelSize(width: frame.width, height: frame.height)
            case .raw(_, _, let pixels, _): pixels
            }
        }

        var failure: String? {
            if case .failed(_, let message) = self { return message }
            return nil
        }

        var developState: LoupeController.DevelopState {
            switch self {
            case .raw: .raw
            case .preview(_, _, true): .developing
            case .empty, .preview(_, _, false), .failed: .preview
            }
        }

        var lensCorrection: LensCorrection? {
            if case .raw(_, _, _, let lc) = self { return lc }
            return nil
        }

        var previewFrame: LoupeFrame? {
            switch self {
            case .preview(_, let frame, _), .raw(_, let frame, _, _): frame
            case .empty, .failed: nil
            }
        }
    }

    let side: ComparePair.Side
    private(set) var content: Content = .empty
    var shown: Photo? { content.photo }
    var shownPixels: LoupeController.PixelSize? { content.pixels }
    var failure: String? { content.failure }
    private(set) var zoomInfo: ZoomInfo?
    private(set) var exif: ExifInfo?
    /// The pane's own RAW state (V-09): `R` develops both panes, and each keeps its own state until its photo changes.
    var developState: LoupeController.DevelopState { content.developState }
    /// V-19: what the decoder did about the lens for this pane's RAW; non-nil only while `content` is `.raw`.
    var lensCorrection: LensCorrection? { content.lensCorrection }
    /// How much of the frame is clipped, while an overlay is on; nil until the analysis is back.
    private(set) var clippingStats: ClippingStats?

    @ObservationIgnored private var developTask: Task<Void, Never>?
    /// Set by the controller: gives a new canvas its zoom rules, its overlays and its link to the other pane.
    @ObservationIgnored var configure: ((LoupeView) -> Void)?
    /// Called when a new frame is up, so the controller can start developing the RAW (Compare always shows the RAW).
    @ObservationIgnored var onShown: (() -> Void)?
    @ObservationIgnored private var loadRequest: (url: URL, task: Task<Void, Never>)?
    /// The view is built after the pane is asked to load; it shows the frame as soon as it exists.
    @ObservationIgnored weak var canvas: LoupeView? {
        didSet {
            guard let canvas, canvas !== oldValue else { return }
            canvas.onZoomChange = { [weak self] in self?.zoomInfo = $0 }
            canvas.onClippingStats = { [weak self] in self?.clippingStats = $0 }
            canvas.focusAnchor = exif?.maker?.focusAnchor.map { CGPoint(x: $0.x, y: $0.y) }
            configure?(canvas)
            canvas.setAccessibilityLabel(accessibilityName)
            if let frame = content.previewFrame {
                canvas.show(frame.image)
                onShown?()
            } else if case .failed = content {
                canvas.show(nil)
            }
        }
    }

    init(side: ComparePair.Side) { self.side = side }

    var isRaw: Bool {
        switch content {
        case .preview(let photo, _, _), .raw(let photo, _, _, _): photo.format.isRaw
        case .empty, .failed: false
        }
    }

    var truthBadge: TruthBadge? {
        guard let zoom = zoomInfo else { return nil }
        let (pixels, source): (LoupeController.PixelSize, TruthBadge.Source)
        switch content {
        case .empty, .failed: return nil
        case .preview(let photo, let frame, let developing):
            let s: TruthBadge.Source = !photo.format.isRaw ? .file : developing ? .developing : .preview
            (pixels, source) = (LoupeController.PixelSize(width: frame.width, height: frame.height), s)
        case .raw(_, _, let px, _):
            (pixels, source) = (px, .raw)
        }
        return TruthBadge.make(source: source, percent: zoom.percent, isFit: zoom.level.isFit,
                               longEdge: pixels.longEdge,
                               sensorLongEdge: RawPolicy.longEdge(ofDimensions: exif?.dimensions))
    }

    var accessibilityName: String {
        switch content {
        case .empty:
            "\(side.title) pane, empty"
        case .failed(let photo, let message):
            "\(side.title) pane, \(photo.name). \(message)"
        case .preview(let photo, let frame, _):
            "\(side.title) pane, \(photo.name), \(frame.width) by \(frame.height) pixels"
        case .raw(let photo, _, let pixels, _):
            "\(side.title) pane, \(photo.name), RAW, \(pixels.width) by \(pixels.height) pixels"
        }
    }

    /// Shows `photo`. A newer call cancels an older one; the previous frame stays up until the new one is ready.
    /// `prefetch` must hold the other pane's key: the pipeline cancels anything that is neither target nor prefetch.
    func show(_ photo: Photo, prefetch: [FrameKey], pipeline: FramePipeline<LoupeFrame>, folder: FolderModel,
              exif readExif: @escaping @Sendable (URL) async -> ExifInfo?, token: Perf.Token?) {
        if loadRequest?.url == photo.url, shown?.url == photo.url {
            if let token { Perf.end(token) }
            return
        }
        loadRequest?.task.cancel()
        stopDeveloping()
        let key = FrameLoader.compareKey(for: photo)
        let task = Task { [weak self] in
            async let info = readExif(photo.url)
            let result: Result<LoupeFrame?, any Error>
            do { result = .success(try await pipeline.frame(for: key, prefetch: prefetch)) } catch { result = .failure(error) }
            let exif = await info
            guard let self, !Task.isCancelled, loadRequest?.url == photo.url else {
                if let token { Perf.end(token) }
                return
            }
            switch result {
            case .success(let loaded?):
                content = .preview(photo: photo, frame: loaded)
                self.exif = exif
                canvas?.focusAnchor = exif?.maker?.focusAnchor.map { CGPoint(x: $0.x, y: $0.y) }
                folder.setPreview(PreviewInfo(pixelWidth: loaded.width, pixelHeight: loaded.height), for: photo.url)
                canvas?.setAccessibilityLabel(accessibilityName)
                canvas?.show(loaded.image, keyToFrame: token)
                onShown?()
            case .success(nil):
                if let token { Perf.end(token) }   // superseded inside the pipeline
            case .failure(let error):
                let message = (error as? PreviewError)?.localizedDescription ?? error.localizedDescription
                content = .failed(photo: photo, message: message)
                self.exif = exif
                zoomInfo = nil
                canvas?.setAccessibilityLabel(accessibilityName)
                canvas?.show(nil, keyToFrame: token)
            }
        }
        loadRequest = (photo.url, task)
    }

    // MARK: develop (V-09)

    /// Decodes the RAW and swaps it in over the preview; the view keeps its place on screen (as in Loupe, V-02).
    /// `done` hears the result for VoiceOver.
    /// The returned task ends when this pane is done (the cache decodes one RAW at a time, so the caller waits).
    func develop(cache: RawFrameCache<LoupeFrame>, done: @escaping @MainActor (String) -> Void) -> Task<Void, Never>? {
        guard case .preview(let photo, let previewFrame, developing: false) = content, photo.format.isRaw, canvas != nil else { return nil }
        content = .preview(photo: photo, frame: previewFrame, developing: true)
        let key = FrameLoader.compareKey(for: photo)
        let minLongEdge = max(512, max(previewFrame.width, previewFrame.height))
        let lens = LoupeController.lensCorrection
        let task = Task { [weak self] in
            let result: Result<LoupeFrame?, any Error>
            do {
                result = .success(try await cache.develop(key) { try FrameLoader.develop($0, minLongEdge: minLongEdge, lensCorrection: lens) })
            } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, shown?.url == photo.url else { return }
            developTask = nil
            switch result {
            case .success(let developed?):
                let pixels = LoupeController.PixelSize(width: developed.width, height: developed.height)
                let correction = developed.lensCorrection ?? .off
                content = .raw(photo: photo, previewFrame: previewFrame, pixels: pixels, lensCorrection: correction)
                canvas?.setAccessibilityLabel(accessibilityName)
                canvas?.show(developed.image, sameZoom: true, keepView: true)
                done("\(side.title), RAW")
            case .success(nil):
                content = .preview(photo: photo, frame: previewFrame, developing: false)
            case .failure:
                content = .preview(photo: photo, frame: previewFrame, developing: false)
                done("\(side.title), this RAW cannot be developed. Showing the preview")
            }
        }
        developTask = task
        return task
    }

    /// Back to the preview, or stop the decode that is running.
    func showPreview() {
        developTask?.cancel()
        developTask = nil
        switch content {
        case .raw(let photo, let previewFrame, _, _):
            content = .preview(photo: photo, frame: previewFrame)
            canvas?.setAccessibilityLabel(accessibilityName)
            canvas?.show(previewFrame.image, sameZoom: true, keepView: true)
        case .preview(let photo, let frame, true):
            content = .preview(photo: photo, frame: frame)
        case .empty, .preview(_, _, false), .failed:
            break
        }
    }

    private func stopDeveloping() {
        developTask?.cancel()
        developTask = nil
        if case .preview(let photo, let frame, true) = content {
            content = .preview(photo: photo, frame: frame)
        }
    }

    /// Compare ended: nothing stays on the canvas for the next entry to flash.
    func clear() {
        loadRequest?.task.cancel()
        loadRequest = nil
        stopDeveloping()
        clippingStats = nil
        content = .empty
        zoomInfo = nil
        exif = nil
        canvas?.show(nil)
    }
}

/// Compare (V-08): two panes, a ring on the active one, and the keys that move, swap and cull them. The pair
/// logic is `ComparePair` in `Library`; this class loads the frames and applies the decisions.
///
/// The folder's current photo is always the active side's photo. That keeps everything that reads
/// `currentURL` (the inspector, undo, Loupe and Grid on the way out) right without knowing about Compare.
@MainActor @Observable
final class CompareController {
    /// Per side, the count of cull keys that took effect; the side's rating glyphs bounce when it changes.
    struct SidePulse: Equatable {
        var select = 0
        var candidate = 0

        subscript(side: ComparePair.Side) -> Int {
            get { side == .select ? select : candidate }
            set { if side == .select { select = newValue } else { candidate = newValue } }
        }
    }

    private enum LinkMode {
        case unlinked
        /// What separate panning left between the panes, as the select's view to the candidate's.
        case linked(ViewLink)
    }

    private(set) var pair: ComparePair?
    let select = ComparePane(side: .select)
    let candidate = ComparePane(side: .candidate)

    private(set) var cullPulse = SidePulse()

    @ObservationIgnored private let folder: FolderModel
    @ObservationIgnored private let loupe: LoupeController
    @ObservationIgnored private let plan = PrefetchPlan()
    @ObservationIgnored private var direction = PrefetchPlan.Direction.forward

    /// `⇧Z` (V-09): a zoom or a pan on one pane moves the other. On at first; the choice stays for the session.
    private var linkMode: LinkMode = .linked(ViewLink())
    var linked: Bool {
        if case .linked = linkMode { return true }
        return false
    }

    init(folder: FolderModel, loupe: LoupeController) {
        self.folder = folder
        self.loupe = loupe
        for side in [ComparePair.Side.select, .candidate] {
            pane(side).configure = { [weak self] canvas in
                guard let self else { return }
                canvas.stickyZoom = self.loupe.stickyZoom
                canvas.onViewChange = { [weak self] state in self?.viewChanged(on: side, to: state) }
                self.loupe.applyOverlays(to: canvas)
            }
            pane(side).onShown = { [weak self] in self?.developPending() }
        }
    }

    /// Both panes' canvases while Compare is up, for the overlays (`F`, `H`, `S`).
    var canvases: [LoupeView] { isActive ? [select.canvas, candidate.canvas].compactMap { $0 } : [] }

    func pane(_ side: ComparePair.Side) -> ComparePane { side == .select ? select : candidate }

    var isActive: Bool { pair != nil }

    // MARK: entering and leaving

    /// `C`. From Grid, two selected photos compare those two; otherwise (and from Loupe) the active photo and the
    /// next. False when the folder has fewer than two photos shown.
    func begin(from mode: ViewMode) -> Bool {
        let urls = folder.visible.map(\.url)
        let selected = mode == .grid ? urls.filter { folder.selection.contains($0) } : []
        guard let started = ComparePair.start(selected: selected, current: folder.currentURL, in: urls) else {
            announce("Compare needs at least two photos")
            return false
        }
        pair = started
        direction = .forward
        if case .linked = linkMode { linkMode = .linked(ViewLink()) }
        folder.setCurrent(started.activeURL)
        refresh(token: nil)
        announce("Compare. Select \(name(of: started.select)), candidate \(name(of: started.candidate)). \(started.active.title) is active")
        return true
    }

    /// Compare went behind Grid or Loupe.
    func end() {
        pair = nil
        developChain?.cancel()
        developChain = nil
        select.clear()
        candidate.clear()
    }

    // MARK: keys

    /// `←` `→` `Home` `End`: the active side moves on.
    func step(_ step: FolderModel.Step) {
        guard var next = pair else { return }
        let urls = folder.visible.map(\.url)
        let token = Perf.begin(.keyToFrame)
        if next.step(step, in: urls) {
            direction = step == .previous || step == .first ? .backward : .forward
            commit(next, token: token)
            announceActive()
        } else {
            Perf.end(token)
            announce(step == .next || step == .last ? "Last photo" : "First photo")
        }
    }

    /// `⇥`.
    func switchSide() {
        guard var next = pair else { return }
        next.switchSide()
        commit(next, token: nil)
        announceActive()
    }

    /// A click on a pane makes it the active side.
    func activate(_ side: ComparePair.Side) {
        guard var next = pair, next.active != side else { return }
        next.activate(side)
        commit(next, token: nil)
        announceActive()
    }

    /// `↓`.
    func swap() {
        guard var next = pair else { return }
        let token = Perf.begin(.keyToFrame)
        next.swap()
        commit(next, token: token)
        announce("Swapped. Select \(name(of: next.select)), candidate \(name(of: next.candidate))")
    }

    /// `↑`.
    func advance() {
        guard var next = pair else { return }
        let token = Perf.begin(.keyToFrame)
        if next.advance(in: folder.visible.map(\.url)) {
            direction = .forward
            commit(next, token: token)
            announce("Next pair. Select \(name(of: next.select)), candidate \(name(of: next.candidate))")
        } else {
            Perf.end(token)
            announce("Last pair")
        }
    }

    /// A cull key acts on the active side. With `advance` (`⇧`, including `⇧X`) the side then moves to the next
    /// photo; the destination is chosen first, from the list as it is before the decision hides anything.
    func cull(_ action: CullAction, advance: Bool) {
        guard let current = pair else { return }
        let token = Perf.begin(.cullFeedback)
        let urls = folder.visible.map(\.url)
        let url = current.activeURL
        let destination = advance ? current.destination(.next, in: urls) : nil
        guard let decision = folder.apply(action, toAll: [url]) else {
            Perf.end(token)
            return
        }
        let photoName = name(of: url)
        confirm(side: current.active,
                phrase: "\(current.active.title), \(photoName), \(decision.summary)", token: token)
        var next = current
        if advance, let destination { next.show(destination, in: folder.visible.map(\.url)); direction = .forward }
        commit(next.reconciled(in: folder.visible.map(\.url)) ?? next, token: nil)
        if advance { announceActive() }
    }

    /// ⌘Z and ⇧⌘Z. The restored photo is shown, as in Loupe: on its own side if it is on one, else on the active side.
    func undo() {
        guard let name = folder.undoName else { return }
        restored("Undid \(name)", url: folder.undo())
    }

    func redo() {
        guard let name = folder.redoName else { return }
        restored("Redid \(name)", url: folder.redo())
    }

    private func restored(_ verb: String, url: URL?) {
        guard let url, var next = pair, let photo = folder.photos.first(where: { $0.url == url }) else { return }
        let urls = folder.visible.map(\.url)
        if url == next.url(of: next.active.other) { next.switchSide() } else { next.show(url, in: urls) }
        commit(next, token: nil)
        confirm(side: next.active,
                phrase: "\(verb). \(photo.name), \(photo.decision.summary)", token: Perf.begin(.cullFeedback))
    }

    /// The filter, the sort or the folder changed under the panes.
    func listChanged() {
        guard let current = pair else { return }
        guard let fixed = current.reconciled(in: folder.visible.map(\.url)) else {
            // Fewer than two photos are left: Compare has nothing to compare.
            announce("Fewer than two photos are shown")
            return
        }
        if fixed != current { commit(fixed, token: nil) }
    }

    // MARK: zoom, pan and link (V-09)

    /// The zoom and pan commands act on the active pane; while linked, the other pane follows.
    private var activeCanvas: LoupeView? {
        guard let pair else { return nil }
        let canvas = pane(pair.active).canvas
        return canvas?.window == nil ? nil : canvas
    }

    func toggleZoom() { activeCanvas?.toggleZoom(token: Perf.begin(.zoom)) }
    func setZoom(_ level: ZoomLevel) { activeCanvas?.setZoom(level, token: Perf.begin(.zoom)) }
    func stepZoom(_ direction: ZoomDirection) { activeCanvas?.stepZoom(direction, token: Perf.begin(.zoom)) }
    func pan(_ direction: PanDirection, page: Bool) { activeCanvas?.pan(direction, page: page) }

    /// `⇧Z`. Linking again keeps the offset the panes have now (V-09/Q1); if their zooms differ, the active pane's zoom
    /// goes to the other.
    func toggleLink() {
        guard let pair else { return }
        switch linkMode {
        case .linked:
            linkMode = .unlinked
        case .unlinked:
            var newLink = ViewLink()
            if let lead = pane(pair.active).canvas, let follower = pane(pair.active.other).canvas {
                let leader = lead.viewState
                let fromActive = ViewLink(leader: leader, follower: follower.viewState)
                newLink = pair.active == .select ? fromActive : fromActive.reversed
                follower.apply(linkFrom(pair.active, link: newLink).follower(of: leader))
            }
            linkMode = .linked(newLink)
        }
        let phrase = linked ? "Zoom and pan linked" : "Zoom and pan unlinked"
        announce(phrase)
        HUD.shared.show(phrase)
    }

    private func linkFrom(_ side: ComparePair.Side, link: ViewLink) -> ViewLink { side == .select ? link : link.reversed }

    /// A pane's view moved by a key, a scroll, a pinch or a drag: the other pane follows while linked.
    private func viewChanged(on side: ComparePair.Side, to state: ViewState) {
        guard case .linked(let link) = linkMode, isActive, let follower = pane(side.other).canvas else { return }
        follower.apply(linkFrom(side, link: link).follower(of: state))
    }

    /// `R`: Compare always shows the developed RAW, so there is nothing to toggle.
    func toggleRaw() {
        guard loupe.canDevelop else { announce("RAW decode is off in Settings"); return }
        announce("Compare always shows the RAW")
    }

    /// Develops every RAW pane that still shows its preview, the active one first (the cache decodes one RAW at a
    /// time). A photo that fails is not tried again until it is shown again.
    private func developPending() {
        guard loupe.canDevelop, developChain == nil else { return }
        developChain = Task { [weak self] in
            var tried: Set<URL> = []
            while !Task.isCancelled, let self, let pair {
                let next = [pair.active, pair.active.other].map(pane).first {
                    $0.isRaw && $0.developState == .preview && $0.canvas != nil && !tried.contains($0.shown?.url ?? URL(fileURLWithPath: "/"))
                }
                guard let next, let url = next.shown?.url else { break }
                tried.insert(url)
                await next.develop(cache: loupe.rawCache) { self.announce($0) }?.value
            }
            self?.developChain = nil
        }
    }

    @ObservationIgnored private var developChain: Task<Void, Never>?

    /// The lens correction setting changed (V-19); the cache is already empty. Each pane goes back to its preview and
    /// develops again with the new setting.
    func lensCorrectionChanged() {
        guard isActive else { return }
        developChain?.cancel()
        developChain = nil
        select.showPreview()
        candidate.showPreview()
        developPending()
    }

    /// For the `R` menu item's check mark.
    var anyDeveloped: Bool { [select, candidate].contains { $0.developState != .preview } }

    // MARK: loading

    private func commit(_ next: ComparePair, token: Perf.Token?) {
        pair = next
        folder.setCurrent(next.activeURL)
        refresh(token: token)
    }

    /// Both panes show what the pair says. The active side's load carries the key-to-frame token.
    private func refresh(token: Perf.Token?) {
        guard let pair else { return }
        var token = token
        for side in [pair.active, pair.active.other] {
            guard let photo = folder.photos.first(where: { $0.url == pair.url(of: side) }) else { continue }
            load(photo, in: pane(side), other: pair.url(of: side.other), token: side == pair.active ? token.take() : nil)
        }
        if let leftover = token { Perf.end(leftover) }
    }

    private func load(_ photo: Photo, in pane: ComparePane, other: URL, token: Perf.Token?) {
        let visible = folder.visible
        let index = visible.firstIndex { $0.url == photo.url }
        let neighbors = (index.map { plan.indices(current: $0, count: visible.count, direction: direction, slow: false) } ?? [])
            .map { FrameLoader.compareKey(for: visible[$0]) }
        let otherKey = folder.photos.first { $0.url == other }.map(FrameLoader.compareKey(for:))
        let loupe = loupe
        pane.show(photo, prefetch: (otherKey.map { [$0] } ?? []) + neighbors, pipeline: loupe.pipeline, folder: folder,
                  exif: { await loupe.exifInfo(for: $0) }, token: token)
    }

    // MARK: confirmation

    private func name(of url: URL) -> String { folder.photos.first { $0.url == url }?.name ?? url.lastPathComponent }

    private func announceActive() {
        guard let pair else { return }
        let url = pair.activeURL
        let decision = folder.decision(for: url)
        announce("\(pair.active.title), \(name(of: url))" + (decision.map { $0.isUndecided ? "" : ", \($0.summary)" } ?? ""))
    }

    private func confirm(side: ComparePair.Side, phrase: String, token: Perf.Token) {
        cullPulse[side] += 1
        endAtNextDisplayFrame(token)
        announce(phrase)
    }

    private func announce(_ phrase: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: phrase, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Ends the interval on the first display-link tick after the state change, i.e. the next display frame.
    private func endAtNextDisplayFrame(_ token: Perf.Token) {
        guard let view = NSApp.keyWindow?.contentView else { Perf.end(token); return }
        let ticker = FrameTicker(token)
        ticker.link = view.displayLink(target: ticker, selector: #selector(FrameTicker.tick(_:)))
        ticker.link?.add(to: .main, forMode: .common)
    }
}

private extension Optional where Wrapped == Perf.Token {
    /// Hands the token to the first caller; later callers get nil.
    mutating func take() -> Perf.Token? {
        defer { self = nil }
        return self
    }
}
