import Foundation
import Sidecar
import Testing
@testable import Library

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Uncached Reference Oracle for FolderModel

/// Naive, uncached reference model of `FolderModel`'s observable state (decisions, filter/sort + G-6 keep-current,
/// selection, navigation, undo/redo). Recomputes `visible` from scratch on every access so any `visibleCache`,
/// `visibleVersion`, or state-transition bug in `FolderModel` stands out immediately.
private struct FolderModelOracle {
    struct Entry {
        let url: URL
        let name: String
        var decision: Decision
        var unknownLabel: String?
    }

    struct Change {
        let url: URL
        let before: Decision
        let after: Decision
        let unknownBefore: String?
        let unknownAfter: String?
    }

    var catalog: [Entry]
    var currentURL: URL?
    var filter = PhotoFilter()
    var selected: Set<URL> = []
    var anchor: URL?
    var undoStack: [[Change]] = []
    var redoStack: [[Change]] = []

    init(photos: [Photo], currentURL: URL?) {
        self.catalog = photos.map {
            Entry(url: $0.url, name: $0.name, decision: $0.decision, unknownLabel: $0.sidecar.unknownLabel)
        }
        self.currentURL = currentURL
    }

    private func matches(_ entry: Entry, with f: PhotoFilter) -> Bool {
        guard f.isNarrowing else { return true }
        let d = entry.decision
        if !f.stars.isEmpty, d.isReject || !f.stars.contains(d.stars) { return false }
        if !f.labels.isEmpty || f.noLabel {
            let ok = d.label.map(f.labels.contains) ?? f.noLabel
            if !ok { return false }
        }
        switch f.rejects {
        case .showAll: break
        case .hideRejected: if d.isReject { return false }
        case .onlyRejected: if !d.isReject { return false }
        }
        let q = f.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, entry.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }

