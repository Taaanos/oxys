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
    let side: ComparePair.Side
    private(set) var shown: Photo?
    private(set) var shownPixels: (width: Int, height: Int)?
    private(set) var failure: String?
    private(set) var zoomInfo: ZoomInfo?
    private(set) var exif: ExifInfo?
    /// The pane's own RAW state (V-09): `R` develops both panes, and each keeps its own state until its photo changes.
    private(set) var developState = LoupeController.DevelopState.preview
    /// How much of the frame is clipped, while an overlay is on; nil until the analysis is back.
    private(set) var clippingStats: ClippingStats?

    @ObservationIgnored private var frame: LoupeFrame?
    @ObservationIgnored private var developTask: Task<Void, Never>?
    /// Set by the controller: gives a new canvas its zoom rules, its overlays and its link to the other pane.
    @ObservationIgnored var configure: ((LoupeView) -> Void)?
    @ObservationIgnored private var wanted: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The view is built after the pane is asked to load; it shows the frame as soon as it exists.
    @ObservationIgnored weak var canvas: LoupeView? {
        didSet {
            guard let canvas, canvas !== oldValue else { return }
            canvas.onZoomChange = { [weak self] in self?.zoomInfo = $0 }
            canvas.onClippingStats = { [weak self] in self?.clippingStats = $0 }
            canvas.focusAnchor = exif?.maker?.focusAnchor.map { CGPoint(x: $0.x, y: $0.y) }
            configure?(canvas)
            canvas.setAccessibilityLabel(accessibilityName)
            if let frame { canvas.show(frame.image) } else if failure != nil { canvas.show(nil) }
        }
    }

    init(side: ComparePair.Side) { self.side = side }

    var isRaw: Bool { shown?.format.isRaw == true && failure == nil }

    var truthBadge: TruthBadge? {
        guard failure == nil, let photo = shown, let pixels = shownPixels, let zoom = zoomInfo else { return nil }
        let source: TruthBadge.Source = !photo.format.isRaw ? .file : developState == .raw ? .raw : developState == .developing ? .developing : .preview
        return TruthBadge.make(source: source, percent: zoom.percent, isFit: zoom.level.isFit,
                               longEdge: max(pixels.width, pixels.height),
                               sensorLongEdge: RawPolicy.longEdge(ofDimensions: exif?.dimensions))
    }

    var accessibilityName: String {
        guard let photo = shown else { return "\(side.title) pane, empty" }
        return failure.map { "\(side.title) pane, \(photo.name). \($0)" }
            ?? "\(side.title) pane, \(photo.name)" + (shownPixels.map { ", \($0.width) by \($0.height) pixels" } ?? "")
    }

    /// Shows `photo`. A newer call cancels an older one; the previous frame stays up until the new one is ready.
    /// `prefetch` must hold the other pane's key: the pipeline cancels anything that is neither target nor prefetch.
    func show(_ photo: Photo, prefetch: [FrameKey], pipeline: FramePipeline<LoupeFrame>, folder: FolderModel,
              exif readExif: @escaping @Sendable (URL) async -> ExifInfo?, token: Perf.Token?) {
        if wanted == photo.url, shown?.url == photo.url {
            if let token { Perf.end(token) }
            return
        }
        task?.cancel()
        stopDeveloping()
        wanted = photo.url
        let key = FrameLoader.key(for: photo)
        task = Task { [weak self] in
            async let info = readExif(photo.url)
            let result: Result<LoupeFrame?, any Error>
            do { result = .success(try await pipeline.frame(for: key, prefetch: prefetch)) } catch { result = .failure(error) }
            let exif = await info
            guard let self, !Task.isCancelled, wanted == photo.url else {
                if let token { Perf.end(token) }
                return
            }
            switch result {
            case .success(let loaded?):
                frame = loaded
                shown = photo
                shownPixels = (loaded.width, loaded.height)
                failure = nil
                developState = .preview
                self.exif = exif
                canvas?.focusAnchor = exif?.maker?.focusAnchor.map { CGPoint(x: $0.x, y: $0.y) }
                folder.setPreview(PreviewInfo(pixelWidth: loaded.width, pixelHeight: loaded.height), for: photo.url)
                canvas?.setAccessibilityLabel(accessibilityName)
                canvas?.show(loaded.image, keyToFrame: token)
            case .success(nil):
                if let token { Perf.end(token) }   // superseded inside the pipeline
            case .failure(let error):
                frame = nil
                shown = photo
                shownPixels = nil
                failure = (error as? PreviewError)?.localizedDescription ?? error.localizedDescription
                developState = .preview
                self.exif = exif
                zoomInfo = nil
                canvas?.setAccessibilityLabel(accessibilityName)
                canvas?.show(nil, keyToFrame: token)
            }
        }
    }

    // MARK: develop (V-09)

    /// Decodes the RAW and swaps it in over the preview; the view keeps its place on screen (as in Loupe, V-02).
    /// `done` hears the result for VoiceOver.
    /// The returned task ends when this pane is done (the cache decodes one RAW at a time, so the caller waits).
    func develop(cache: RawFrameCache<LoupeFrame>, done: @escaping @MainActor (String) -> Void) -> Task<Void, Never>? {
        guard let photo = shown, isRaw, developState == .preview, canvas != nil else { return nil }
        developState = .developing
        let key = FrameLoader.key(for: photo)
        let minLongEdge = max(512, shownPixels.map { max($0.width, $0.height) } ?? 0)
        let task = Task { [weak self] in
            let result: Result<LoupeFrame?, any Error>
            do {
                result = .success(try await cache.develop(key) { try FrameLoader.develop($0, minLongEdge: minLongEdge) })
            } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, shown?.url == photo.url else { return }
            developTask = nil
            switch result {
            case .success(let developed?):
                developState = .raw
                shownPixels = (developed.width, developed.height)
                canvas?.setAccessibilityLabel("\(side.title) pane, \(photo.name), RAW, \(developed.width) by \(developed.height) pixels")
                canvas?.show(developed.image, sameZoom: true, keepView: true)
                done("\(side.title), RAW")
            case .success(nil):
                developState = .preview
            case .failure:
                developState = .preview
                done("\(side.title), this RAW cannot be developed. Showing the preview")
            }
        }
        developTask = task
        return task
    }

    /// Back to the preview, or stop the decode that is running.
    func showPreview() {
        let wasDeveloped = developState == .raw
        stopDeveloping()
        guard wasDeveloped, let frame else { return }
        shownPixels = (frame.width, frame.height)
        canvas?.setAccessibilityLabel(accessibilityName)
        canvas?.show(frame.image, sameZoom: true, keepView: true)
    }

    private func stopDeveloping() {
        developTask?.cancel()
        developTask = nil
        developState = .preview
    }

    /// Compare ended: nothing stays on the canvas for the next entry to flash.
    func clear() {
        task?.cancel()
        task = nil
        stopDeveloping()
        clippingStats = nil
        wanted = nil
        frame = nil
        shown = nil
        shownPixels = nil
        failure = nil
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
    private(set) var pair: ComparePair?
    let select = ComparePane(side: .select)
    let candidate = ComparePane(side: .candidate)

    /// The confirmation over the active pane after a cull key; nil when it has timed out.
    struct Badge: Equatable {
        let id: Int
        let side: ComparePair.Side
        let decision: Decision
        let photoName: String?
    }
    private(set) var badge: Badge?
    @ObservationIgnored private var badgeCount = 0
    @ObservationIgnored private var badgeTimeout: Task<Void, Never>?

    @ObservationIgnored private let folder: FolderModel
    @ObservationIgnored private let loupe: LoupeController
    @ObservationIgnored private let plan = PrefetchPlan()
    @ObservationIgnored private var direction = PrefetchPlan.Direction.forward

    /// `⇧Z` (V-09): a zoom or a pan on one pane moves the other. On at first; the choice stays for the session.
    private(set) var linked = true
    /// What separate panning left between the panes, as the select's view to the candidate's.
    @ObservationIgnored private var link = ViewLink()

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
        link = ViewLink()
        folder.setCurrent(started.activeURL)
        refresh(token: nil)
        announce("Compare. Select \(name(of: started.select)), candidate \(name(of: started.candidate)). \(started.active.title) is active")
        return true
    }

    /// Compare went behind Grid or Loupe.
    func end() {
        pair = nil
        badge = nil
        badgeTimeout?.cancel()
        developChain?.cancel()
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
        confirm(decision, side: current.active, photoName: advance ? photoName : nil,
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
        confirm(photo.decision, side: next.active, photoName: photo.name,
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
        linked.toggle()
        if linked, let lead = pane(pair.active).canvas, let follower = pane(pair.active.other).canvas {
            let leader = lead.viewState
            let fromActive = ViewLink(leader: leader, follower: follower.viewState)
            link = pair.active == .select ? fromActive : fromActive.reversed
            follower.apply(linkFrom(pair.active).follower(of: leader))
        }
        announce(linked ? "Zoom and pan linked" : "Zoom and pan unlinked")
    }

    private func linkFrom(_ side: ComparePair.Side) -> ViewLink { side == .select ? link : link.reversed }

    /// A pane's view moved by a key, a scroll, a pinch or a drag: the other pane follows while linked.
    private func viewChanged(on side: ComparePair.Side, to state: ViewState) {
        guard linked, isActive, let follower = pane(side.other).canvas else { return }
        follower.apply(linkFrom(side).follower(of: state))
    }

    /// `R`: develops the RAW on both panes, or, when they are developed or developing, goes back to the previews.
    func toggleRaw() {
        guard loupe.canDevelop else { announce("RAW decode is off in Settings"); return }
        let raws = [select, candidate].filter(\.isRaw)
        guard !raws.isEmpty else { announce("Neither photo is a RAW file"); return }
        if raws.contains(where: { $0.developState == .preview }) {
            announce(raws.count == 2 ? "Developing both" : "Developing \(raws[0].side.title)")
            // One decode at a time: the active pane first.
            let ordered = raws.sorted { $0.side == pair?.active && $1.side != pair?.active }
            developChain = Task { [weak self] in
                for pane in ordered {
                    guard !Task.isCancelled, let self else { return }
                    await pane.develop(cache: loupe.rawCache) { self.announce($0) }?.value
                }
            }
        } else {
            developChain?.cancel()
            for pane in raws { pane.showPreview() }
            loupe.rawCache.cancelInflight()
            announce("Previews")
        }
    }

    @ObservationIgnored private var developChain: Task<Void, Never>?

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
            .map { FrameLoader.key(for: visible[$0]) }
        let otherKey = folder.photos.first { $0.url == other }.map(FrameLoader.key(for:))
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

    private func confirm(_ decision: Decision, side: ComparePair.Side, photoName: String?, phrase: String, token: Perf.Token) {
        badgeCount += 1
        badge = Badge(id: badgeCount, side: side, decision: decision, photoName: photoName)
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
