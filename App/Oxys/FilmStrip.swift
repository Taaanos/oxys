import AppKit
import Canvas
import Diagnostics
import Imaging
import Library
import SwiftUI

/// The film strip's SwiftUI side (V-20): the scroll view the controller builds, and a hairline on top that marks
/// where the picture area ends. The band is layout, so it never overlays the photo.
struct FilmStripView: View {
    let controller: FilmStripController

    var body: some View {
        FilmStripRepresentable(controller: controller)
            .frame(height: FilmStripGeometry.bandHeight)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Film strip")
    }
}

private struct FilmStripRepresentable: NSViewRepresentable {
    let controller: FilmStripController

    func makeNSView(context: Context) -> NSScrollView { controller.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) {}
    static func dismantleNSView(_ view: NSScrollView, coordinator: ()) {}
}

/// A scroll view that never takes the keyboard and turns the wheel into a sideways scroll. A scroll moves the
/// strip and not the active photo; `onScroll` tells the controller the strip is no longer centered on it.
private final class FilmStripScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onScroll: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func scrollWheel(with event: NSEvent) {
        let sideways = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard sideways != 0 else { return }
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let clip = contentView
        let width = (documentView?.frame.width ?? 0) - clip.bounds.width
        let x = min(max(clip.bounds.origin.x - sideways * unit, 0), max(width, 0))
        guard x != clip.bounds.origin.x else { return }
        clip.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(clip)
        onScroll?()
    }
}

private final class FilmStripCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

private final class FilmStripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("filmstrip-item")
    override func loadView() { view = GridCellView() }
}

/// The film strip: one row of small thumbnails around the active photo in Loupe, with the Grid's cell and badges.
/// It shows `FolderModel.visible`, follows the active photo with a cut, and is an indicator: a click makes a
/// cell the active photo, and nothing else on it is interactive.
@MainActor
final class FilmStripController: NSObject, NSCollectionViewDataSource {
    /// The thumbnail edge in pixels: an 80 pt cell at 2x.
    static let edge = 160
    /// How long after the last key press the strip's loads may start again.
    private static let resumeDelay: Duration = .milliseconds(100)

    private let folder: FolderModel
    private let loader = GridThumbnailLoader(store: FrameLoader.sharedThumbnails, concurrency: 2,
                                             priority: .utility, budget: 16 << 20,
                                             sourceAtLeast: 512)
    private var scrollView: FilmStripScrollView?
    private var collectionView: NSCollectionView?
    private var layout: NSCollectionViewFlowLayout?
    private var boundsObserver: Any?
    private var isObserving = false

    private var photos: [Photo] = []
    private var indexByURL: [URL: Int] = [:]
    private var indexByShownURL: [URL: Int] = [:]
    private var shownCurrent: URL?
    private var shownFolder: URL?
    private var wantedRange: Range<Int> = 0..<0
    private var scrolledAway = false
    private var resumeTask: Task<Void, Never>?
    private var refreshToken: Perf.Token?
    /// The active cell's thumbnail seen through the glass lens, made once per photo that becomes active (V-20).
    private var lensed: (key: LensKey, image: CGImage)?

    private struct LensKey: Equatable {
        let thumbnail: GridThumbnailLoader.Key
        let decision: Decision
        let isPair: Bool
    }
    private static let lensStyle: GlassLens.Style = {
        var style = GlassLens.Style()
        style.strength = 0.09
        style.rimWidth = 0.15
        return style
    }()

    init(folder: FolderModel) {
        self.folder = folder
        super.init()
        loader.onResolved = { [weak self] key in self?.resolved(key) }
    }

    // MARK: building

