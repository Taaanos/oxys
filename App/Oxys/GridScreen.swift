import AppKit
import Canvas
import Diagnostics
import Imaging
import Library
import SwiftUI

/// A scroll view that reports each layout pass and window change, so Grid can notice a viewport that
/// settled after its first thumbnail request.
final class GridScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onLayout?() }
    }
}

/// Grid's SwiftUI side: the scroll view the controller builds, nothing more.
struct GridScreen: NSViewRepresentable {
    let controller: GridController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    func makeNSView(context: Context) -> NSScrollView { controller.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) {}
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.controller.detach() }

    final class Coordinator {
        let controller: GridController
        init(controller: GridController) { self.controller = controller }
    }
}

/// Grid (M-12): an AppKit collection view with a flow layout. The folder model stays the source of truth;
/// this watches it and redraws only the cells whose decision changed.
@MainActor
final class GridController: NSObject, NSCollectionViewDataSource {
    private let folder: FolderModel
    private let loupe: LoupeController
    private let loader = GridThumbnailLoader(store: FrameLoader.sharedThumbnails)

    private var scrollView: NSScrollView?
    private var collectionView: NSCollectionView?
    private var layout: NSCollectionViewFlowLayout?
    private var boundsObserver: Any?

    private var photos: [Photo] = []
    private var indexByURL: [URL: Int] = [:]
    private var shownCurrent: URL?
    private var wantedRange: Range<Int> = 0..<0
    private var wantedEdge = 0
    private var lastLowerBound = 0
    private var direction: GridPrefetch.Direction = .down
    private var firstScreenToken: Perf.Token?
    private var isObserving = false
    private var shownSelection = Set<URL>()

    /// 0 to 4, into `GridGeometry.itemSizes`; remembered between launches.
    private(set) var step: Int = {
        let stored = UserDefaults.standard.object(forKey: "gridThumbnailStep") as? Int
        return GridGeometry.clampedStep(stored ?? GridGeometry.defaultStep)
    }()

    var onOpen: (() -> Void)?

    init(folder: FolderModel, loupe: LoupeController) {
        self.folder = folder
        self.loupe = loupe
        super.init()
        loader.onResolved = { [weak self] key in self?.resolved(key) }
    }

    // MARK: building