    private func ordered(_ list: [Entry], with f: PhotoFilter) -> [Entry] {
        switch (f.sortKey, f.ascending) {
        case (.captureTime, true): return list
        case (.captureTime, false): return list.reversed()
        case (.filename, let up):
            return list.sorted {
                let cmp = $0.name.localizedStandardCompare($1.name)
                return up ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
    }

    /// Recomputed from scratch (zero caching) with G-6 `keeping: currentURL`.
    var visible: [Entry] {
        guard filter.isNarrowing || !filter.isDefaultSort else { return catalog }
        let kept = filter.isNarrowing ? currentURL : nil
        let filtered = filter.isNarrowing ? catalog.filter { matches($0, with: filter) || $0.url == kept } : catalog
        return ordered(filtered, with: filter)
    }

    var visibleURLs: [URL] { visible.map(\.url) }

    var currentIndex: Int? {
        guard let currentURL else { return nil }
        return visible.firstIndex { $0.url == currentURL }
    }

    var cullTargets: [URL] {
        if selected.isEmpty { return currentURL.map { [$0] } ?? [] }
        return visible.filter { selected.contains($0.url) }.map(\.url)
    }

    mutating func move(_ step: FolderModel.Step) {
        let shown = visible
        guard !shown.isEmpty else { return }
        let from = currentIndex ?? 0
        let to = switch step {
        case .next: min(from + 1, shown.count - 1)
        case .previous: max(from - 1, 0)
        case .first: 0
        case .last: shown.count - 1
        }
        guard to != from || currentURL == nil else { return }
        currentURL = shown[to].url
    }

    mutating func setCurrent(_ url: URL) {
        guard url != currentURL, visible.contains(where: { $0.url == url }) else { return }
        currentURL = url
    }

    mutating func setCurrent(index: Int) {
        let shown = visible
        guard shown.indices.contains(index) else { return }
        setCurrent(shown[index].url)
    }

    mutating func selectAll() { selected = Set(visibleURLs) }
    mutating func selectNone() { selected = []; anchor = nil }
    mutating func invertSelection() { selected = Set(visibleURLs).subtracting(selected) }
    mutating func deselectCurrent() { if let currentURL { selected.remove(currentURL) } }

    mutating func select(matching criteria: SelectionCriteria) {
        selected = Set(visible.filter { criteria.matches($0.decision) }.map(\.url))
    }

    mutating func click(_ url: URL, mode: FolderModel.ClickMode) {
        let shown = visibleURLs
        guard shown.contains(url) else { return }
        switch mode {
        case .replace:
            selected = [url]
            anchor = url
        case .toggle:
            if !selected.insert(url).inserted { selected.remove(url) }
            anchor = url
        case .range:
            extend(to: url, in: shown)
        }
        currentURL = url
    }

    mutating func extendSelection(toIndex index: Int) {
        let shown = visibleURLs
        guard shown.indices.contains(index) else { return }
        extend(to: shown[index], in: shown)
        currentURL = shown[index]
    }

    private mutating func extend(to url: URL, in shown: [URL]) {
        guard let end = shown.firstIndex(of: url) else { return }
        let start = (anchor ?? currentURL).flatMap { shown.firstIndex(of: $0) } ?? end
        if anchor == nil { anchor = shown[start] }
        selected = Set(shown[min(start, end)...max(start, end)])
    }

    mutating func updateFilter(_ change: (inout PhotoFilter) -> Void) {
        var next = filter
        change(&next)
        guard next != filter else { return }
        filter = next
        // Without keep-current: changing the filter moves currentURL if hidden.
        let filtered = next.isNarrowing ? catalog.filter { matches($0, with: next) } : catalog
        let shown = ordered(filtered, with: next)
        let shownSet = Set(shown.map(\.url))
        selected.formIntersection(shownSet)
        if let a = anchor, !shownSet.contains(a) { anchor = nil }
        if let cur = currentURL, !shownSet.contains(cur) {
            if let from = catalog.firstIndex(where: { $0.url == cur }) {
                currentURL = catalog[from...].first(where: { shownSet.contains($0.url) })?.url
                    ?? catalog[..<from].last(where: { shownSet.contains($0.url) })?.url
            } else {
                currentURL = shown.first?.url
            }
        } else if currentURL == nil {
            currentURL = shown.first?.url
        }
    }

    mutating func apply(_ action: CullAction, toAll urls: [URL]) {
        var changes: [Change] = []
        for url in urls {
            guard let i = catalog.firstIndex(where: { $0.url == url }) else { continue }
            let before = catalog[i].decision
            let after = action.applied(to: before)
            guard after != before else { continue }
            let uBefore = catalog[i].unknownLabel
            if after.label != before.label { catalog[i].unknownLabel = nil }
            catalog[i].decision = after
            changes.append(Change(url: url, before: before, after: after,
                                  unknownBefore: uBefore, unknownAfter: catalog[i].unknownLabel))
        }
        if !changes.isEmpty {
            undoStack.append(changes)
            if undoStack.count > UndoStack.limit { undoStack.removeFirst(undoStack.count - UndoStack.limit) }
            redoStack.removeAll()
        }
    }

    mutating func undo() {
        guard let step = undoStack.popLast() else { return }
        redoStack.append(step)
        var first: URL?
        for c in step {
            guard let i = catalog.firstIndex(where: { $0.url == c.url }) else { continue }
            catalog[i].decision = c.before
            catalog[i].unknownLabel = c.unknownBefore
            first = first ?? c.url
        }
        if let first { currentURL = first }
    }

    mutating func redo() {
        guard let step = redoStack.popLast() else { return }
        undoStack.append(step)
        var first: URL?
        for c in step {
            guard let i = catalog.firstIndex(where: { $0.url == c.url }) else { continue }
            catalog[i].decision = c.after
            catalog[i].unknownLabel = c.unknownAfter
            first = first ?? c.url
        }
        if let first { currentURL = first }
    }
}

// MARK: - Suite: Stateful Differential Oracle Tests for FolderModel

@Suite @MainActor struct FolderModelOracleTests {
    private func waitUntilLoaded(_ model: FolderModel) async {
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<500 where model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func randomAction(rng: inout SeededRNG) -> CullAction {
        switch rng.int(in: 0...4) {
        case 0...1: .setRating(rng.int(in: 0...5))
        case 2: .stepRating(rng.bool() ? 1 : -1)
        case 3: .toggleLabel(rng.pick(ColorLabel.allCases))
        default: .toggleReject
        }
    }

    private func randomCriteria(rng: inout SeededRNG) -> SelectionCriteria {
        let rating: SelectionCriteria.Rating? = switch rng.int(in: 0...5) {
        case 0: nil
        case 1: .exactly(rng.int(in: 1...5))
        case 2: .atLeast(rng.int(in: 1...5))
        case 3: .atMost(rng.int(in: 1...5))
        case 4: .unrated
        default: .rejected
        }
        let label: SelectionCriteria.Label? = switch rng.int(in: 0...2) {
        case 0: nil
        case 1: .unlabeled
        default: .color(rng.pick(ColorLabel.allCases))
        }
        return SelectionCriteria(rating: rating, label: label)
    }

    private func makeFilterMutation(rng: inout SeededRNG) -> (inout PhotoFilter) -> Void {
        switch rng.int(in: 0...9) {
        case 0:
            return { $0.isOn.toggle() }
        case 1:
            let n = rng.int(in: 0...5)
            let extend = rng.bool(probability: 1, outOf: 4)
            let toggle = rng.bool(probability: 1, outOf: 3)
            let orMore = rng.bool(probability: 1, outOf: 4)
            return { $0.clickStar(n, extend: extend, toggle: toggle, orMore: orMore) }
        case 2:
            let n = rng.int(in: 0...5)
            return { $0.setMinimumStars(n) }
        case 3:
            let c = rng.pick(ColorLabel.allCases)
            return { if !$0.labels.insert(c).inserted { $0.labels.remove(c) } }
        case 4:
            return { $0.noLabel.toggle() }
        case 5:
            let r = rng.pick(RejectFilter.allCases)
            return { $0.rejects = r }
        case 6:
            let q = rng.pick(["", "IMG", "00", "A_", "B_", "NO_MATCH", "arw"])
            return { $0.search = q }
        case 7:
            let key = rng.pick(SortKey.allCases)
            return { $0.sortKey = key }
        case 8:
            return { $0.ascending.toggle() }
        default:
            return {
                $0.stars = []
                $0.labels = []
                $0.noLabel = false
                $0.rejects = .showAll
                $0.search = ""
                $0.isOn = true
            }
        }
    }

    @Test(arguments: [UInt64(0xD001), 0xD002, 0xD003, 0xD004, 0xD005, 0xD006])
    func folderModelMatchesNaiveOracleAcrossRandomizedSessions(seed: UInt64) async throws {
        var rng = SeededRNG(seed: seed)
        let folder = try TempFolder()
        defer { folder.remove() }

        let fileNames = [
            "IMG_001.ARW", "IMG_002.ARW", "IMG_003.ARW", "IMG_003.JPG",
            "IMG_004.ARW", "IMG_005.ARW", "IMG_006.ARW", "IMG_007.ARW", "IMG_007.JPG",
            "A_01.CR3", "B_02.NEF", "C_03.RAF", "D_04.DNG", "E_05.ARW",
        ]
        for name in fileNames { try folder.add(name) }

        // Seed two pre-existing sidecars: one standard, one with a foreign unknown label ("Select").
        let xmp1 = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="3" xmp:Label="Red"/></rdf:RDF></x:xmpmeta>"#
        let xmp2 = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2" xmp:Label="Select"/></rdf:RDF></x:xmpmeta>"#
        try Data(xmp1.utf8).write(to: folder.url.appendingPathComponent("IMG_001.xmp"))
        try Data(xmp2.utf8).write(to: folder.url.appendingPathComponent("IMG_002.xmp"))

        let model = FolderModel()
        model.open(folder.url)
        await waitUntilLoaded(model)

        var oracle = FolderModelOracle(photos: model.photos, currentURL: model.currentURL)

        for step in 0..<350 {
            switch rng.int(in: 0...17) {
            case 0...2:
                // Navigate via Step
                let s = rng.pick([FolderModel.Step.next, .previous, .first, .last])
                model.move(s)
                oracle.move(s)

            case 3:
                // Jump directly to a visible index (or intentionally out of bounds)
                let idx = rng.int(in: -1...max(0, oracle.visible.count))
                model.setCurrent(index: idx)
                oracle.setCurrent(index: idx)

            case 4...6:
                // Apply a cull action to current photo
                let action = randomAction(rng: &rng)
                if let url = model.currentURL {
                    model.apply(action)
                    oracle.apply(action, toAll: [url])
                }

            case 7...8:
                // Apply a cull action to all cullTargets (selection or current)
                let action = randomAction(rng: &rng)
                let targets = model.cullTargets
                model.apply(action, toAll: targets)
                oracle.apply(action, toAll: targets)

            case 9:
                // Click in Grid (replace / toggle / range)
                let shown = oracle.visibleURLs
                if !shown.isEmpty {
                    let target = rng.pick(shown)
                    let mode = rng.pick([FolderModel.ClickMode.replace, .toggle, .range])
                    model.click(target, mode: mode)
                    oracle.click(target, mode: mode)
                }

            case 10:
                // Shift-arrow range extend
                let shown = oracle.visibleURLs
                if !shown.isEmpty {
                    let idx = rng.int(in: 0...(shown.count - 1))
                    model.extendSelection(toIndex: idx)
                    oracle.extendSelection(toIndex: idx)
                }

            case 11:
                // Bulk selection operations
                switch rng.int(in: 0...4) {
                case 0: model.selectAll(); oracle.selectAll()
                case 1: model.selectNone(); oracle.selectNone()
                case 2: model.invertSelection(); oracle.invertSelection()
                case 3: model.deselectCurrent(); oracle.deselectCurrent()
                default:
                    let criteria = randomCriteria(rng: &rng)
                    model.select(matching: criteria)
                    oracle.select(matching: criteria)
                }

            case 12...14:
                // Filter / sort mutation
                let mutate = makeFilterMutation(rng: &rng)
                model.updateFilter(mutate)
                oracle.updateFilter(mutate)

            case 15:
                // Undo
                model.undo()
                oracle.undo()

            case 16:
                // Redo
                model.redo()
                oracle.redo()

            default:
                // SessionState JSON round-trip check
                if let state = model.sessionState(mode: "loupe") {
                    let encoded = try JSONEncoder().encode(state)
                    let decoded = try JSONDecoder().decode(SessionState.self, from: encoded)
                    #expect(decoded == state, "seed=\(hex(seed)) step=\(step): SessionState JSON round-trip mismatch")
                }
            }

            // --- Every-step differential assertions against uncached oracle ---
            #expect(model.visible.map(\.url) == oracle.visibleURLs,
                    "seed=\(hex(seed)) step=\(step): visible mismatch (cache/filter/G-6)")
            #expect(model.currentURL == oracle.currentURL,
                    "seed=\(hex(seed)) step=\(step): currentURL mismatch")
            #expect(model.currentIndex == oracle.currentIndex,
                    "seed=\(hex(seed)) step=\(step): currentIndex mismatch")
            #expect(model.photos.map(\.decision) == oracle.catalog.map(\.decision),
                    "seed=\(hex(seed)) step=\(step): catalog decisions mismatch")
            #expect(model.photos.map(\.sidecar.unknownLabel) == oracle.catalog.map(\.unknownLabel),
                    "seed=\(hex(seed)) step=\(step): unknownLabel mismatch")
            #expect(model.selection.urls == oracle.selected,
                    "seed=\(hex(seed)) step=\(step): selection.urls mismatch")
            #expect(model.selection.anchor == oracle.anchor,
                    "seed=\(hex(seed)) step=\(step): selection.anchor mismatch")
            #expect(model.cullTargets == oracle.cullTargets,
                    "seed=\(hex(seed)) step=\(step): cullTargets mismatch")
            #expect((model.undoName != nil) == !oracle.undoStack.isEmpty,
                    "seed=\(hex(seed)) step=\(step): undoStack emptiness mismatch")
            #expect((model.redoName != nil) == !oracle.redoStack.isEmpty,
                    "seed=\(hex(seed)) step=\(step): redoStack emptiness mismatch")
        }

        // Flush sidecar writes and verify disk matches final in-memory state.
        model.flushSidecarWrites()
        let fm = FileManager.default
        let dirContents = try fm.contentsOfDirectory(atPath: folder.url.path)
        let temps = dirContents.filter { $0.contains(SidecarWriter.tempMarker) }
        #expect(temps.isEmpty, "seed=\(hex(seed)): leaked temp files \(temps)")

        for photo in model.photos {
            let sidecarURL = folder.url.appendingPathComponent(SidecarNaming.stem.fileName(for: photo.name))
            let exists = fm.fileExists(atPath: sidecarURL.path)
            if !photo.decision.isUndecided || photo.sidecar.unknownLabel != nil {
                #expect(exists, "seed=\(hex(seed)): expected sidecar on disk for \(photo.name)")
            }
            if exists {
                let props = try XMPReader.parse(Data(contentsOf: sidecarURL))
                #expect(props.rating == photo.decision.rating,
                        "seed=\(hex(seed)): sidecar rating mismatch for \(photo.name)")
                let expectedLabel = photo.decision.label?.name ?? photo.sidecar.unknownLabel
                #expect(props.label == expectedLabel,
                        "seed=\(hex(seed)): sidecar label mismatch for \(photo.name)")
            }
        }
    }
}