    func makeView() -> NSScrollView {
        detach()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = FilmStripGeometry.spacing
        layout.itemSize = NSSize(width: FilmStripGeometry.cellSize, height: FilmStripGeometry.cellSize)

        let collection = FilmStripCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.isSelectable = false
        collection.backgroundColors = [NSColor(white: LoupeView.canvasGray, alpha: 1)]
        collection.register(FilmStripItem.self, forItemWithIdentifier: FilmStripItem.identifier)

        let scroll = FilmStripScrollView()
        scroll.onLayout = { [weak self] in self?.widthChanged() }
        scroll.onScroll = { [weak self] in self?.scrolledAway = true }
        scroll.documentView = collection
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: LoupeView.canvasGray, alpha: 1)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWanted() }
        }
        self.layout = layout
        collectionView = collection
        scrollView = scroll

        photos = folder.visible
        reindex()
        shownCurrent = folder.currentURL
        if shownFolder != folder.folder { loader.reset(); shownFolder = folder.folder }
        applyInsets()
        isObserving = true
        observe()
        DispatchQueue.main.async { [weak self] in
            self?.recenter()
            self?.refreshWanted(force: true)
        }
        return scroll
    }

    func detach() {
        isObserving = false
        resumeTask?.cancel()
        resumeTask = nil
        loader.setPaused(false)
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        if let token = refreshToken { Perf.end(token) }
        refreshToken = nil
        scrollView = nil
        collectionView = nil
        layout = nil
        wantedRange = 0..<0
    }

    // MARK: keys

    /// Every key press, held keys included: strip loads wait until the keys stop, so they never compete with the
    /// frame load (V-20). A scrolled strip goes back to the active photo.
    func keyPressed() {
        guard scrollView != nil else { return }
        loader.setPaused(true)
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.resumeDelay)
            guard !Task.isCancelled else { return }
            self?.loader.setPaused(false)
        }
        if scrolledAway { recenter() }
    }

    // MARK: geometry

    private var geometry: FilmStripGeometry { FilmStripGeometry(width: scrollView?.contentView.bounds.width ?? 800) }

    private func applyInsets() {
        let g = geometry
        let lead = g.leading(count: photos.count)
        layout?.sectionInset = NSEdgeInsets(top: FilmStripGeometry.verticalInset, left: lead,
                                            bottom: FilmStripGeometry.verticalInset, right: lead)
        layout?.invalidateLayout()
    }

    private func widthChanged() {
        guard scrollView != nil else { return }
        applyInsets()
        if !scrolledAway { recenter() }
        refreshWanted()
    }

    /// A cut to the active photo: no animation.
    private func recenter() {
        guard let scrollView, let collectionView else { return }
        collectionView.layoutSubtreeIfNeeded()
        scrolledAway = false
        let g = geometry
        let x = g.offset(centering: folder.currentIndex ?? 0, count: photos.count)
        guard x != scrollView.contentView.bounds.origin.x else { return }
        scrollView.contentView.scroll(to: NSPoint(x: x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: thumbnails

    private func key(for photo: Photo) -> GridThumbnailLoader.Key {
        .init(frame: FrameLoader.key(for: photo), edge: Self.edge)
    }

    private func refreshWanted(force: Bool = false) {
        guard let scrollView, !photos.isEmpty else { return }
        let g = geometry
        let range = g.visibleRange(offset: scrollView.contentView.bounds.origin.x, count: photos.count)
        let starved = loader.isIdle && !range.allSatisfy { loader.isResolved(key(for: photos[$0])) }
        guard force || starved || range != wantedRange else { return }
        wantedRange = range
        if let token = refreshToken { Perf.end(token) }
        refreshToken = Perf.begin(.filmstripRefresh)
        let center = scrolledAway ? (range.lowerBound + range.upperBound) / 2 : (folder.currentIndex ?? range.lowerBound)
        let order = g.order(visible: range, count: photos.count, center: center)
        loader.want(order.map { key(for: photos[$0]) })
        // Everything visible is cached already: the cells were drawn with the cut.
        if range.allSatisfy({ loader.isResolved(key(for: photos[$0])) }) { endRefresh() }
    }

    private func endRefresh() {
        guard let token = refreshToken else { return }
        Perf.end(token)
        refreshToken = nil
    }

    private func resolved(_ key: GridThumbnailLoader.Key) {
        if let index = indexByShownURL[key.frame.url] { refresh(index: index) }
        if wantedRange.contains(where: { indexByShownURL[key.frame.url] == $0 }) { endRefresh() }
    }

    // MARK: observation

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = folder.visible
            _ = folder.currentURL
        } onChange: { [weak self] in
            // Runs before the change lands; look at the folder once it has.
            Task { @MainActor in self?.folderChanged() }
        }
    }

    private func folderChanged() {
        guard isObserving else { return }
        defer { observe() }
        let new = folder.visible
        let old = photos
        let sameList = new.count == old.count && zip(new, old).allSatisfy { $0.url == $1.url }
        photos = new
        if shownFolder != folder.folder { loader.reset(); shownFolder = folder.folder }
        if !sameList {
            reindex()
            applyInsets()
            collectionView?.reloadData()
            shownCurrent = folder.currentURL
            recenter()
            refreshWanted(force: true)
            return
        }
        for i in new.indices where new[i].decision != old[i].decision { refresh(index: i) }
        if shownCurrent != folder.currentURL {
            let previous = shownCurrent
            shownCurrent = folder.currentURL
            if let previous, let i = indexByURL[previous] { refresh(index: i) }
            if let current = shownCurrent, let i = indexByURL[current] { refresh(index: i) }
            recenter()
            refreshWanted(force: true)
        }
    }

    private func reindex() {
        indexByURL = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.url, $0) })
        indexByShownURL = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.shownURL, $0) })
    }

    // MARK: cells

    private func refresh(index: Int) {
        guard let item = collectionView?.item(at: IndexPath(item: index, section: 0)), let cell = item.view as? GridCellView
        else { return }
        configure(cell, index: index)
    }

    private func configure(_ cell: GridCellView, index: Int) {
        let photo = photos[index]
        let key = key(for: photo)
        let isCurrent = photo.url == folder.currentURL
        let content = GridCellView.Content(
            url: photo.url, image: isCurrent ? lens(for: key, photo: photo) : loader.image(for: key), failed: loader.isFailed(key),
            decision: photo.decision,
            isCurrent: isCurrent, isSelected: false,
            label: isCurrent ? "\(photo.cellLabel), current photo" : photo.cellLabel, isPair: photo.isPair, showsRing: false,
            badgePlate: false, badgesInImage: isCurrent)
        cell.configure(content) { [weak self] url, _, _ in self?.folder.setCurrent(url) }
    }

    /// The thumbnail through the glass lens, with the decision drawn under the glass, or the plain thumbnail while it
    /// has not loaded. Made on the first draw of the active cell (about a millisecond) and again when its decision
    /// changes; kept until another photo is active.
    private func lens(for key: GridThumbnailLoader.Key, photo: Photo) -> CGImage? {
        guard let plain = loader.image(for: key) else { return nil }
        let lensKey = LensKey(thumbnail: key, decision: photo.decision, isPair: photo.isPair)
        if let lensed, lensed.key == lensKey { return lensed.image }
        let edge = Self.edge
        let image = GlassLens.apply(to: plain, edge: edge, background: LoupeView.canvasGray, style: Self.lensStyle) { ctx in
            Self.drawDecision(photo.decision, isPair: photo.isPair, into: ctx, edge: edge)
        }
        lensed = image.map { (lensKey, $0) }
        return image ?? plain
    }

    /// How far above the cell's bottom edge the badges sit on the lens: past the bending rim, so it does not cut them.
    private static let lensBadgeLift: CGFloat = 16

    /// Draws the badges (and, for a reject, the veil that dims the picture) into the lens bitmap, in cell points.
    private static func drawDecision(_ decision: Decision, isPair: Bool, into ctx: CGContext, edge: Int) {
        let cell = FilmStripGeometry.cellSize
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Points, top-left origin, like the cell's own badge view.
        ctx.translateBy(x: 0, y: CGFloat(edge))
        ctx.scaleBy(x: CGFloat(edge) / cell, y: -CGFloat(edge) / cell)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if decision.isReject {
            NSColor(white: LoupeView.canvasGray, alpha: 0.65).setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
        }
        GridBadgeView.drawBadges(decision: decision, isPair: isPair,
                                 in: NSRect(x: 4, y: cell - GridBadgeView.height - Self.lensBadgeLift, width: cell - 8, height: GridBadgeView.height),
                                 plate: false)
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { photos.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmStripItem.identifier, for: indexPath)
        if let cell = item.view as? GridCellView { configure(cell, index: indexPath.item) }
        return item
    }
}