    func makeView() -> NSScrollView {
        detach()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        layout.itemSize = NSSize(width: size, height: size)

        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.isSelectable = false
        collection.backgroundColors = [NSColor(white: LoupeView.canvasGray, alpha: 1)]
        collection.register(GridItem.self, forItemWithIdentifier: GridItem.identifier)
        collection.setAccessibilityLabel("Photos")

        let scroll = GridScrollView()
        scroll.onLayout = { [weak self] in self?.viewportChanged() }
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: LoupeView.canvasGray, alpha: 1)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        }
        self.layout = layout
        collectionView = collection
        scrollView = scroll
        loupe.fallbackHost = scroll

        photos = folder.visible
        reindex()
        shownCurrent = folder.currentURL
        shownSelection = folder.selection.urls
        isObserving = true
        observe()
        // The first layout pass happens once the view is in a window; scroll to the current photo then.
        DispatchQueue.main.async { [weak self] in
            self?.scrollToCurrent()
            self?.viewportChanged(force: true)
        }
        return scroll
    }

    func detach() {
        isObserving = false
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        scrollView = nil
        collectionView = nil
        layout = nil
        if let token = firstScreenToken { Perf.end(token) }
        firstScreenToken = nil
    }

    /// A folder is being opened: the first-screen interval runs from here until its thumbnails are drawn.
    func noteOpening() {
        if let token = firstScreenToken { Perf.end(token) }
        firstScreenToken = Perf.begin(.gridFirstScreen)
        loader.reset()
        wantedRange = 0..<0
    }

    // MARK: geometry

    private var size: CGFloat { GridGeometry.itemSizes[step] }

    private var geometry: GridGeometry {
        GridGeometry(itemSize: size, width: scrollView?.contentView.bounds.width ?? 800)
    }

    private var edge: Int {
        let scale = scrollView?.window?.backingScaleFactor ?? 2
        return size * scale <= 512 ? 512 : 1024
    }

    private func key(for photo: Photo, edge: Int) -> GridThumbnailLoader.Key {
        .init(frame: FrameLoader.key(for: photo), edge: edge)
    }

    // MARK: commands

    func move(_ move: GridGeometry.Move) {
        guard !photos.isEmpty else { return }
        let from = folder.currentIndex ?? 0
        folder.setCurrent(index: geometry.moved(from: from, move, count: photos.count))
    }

    /// `⇧`-arrow: moves the active photo like the plain arrow and selects the range to it (M-19).
    func extend(_ move: GridGeometry.Move) {
        guard !photos.isEmpty else { return }
        let from = folder.currentIndex ?? 0
        folder.extendSelection(toIndex: geometry.moved(from: from, move, count: photos.count))
    }

    func resize(by delta: Int) {
        let next = GridGeometry.clampedStep(step + delta)
        guard next != step else { return }
        step = next
        UserDefaults.standard.set(step, forKey: "gridThumbnailStep")
        layout?.itemSize = NSSize(width: size, height: size)
        layout?.invalidateLayout()
        scrollToCurrent()
        viewportChanged(force: true)
        refreshAllVisible()
        announce("\(Int(size)) point thumbnails, \(geometry.columns) per row")
    }

    // MARK: observation

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = folder.visible
            _ = folder.currentURL
            _ = folder.selection
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
        if !sameList {
            reindex()
            collectionView?.reloadData()
            wantedRange = 0..<0
            shownCurrent = folder.currentURL
            shownSelection = folder.selection.urls
            scrollToCurrent()
            viewportChanged(force: true)
            return
        }
        let selection = folder.selection.urls
        if selection != shownSelection {
            for url in selection.symmetricDifference(shownSelection) { if let i = indexByURL[url] { refresh(index: i) } }
            announceSelection(selection.count)
            shownSelection = selection
        }
        for i in new.indices where new[i].decision != old[i].decision { refresh(index: i) }
        if shownCurrent != folder.currentURL {
            let previous = shownCurrent
            shownCurrent = folder.currentURL
            if let previous, let i = indexByURL[previous] { refresh(index: i) }
            if let current = shownCurrent, let i = indexByURL[current] {
                refresh(index: i)
                announce(label(for: new[i]))
            }
            scrollToCurrent()
        }
    }

    private func reindex() {
        indexByURL = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.url, $0) })
    }

    private func scrollToCurrent() {
        guard let collectionView, let index = folder.currentIndex else { return }
        collectionView.layoutSubtreeIfNeeded()
        let g = geometry
        let rect = NSRect(x: 0, y: g.rowOrigin(of: index) - g.spacing, width: 1, height: g.itemSize + 2 * g.spacing)
        collectionView.scrollToVisible(rect)
    }

    // MARK: thumbnails

    private func viewportChanged(force: Bool = false) {
        guard let scrollView, !photos.isEmpty else { return }
        let bounds = scrollView.contentView.bounds
        let g = geometry
        let range = g.visibleRange(offset: bounds.minY, height: bounds.height, count: photos.count)
        let edge = edge
        // The first pass can run before the view has its size or a window and want nothing; a later layout
        // then finds the same range. When nothing is loading and something visible is missing, ask again.
        let starved = loader.isIdle && !range.allSatisfy { loader.isResolved(key(for: photos[$0], edge: edge)) }
        guard force || starved || range != wantedRange || edge != wantedEdge else { return }
        if range.lowerBound != lastLowerBound { direction = range.lowerBound > lastLowerBound ? .down : .up }
        lastLowerBound = range.lowerBound
        wantedRange = range
        wantedEdge = edge
        let order = GridPrefetch.order(visible: range, count: photos.count, columns: g.columns, direction: direction)
        loader.want(order.map { key(for: photos[$0], edge: edge) })
        checkFirstScreen()
    }

    private func resolved(_ key: GridThumbnailLoader.Key) {
        if let index = indexByURL[key.frame.url] { refresh(index: index) }
        checkFirstScreen()
    }

    private func checkFirstScreen() {
        guard let token = firstScreenToken, !wantedRange.isEmpty else { return }
        let edge = wantedEdge
        guard wantedRange.allSatisfy({ loader.isResolved(key(for: photos[$0], edge: edge)) }) else { return }
        Perf.end(token)
        firstScreenToken = nil
    }

    // MARK: cells

    private var visibleItems: [(index: Int, cell: GridCellView)] {
        guard let collectionView else { return [] }
        return collectionView.visibleItems().compactMap { item in
            guard let cell = item.view as? GridCellView, let path = collectionView.indexPath(for: item) else { return nil }
            return (path.item, cell)
        }
    }

    private func refresh(index: Int) {
        guard let item = collectionView?.item(at: IndexPath(item: index, section: 0)), let cell = item.view as? GridCellView
        else { return }
        cell.configure(from: self, index: index)
    }

    private func refreshAllVisible() {
        for item in visibleItems { item.cell.configure(from: self, index: item.index) }
    }

    /// What a cell shows for the photo at `index`: its thumbnail (or one of the other size while that loads).
    fileprivate func presentation(at index: Int) -> GridCellView.Content {
        let photo = photos[index]
        let primary = key(for: photo, edge: edge)
        let other = key(for: photo, edge: edge == 512 ? 1024 : 512)
        return .init(url: photo.url, image: loader.image(for: primary) ?? loader.image(for: other),
                     failed: loader.isFailed(primary), decision: photo.decision,
                     isCurrent: photo.url == folder.currentURL, isSelected: folder.selection.contains(photo.url),
                     label: label(for: photo))
    }

    private func label(for photo: Photo) -> String {
        [photo.name, photo.decision.isUndecided ? nil : photo.decision.summary].compactMap { $0 }.joined(separator: ", ")
    }

    fileprivate func clicked(_ url: URL, open: Bool, modifiers: NSEvent.ModifierFlags) {
        if open {
            folder.setCurrent(url)
            onOpen?()
        } else if modifiers.contains(.shift) {
            folder.click(url, mode: .range)
        } else if modifiers.contains(.command) {
            folder.click(url, mode: .toggle)
        } else {
            // A plain click makes the photo active and ends any selection, so a cull key cannot reach photos
            // the photographer no longer sees as chosen (M-19).
            folder.setCurrent(url)
            folder.selectNone()
        }
    }

    private func announceSelection(_ count: Int) {
        announce(count == 0 ? "Selection cleared" : count == 1 ? "1 photo selected" : "\(count) photos selected")
    }

    private func announce(_ phrase: String) {
        guard let scrollView else { return }
        NSAccessibility.post(element: scrollView, notification: .announcementRequested, userInfo: [
            .announcement: phrase, .priority: NSAccessibilityPriorityLevel.low.rawValue,
        ])
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { photos.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GridItem.identifier, for: indexPath)
        (item.view as? GridCellView)?.configure(from: self, index: indexPath.item)
        return item
    }
}

// MARK: - cell

final class GridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("grid-item")
    override func loadView() { view = GridCellView() }
}

/// One thumbnail: a gray tile, the image fitted inside it, a ring when it is the active photo, and a strip of
/// badges along the bottom (stars, label letter, reject mark) that never relies on color alone.
@MainActor
final class GridCellView: NSView {
    struct Content {
        let url: URL
        let image: CGImage?
        let failed: Bool
        let decision: Decision
        let isCurrent: Bool
        let isSelected: Bool
        let label: String
    }

    private let imageLayer = CALayer()
    private let ringLayer = CALayer()
    private let tintLayer = CALayer()
    private let checkLayer = CATextLayer()
    private let badges = GridBadgeView()
    private(set) var url: URL?
    private weak var controller: GridController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        layer?.cornerRadius = 3
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        tintLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        tintLayer.isHidden = true
        layer?.addSublayer(tintLayer)
        ringLayer.borderColor = NSColor.controlAccentColor.cgColor
        ringLayer.cornerRadius = 3
        layer?.addSublayer(ringLayer)
        // A checkmark as well as the tint, so selection never relies on color alone.
        checkLayer.string = "✓"
        checkLayer.fontSize = 13
        checkLayer.alignmentMode = .center
        checkLayer.foregroundColor = NSColor.white.cgColor
        checkLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        checkLayer.cornerRadius = 9
        checkLayer.isHidden = true
        layer?.addSublayer(checkLayer)
        addSubview(badges)
        setAccessibilityRole(.cell)
        setAccessibilityElement(true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        ringLayer.frame = bounds
        tintLayer.frame = bounds
        checkLayer.frame = NSRect(x: bounds.width - 24, y: bounds.height - 24, width: 18, height: 18)
        checkLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        badges.frame = NSRect(x: 0, y: 0, width: bounds.width, height: GridBadgeView.height)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func configure(from controller: GridController, index: Int) {
        self.controller = controller
        let content = controller.presentation(at: index)
        url = content.url
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = content.image
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        imageLayer.opacity = content.decision.isReject ? 0.35 : 1
        ringLayer.borderWidth = content.isCurrent ? 3 : 0
        tintLayer.isHidden = !content.isSelected
        checkLayer.isHidden = !content.isSelected
        CATransaction.commit()
        badges.decision = content.failed ? nil : content.decision
        badges.failed = content.failed
        setAccessibilityLabel(content.failed ? "\(content.label), no preview" : content.label)
        setAccessibilitySelected(content.isCurrent || content.isSelected)
    }

    override func mouseDown(with event: NSEvent) {
        guard let url else { return }
        controller?.clicked(url, open: event.clickCount >= 2, modifiers: event.modifierFlags)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let url else { return false }
        controller?.clicked(url, open: true, modifiers: [])
        return true
    }
}

/// The badge strip. Draws nothing for an undecided photo.
private final class GridBadgeView: NSView {
    static let height: CGFloat = 22

    var decision: Decision? { didSet { if decision != oldValue { needsDisplay = true } } }
    var failed = false { didSet { if failed != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if failed {
            draw("No preview", at: NSPoint(x: 6, y: 4), color: .white, font: .systemFont(ofSize: 11))
            return
        }
        guard let decision, !decision.isUndecided else { return }
        NSColor.black.withAlphaComponent(Plate.opacity).setFill()
        bounds.fill()
        var x: CGFloat = 6
        if decision.isReject {
            let mark = NSRect(x: x, y: 3, width: 16, height: 16)
            NSColor(srgbRed: 0.78, green: 0.06, blue: 0.12, alpha: 1).setFill() // white ✕ at 5.9:1
            NSBezierPath(roundedRect: mark, xRadius: 4, yRadius: 4).fill()
            draw("✕", in: mark, color: .white, font: .systemFont(ofSize: 11, weight: .bold))
            x += 22
        } else if decision.stars > 0 {
            let text = String(repeating: "★", count: decision.stars)
            x += draw(text, at: NSPoint(x: x, y: 3), color: .systemYellow, font: .systemFont(ofSize: 13)) + 6
        }
        if let label = decision.label {
            let chip = NSRect(x: bounds.width - 22, y: 3, width: 16, height: 16)
            label.nsColor.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
            draw(String(label.letter), in: chip, color: .black,
                 font: .monospacedSystemFont(ofSize: 11, weight: .bold))
        }
    }

    @discardableResult
    private func draw(_ text: String, at point: NSPoint, color: NSColor, font: NSFont) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        string.draw(at: point)
        return string.size().width
    }

    private func draw(_ text: String, in rect: NSRect, color: NSColor, font: NSFont) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

private extension ColorLabel {
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }
}
