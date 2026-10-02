import AppKit
import Canvas
import Commands
import Darwin
import Diagnostics
import Imaging
import Library
import Metadata

/// M-26 measurement driver. With `OXYS_BENCH=<scenario>` and `OXYS_OPEN=<folder>` set, the app opens the
/// folder, runs one scenario through the same commands the keys call, writes its numbers with `Perf.record`
/// (set `OXYS_PERF_LOG=<file>`; read it with `PerfTool log`) and quits. Does nothing otherwise.
///
/// Scenarios: `open` (folder open to first image), `nav-prefetched`, `nav-cold`, `nav-held` (30 steps a second),
/// `scrub` (1,000 frames, memory), `cull`, `zoom`, `develop`, `develop-always` (⇧R then browsing, V-03), `develop-cancel` (V-02),
/// `compare` (V-08: checks the pair rules, then steps both sides), `compare-link` (V-09: linked zoom and pan, overlays and `R` on both panes),
/// `compare-view` (Compare stays up for 40 s, for a screenshot), `overlays`, `peaking` (V-06: F on and off, then browsing with it on),
/// `peaking-still` (the overlay on one photo), `peaking-view` (stays up for 40 s; `OXYS_BENCH_ZOOM=1` goes to 1:1 first),
/// `clipping` and `clipping-still` (the same for H and S, V-07), `grid` (scroll 10,000 files), `idle`,
/// `load-memory` (P-02: the working memory of one frame load), `zoom-from-screen` (P-03: 1:1 over a screen-size frame).
/// `scripts/perf-gate.sh` (P-01) runs the ones in `scripts/perf-targets.tsv` against the PRD limits.
/// `OXYS_BENCH_DELAY_MS=<n>` makes every frame load wait n ms first, as slow media would (see `FrameLoader`).
@MainActor
enum PerfBench {
    private static let environment = ProcessInfo.processInfo.environment
    static var scenario: String? { environment["OXYS_BENCH"] }

    static func start(model: AppModel, folder url: URL) {
        guard let scenario else { return }
        Task { @MainActor in
            await run(scenario, model: model, url: url)
            Perf.record("done", 1)
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    private static func run(_ scenario: String, model: AppModel, url: URL) async {
        let folder = model.folder, loupe = model.loupe, commands = model.commands
        // The monitor's own timers would show up as idle CPU, so the idle run goes without it.
        let monitor = Monitor()
        if scenario != "idle" { monitor.start() }
        defer { if scenario != "idle" { monitor.finish() } }

        let opened = ContinuousClock.now
        model.open(url)   // always lands in Grid, as for a user
        if scenario != "grid" { commands.mode = .loupe }
        // Folder open to first image: the first preview on the canvas (Loupe) or a settled Grid.
        if scenario != "grid" {
            while loupe.shown == nil, opened.duration(to: .now) < .seconds(30) { try? await Task.sleep(for: .milliseconds(1)) }
            Perf.record("folder-open-to-first-image", ms(opened.duration(to: .now)))
        }
        while folder.isReadingCaptureTimes || folder.isReadingSidecars { try? await Task.sleep(for: .milliseconds(20)) }
        Perf.record("folder-photos", Double(folder.photos.count))
        await settle(.seconds(2))
        if scenario != "grid" { commands.perform("nav.first"); await settle(.seconds(1)) }

        switch scenario {
        case "open": break
        case "nav-prefetched":
            // One step every 300 ms leaves the prefetch time to fill the next frames.
            for _ in 0..<200 { commands.perform("nav.next"); await settle(.milliseconds(300)) }
        case "nav-cold":
            // The cache is emptied before each jump to a far photo, so no frame and no prefetch is ready.
            for i in 0..<60 {
                loupe.reset()
                await settle(.milliseconds(300))
                commands.perform(i % 2 == 0 ? "nav.last" : "nav.first")
                await settle(.milliseconds(700))
            }
        case "nav-held":
            await held(commands, steps: 400, every: .milliseconds(33))
        case "scrub":
            // 1,000 frames in a row, fast enough to stay ahead of the loads, slow enough to load most of them.
            await held(commands, steps: 1000, every: .milliseconds(100))
        case "cull":
            let ids = ["cull.rate.1", "cull.rate.2", "cull.rate.3", "cull.rate.4", "cull.rate.5", "cull.reject", "cull.label.red"]
            for i in 0..<300 {
                commands.perform(CommandID(rawValue: ids[i % ids.count]))
                await settle(.milliseconds(60))
                commands.perform("nav.next")
                await settle(.milliseconds(120))
            }
        case "compare":
            await compareWalk(model)
        case "compare-link":
            await compareLinkWalk(model)
        case "compare-view":
            // Compare stays up for 40 s so a screenshot can look at it.
            commands.perform("compare.enter"); await settle(.seconds(1))
            commands.perform("cull.rate.3"); await settle(.seconds(40))
        case "zoom":
            for _ in 0..<60 {
                commands.perform("zoom.actual"); await settle(.milliseconds(500))
                commands.perform("zoom.fit"); await settle(.milliseconds(500))
                commands.perform("nav.next"); await settle(.milliseconds(300))
            }
        case "zoom-from-screen":
            // P-03: a cold photo, then 1:1 while only its screen-size frame is up. The badge must say so at once, and
            // the full-size frame must replace the frame in place. `full-after-zoom-ms` is the zoom command to the
            // full frame; `screen-frame-at-zoom` and `badge-warns-at-zoom` count the runs where the zoom found the
            // screen-size frame up and the badge warning.
            for i in 0..<20 {
                loupe.reset(); await settle(.milliseconds(300))
                commands.perform(i % 2 == 0 ? "nav.last" : "nav.first")
                let waiting = ContinuousClock.now
                while !loupe.showingScreenSize, waiting.duration(to: .now) < .seconds(3) { await settle(.milliseconds(1)) }
                let screenUp = loupe.showingScreenSize
                Perf.record("screen-frame-at-zoom", screenUp ? 1 : 0)
                let began = ContinuousClock.now
                commands.perform("zoom.actual")
                await settle(.milliseconds(30))
                Perf.record("badge-warns-at-zoom", loupe.truthBadge?.text == "Loading full size" ? 1 : 0)
                while loupe.showingScreenSize, began.duration(to: .now) < .seconds(3) { await settle(.milliseconds(1)) }
                Perf.record("full-after-zoom-ms", ms(began.duration(to: .now)))
                await settle(.milliseconds(400))
                commands.perform("zoom.fit"); await settle(.milliseconds(300))
            }
        case "develop":
            // R, wait for the RAW on screen, R back, next photo. `raw-ready` is press to developed frame (V-02).
            for _ in 0..<20 {
                await nextRaw(model)
                let began = ContinuousClock.now
                commands.perform("zoom.raw")
                while loupe.developState != .raw, began.duration(to: .now) < .seconds(15) { try? await Task.sleep(for: .milliseconds(1)) }
                if loupe.developState == .raw { Perf.record("raw-ready", ms(began.duration(to: .now))) } else { Perf.record("raw-timeout", 1) }
                await settle(.milliseconds(300))
                commands.perform("zoom.raw"); await settle(.milliseconds(200))
                commands.perform("nav.next"); await settle(.milliseconds(500))
            }
        case "develop-always":
            // ⇧R, then key-repeat browsing (the previews must keep up while neighbors develop), then steps with a
            // pause: the neighbor ahead should be developed, so `raw-ready` after a step is short (V-03).
            commands.perform("zoom.rawAlways"); await settle(.milliseconds(500))
            await held(commands, steps: 300, every: .milliseconds(33))
            await settle(.seconds(3))
            for _ in 0..<20 {
                let began = ContinuousClock.now
                commands.perform("nav.next")
                while loupe.developState != .raw, began.duration(to: .now) < .seconds(15) { try? await Task.sleep(for: .milliseconds(1)) }
                if loupe.developState == .raw { Perf.record("raw-ready", ms(began.duration(to: .now))) } else { Perf.record("raw-timeout", 1) }
                await settle(.seconds(2))
            }
        case "develop-cancel":
            // R and then on to the next photo before the decode ends: `raw-wasted` must not appear in the log.
            for _ in 0..<30 {
                await nextRaw(model)
                commands.perform("zoom.raw"); await settle(.milliseconds(Int(environment["OXYS_BENCH_CANCEL_MS"] ?? "") ?? 30))
                commands.perform("nav.next"); await settle(.milliseconds(1000))
            }
        case "overlays":
            for _ in 0..<60 {
                for id in ["info.histogram", "info.cycle"] {
                    let began = ContinuousClock.now
                    commands.perform(CommandID(rawValue: id))
                    await DisplayTick.next()
                    Perf.record(id, ms(began.duration(to: .now)))
                    await settle(.milliseconds(250))
                }
            }
        case "clipping":
            // H and S on and off (`clipping-on` is the command to the next display frame; the first one runs the
            // analysis), then browsing with both overlays on.
            for _ in 0..<40 {
                for id in ["clipping-on", "clipping-off"] {
                    let began = ContinuousClock.now
                    commands.perform("overlay.highlights")
                    await DisplayTick.next()
                    Perf.record(id, ms(began.duration(to: .now)))
                    await settle(.milliseconds(250))
                }
                commands.perform("nav.next"); await settle(.milliseconds(300))
            }
            commands.perform("overlay.highlights"); commands.perform("overlay.shadows"); await settle(.milliseconds(300))
            await held(commands, steps: 300, every: .milliseconds(33))
            commands.perform("overlay.highlights"); commands.perform("overlay.shadows")
        case "clipping-still":
            // The overlay on and off on one photo: the cost of the analysis and the draw alone.
            for _ in 0..<100 {
                for id in ["clipping-on", "clipping-off"] {
                    let began = ContinuousClock.now
                    commands.perform("overlay.highlights")
                    await DisplayTick.next()
                    Perf.record(id, ms(began.duration(to: .now)))
                    await settle(.milliseconds(150))
                }
            }
        case "peaking-view":
            // The overlay stays on for 40 s so a screenshot can look at it. `OXYS_BENCH_ZOOM=1` goes to 1:1 first.
            if environment["OXYS_BENCH_ZOOM"] == "1" { commands.perform("zoom.actual"); await settle(.milliseconds(500)) }
            commands.perform("overlay.peaking")
            await settle(.seconds(40))
        case "peaking-still":
            // The overlay on and off on one photo: the cost of the analysis and the draw, with no other work going on.
            for _ in 0..<100 {
                for id in ["peaking-on", "peaking-off"] {
                    let began = ContinuousClock.now
                    commands.perform("overlay.peaking")
                    await DisplayTick.next()
                    Perf.record(id, ms(began.duration(to: .now)))
                    await settle(.milliseconds(150))
                }
            }
        case "peaking":
            // F on and off (`peaking-on` is the command to the next display frame, the first one runs the analysis),
            // then browsing with the overlay on: each frame carries its own analysis, so key-to-frame shows its cost.
            for _ in 0..<40 {
                for id in ["peaking-on", "peaking-off"] {
                    let began = ContinuousClock.now
                    commands.perform("overlay.peaking")
                    await DisplayTick.next()
                    Perf.record(id, ms(began.duration(to: .now)))
                    await settle(.milliseconds(250))
                }
                commands.perform("nav.next"); await settle(.milliseconds(300))
            }
            commands.perform("overlay.peaking"); await settle(.milliseconds(300))
            await held(commands, steps: 300, every: .milliseconds(33))
            commands.perform("overlay.peaking")
        case "grid":
            await scrollGrid(model)
        case "load-memory":
            await loadMemory(model)
        case "idle":
            // Nothing happens for 30 s; the process's CPU time over that span is the idle cost.
            let before = cpuSeconds(), began = ContinuousClock.now
            await settle(.seconds(30))
            let wall = seconds(began.duration(to: .now))
            Perf.record("idle-cpu-percent-loupe", (cpuSeconds() - before) / wall * 100)
            commands.mode = .grid
            await settle(.seconds(3))
            let beforeGrid = cpuSeconds(), gridBegan = ContinuousClock.now
            await settle(.seconds(30))
            Perf.record("idle-cpu-percent-grid", (cpuSeconds() - beforeGrid) / seconds(gridBegan.duration(to: .now)) * 100)
        default:
            Perf.record("unknown-scenario", 1)
        }
        await settle(.seconds(1))
    }

    // MARK: drivers

    /// V-08: the keys of Compare through the commands they call. First a walk with checks (`check-<name>` is 1 when it
    /// held, 0 when not), then 100 rounds of stepping both sides, swapping and advancing, so key-to-frame covers both panes.
    private static func compareWalk(_ model: AppModel) async {
        let folder = model.folder, commands = model.commands, compare = model.compare
        let urls = folder.visible.map(\.url)
        guard urls.count >= 8 else { Perf.record("check-folder-too-small", 0); return }
        func check(_ name: String, _ ok: Bool) { Perf.record("check-\(name)", ok ? 1 : 0) }
        func pair() -> (ComparePairSnapshot) {
            guard let p = compare.pair else { return ComparePairSnapshot(select: nil, candidate: nil, active: nil) }
            return ComparePairSnapshot(select: p.select, candidate: p.candidate, active: p.active)
        }
        let first = urls[0]
        folder.setCurrent(first)
        await settle(.milliseconds(500))
        commands.perform("compare.enter"); await settle(.seconds(1))
        check("enter-from-loupe", commands.mode == .compare && pair().select == urls[0] && pair().candidate == urls[1] && pair().active == .select)
        commands.perform("nav.next"); await settle(.milliseconds(500))
        check("step-skips-other-side", pair().select == urls[2] && pair().candidate == urls[1])
        commands.perform("compare.switchSide")
        check("switch-side", pair().active == .candidate && folder.currentURL == urls[1])
        commands.perform("nav.next"); await settle(.milliseconds(500))
        check("step-candidate", pair().candidate == urls[3] && pair().select == urls[2])
        commands.perform("compare.swap"); await settle(.milliseconds(500))
        check("swap", pair().select == urls[3] && pair().candidate == urls[2] && pair().active == .candidate)
        commands.perform("cull.rate.3"); await settle(.milliseconds(300))
        check("rate-active-side", folder.decision(for: urls[2])?.stars == 3 && folder.decision(for: urls[3])?.stars == 0)
        commands.perform("cull.reject", phase: .performAdvancing); await settle(.milliseconds(500))
        check("reject-advances-side", folder.decision(for: urls[2])?.isReject == true && pair().candidate == urls[4] && pair().select == urls[3])
        commands.perform("compare.advance"); await settle(.milliseconds(500))
        check("advance", pair().select == urls[4] && pair().candidate == urls[5])
        commands.perform("view.loupe"); await settle(.milliseconds(500))
        check("to-loupe-on-active", commands.mode == .loupe && folder.currentURL == urls[5])
        commands.perform("compare.enter"); await settle(.milliseconds(500))
        commands.perform("view.grid"); await settle(.milliseconds(300))
        check("to-grid", commands.mode == .grid)
        // Two selected photos compare those two (Grid).
        folder.selectNone(); folder.click(urls[6], mode: .replace); folder.click(urls[7], mode: .toggle)
        commands.perform("compare.enter"); await settle(.milliseconds(500))
        check("enter-from-selection", pair().select == urls[6] && pair().candidate == urls[7])
        for _ in 0..<100 {
            for id in ["nav.next", "compare.switchSide", "nav.next", "compare.swap", "compare.advance", "nav.previous", "compare.switchSide"] {
                commands.perform(CommandID(rawValue: id)); await settle(.milliseconds(250))
            }
        }
        commands.perform("view.grid")
    }

    /// V-09: linked zoom and pan, the overlays and `R` on both panes, through the commands the keys call. Each
    /// `check-<name>` is 1 when it held, 0 when not.
    private static func compareLinkWalk(_ model: AppModel) async {
        let folder = model.folder, commands = model.commands, compare = model.compare
        let urls = folder.visible.map(\.url)
        guard urls.count >= 4 else { Perf.record("check-folder-too-small", 0); return }
        func check(_ name: String, _ ok: Bool) { Perf.record("check-\(name)", ok ? 1 : 0) }
        func state(_ pane: ComparePane) -> ViewState? { pane.canvas?.viewState }
        func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-4 && abs(a.y - b.y) < 1e-4 }
        func moved(_ a: CGPoint, _ b: CGPoint) -> Bool { !same(a, b) }
        let select = compare.select, candidate = compare.candidate
        folder.setCurrent(urls[0])
        await settle(.milliseconds(500))
        commands.perform("compare.enter"); await settle(.seconds(1.5))
        check("linked-at-start", compare.linked)
        // Z: both sides at 1:1, at the same relative point.
        commands.perform("zoom.toggle"); await settle(.milliseconds(500))
        let a = state(select), b = state(candidate)
        check("z-both-actual-size", a?.level == .actual && b?.level == .actual)
        check("z-same-relative-point", a != nil && b != nil && same(a!.center, b!.center))
        // Linked, a pan moves both by the same amount.
        commands.perform("pan.right"); await settle(.milliseconds(300))
        let a2 = state(select), b2 = state(candidate)
        check("linked-pan-moves-both", a2 != nil && b2 != nil && moved(a!.center, a2!.center) && same(a2!.center, b2!.center))
        // Linked, a zoom step moves both.
        commands.perform("zoom.in"); await settle(.milliseconds(300))
        check("linked-zoom-step", state(select)?.level == state(candidate)?.level && state(select)?.level != a2?.level)
        commands.perform("zoom.actual"); await settle(.milliseconds(300))
        // Unlinked, each side pans on its own (the active side is the select).
        commands.perform("zoom.link"); await settle(.milliseconds(200))
        check("unlinked", !compare.linked)
        let before = (state(select), state(candidate))
        commands.perform("pan.down"); await settle(.milliseconds(300))
        let after = (state(select), state(candidate))
        check("unlinked-pans-alone", before.0 != nil && after.0 != nil && moved(before.0!.center, after.0!.center)
              && before.1?.center == after.1?.center)
        // Relinking keeps the offset the separate panning left.
        commands.perform("zoom.link"); await settle(.milliseconds(200))
        let offset = (state(candidate)!.center.x - state(select)!.center.x, state(candidate)!.center.y - state(select)!.center.y)
        check("relink-keeps-offset", offset.0 == 0 ? offset.1 != 0 : true)
        commands.perform("pan.left"); await settle(.milliseconds(300))
        let end = (state(candidate)!.center.x - state(select)!.center.x, state(candidate)!.center.y - state(select)!.center.y)
        check("relinked-pan-keeps-offset", abs(end.0 - offset.0) < 1e-4 && abs(end.1 - offset.1) < 1e-4)
        // The other side leads just as well.
        commands.perform("compare.switchSide")
        commands.perform("pan.up"); await settle(.milliseconds(300))
        check("candidate-leads", moved(after.1!.center, state(candidate)!.center) && moved(state(select)!.center, a2!.center))
        // Overlays reach both panes.
        commands.perform("overlay.peaking"); await settle(.milliseconds(800))
        check("peaking-on-both", select.canvas?.peaking != nil && candidate.canvas?.peaking != nil)
        commands.perform("overlay.peaking"); await settle(.milliseconds(300))
        check("peaking-off-both", select.canvas?.peaking == nil && candidate.canvas?.peaking == nil)
        commands.perform("overlay.highlights"); commands.perform("overlay.shadows"); await settle(.milliseconds(800))
        check("clipping-on-both", select.canvas?.clipping != nil && candidate.canvas?.clipping != nil
              && select.clippingStats != nil && candidate.clippingStats != nil)
        commands.perform("overlay.highlights"); commands.perform("overlay.shadows"); await settle(.milliseconds(300))
        check("clipping-off-both", select.canvas?.clipping == nil && candidate.canvas?.clipping == nil)
        // R develops both RAW panes, and back.
        let raws = [select, candidate].filter(\.isRaw)
        if !raws.isEmpty {
            let began = ContinuousClock.now
            commands.perform("zoom.raw")
            for _ in 0..<100 where raws.contains(where: { $0.developState != .raw }) { await settle(.milliseconds(100)) }
            Perf.record("raw-both-ready-ms", ms(began.duration(to: .now)))
            for pane in raws { Perf.record("raw-state-\(pane.side.title.lowercased())-\(pane.developState)", 1) }
            check("r-develops-both", raws.allSatisfy { $0.developState == .raw })
            commands.perform("zoom.raw"); await settle(.milliseconds(500))
            check("r-back-to-previews", raws.allSatisfy { $0.developState == .preview })
        }
        // The EXIF line marks differences against the other photo.
        let fields = select.exif?.compareFields(against: candidate.exif) ?? []
        check("exif-line-has-values", !fields.isEmpty)
        // Stepping a side keeps the zoom and the spot (sticky), and the link follows the new photo.
        for _ in 0..<100 {
            for id in ["nav.next", "pan.right", "compare.switchSide", "nav.next", "pan.left", "zoom.fit", "zoom.actual", "compare.switchSide"] {
                commands.perform(CommandID(rawValue: id)); await settle(.milliseconds(250))
            }
        }
        commands.perform("view.grid")
    }

    private struct ComparePairSnapshot {
        let select: URL?
        let candidate: URL?
        let active: ComparePair.Side?
    }

    /// Steps forward until the photo on screen is a RAW (the bench folders mix in TIFF scans).
    private static func nextRaw(_ model: AppModel) async {
        if model.folder.currentIndex == model.folder.visible.count - 1 { model.commands.perform("nav.first"); await settle(.milliseconds(400)) }
        for _ in 0..<10 {
            if model.loupe.shown?.url == model.folder.currentURL, model.folder.currentPhoto?.showsRaw == true { return }
            model.commands.perform("nav.next")
            await settle(.milliseconds(400))
        }
    }

    private static func held(_ commands: CommandCenter, steps: Int, every interval: Duration) async {
        let clock = ContinuousClock()
        var next = clock.now
        for _ in 0..<steps {
            commands.perform("nav.next")
            next += interval
            try? await clock.sleep(until: next)
        }
    }

    /// Scrolls Grid from top to bottom at a fast flick twice: the first pass fills the thumbnail cache (its frames
    /// are logged apart), the second is the measurement ("thumbnails from disk cache").
    private static func scrollGrid(_ model: AppModel) async {
        for pass in ["grid-warmup-frame", "grid-frame"] {
            model.grid.scrollToTop()
            await settle(.seconds(1))
            await model.grid.scrollWithDisplayLink(pointsPerSecond: 6000) { Perf.record(pass + "-ms", $0) }
            await settle(.seconds(2))
        }
    }

    // MARK: helpers

    fileprivate static func ms(_ d: Duration) -> Double { seconds(d) * 1000 }
    fileprivate static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
    private static func settle(_ d: Duration) async { try? await Task.sleep(for: d) }

    fileprivate static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// P-02: the working memory of one frame load. Twelve photos spread over the folder load one at a time, straight
    /// through `FrameLoader.load` (no cache, no prefetch); a 1 ms sampler keeps the footprint peak of each load.
    /// `load-working-mb` is that peak less the footprint before the load and less the finished frame, so it is
    /// the memory the load needs on top of its result. `load-working-ratio` divides it by the frame's cost (frames of 20 MB or more).
    private static func loadMemory(_ model: AppModel) async {
        model.loupe.reset()
        await settle(.seconds(2))
        let photos = model.folder.photos
        guard photos.count >= 24 else { Perf.record("load-memory-folder-too-small", 1); return }
        let keys = stride(from: 10, to: photos.count, by: photos.count / 12).prefix(12).map { FrameLoader.key(for: photos[$0]) }
        for key in keys {
            let base = footprintMB()
            let sampler = PeakSampler()
            sampler.start()
            let cost = await Task.detached { () -> Int? in
                (try? await FrameLoader.load(key, thumbnails: FrameLoader.sharedThumbnails))?.cost
            }.value
            let peak = sampler.stop()
            guard let cost else { continue }
            let frameMB = Double(cost) / 1_048_576
            let working = max(0, peak - base - frameMB)
            Perf.record("load-frame-mb", frameMB)
            Perf.record("load-working-mb", working)
            // Under 20 MB a frame is smaller than the load's fixed overhead (a few MB), so the ratio says nothing.
            if frameMB >= 20 { Perf.record("load-working-ratio", working / frameMB) }
            await settle(.milliseconds(500))
        }
    }

    /// Polls `footprintMB` every millisecond on its own thread and keeps the highest value.
    private nonisolated final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0.0
        private var running = false

        func start() {
            lock.withLock { running = true; peak = PerfBench.footprintMB() }
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let mb = PerfBench.footprintMB()
                    lock.withLock { peak = max(peak, mb) }
                    usleep(1000)
                }
            }
        }

        func stop() -> Double {
            lock.withLock { running = false; return max(peak, PerfBench.footprintMB()) }
        }
    }

    fileprivate nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// Samples memory every 250 ms and how late a 10 ms main-thread timer fires (a blocked main thread shows as lateness).
    @MainActor
    private final class Monitor {
        private var memory: Task<Void, Never>?
        private var timer: Timer?
        private var expected = ContinuousClock.now
        private var peak = 0.0

        func start() {
            Perf.record("resident-start-mb", PerfBench.footprintMB())
            memory = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let mb = PerfBench.footprintMB()
                    self?.peak = max(self?.peak ?? 0, mb)
                    Perf.record("footprint-mb", mb)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            expected = .now + .milliseconds(10)
            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Perf.record("main-thread-lateness-ms", max(0, PerfBench.ms(self.expected.duration(to: .now))))
                    self.expected = .now + .milliseconds(10)
                }
            }
        }

        func finish() {
            memory?.cancel()
            timer?.invalidate()
            Perf.record("footprint-peak-mb", peak)
            Perf.record("footprint-end-mb", PerfBench.footprintMB())
        }
    }
}

/// Waits for the next display-link tick of the key window: the time a change needs to reach the screen, at best.
@MainActor
enum DisplayTick {
    static func next() async {
        guard let view = NSApp.keyWindow?.contentView else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ticker = Ticker(continuation)
            ticker.link = view.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
            ticker.link?.add(to: .main, forMode: .common)
        }
    }

    @MainActor
    private final class Ticker: NSObject {
        var link: CADisplayLink?
        private var continuation: CheckedContinuation<Void, Never>?
        private var keepAlive: Ticker?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
            super.init()
            keepAlive = self
        }

        @objc func tick(_ link: CADisplayLink) {
            link.invalidate()
            self.link = nil
            continuation?.resume()
            continuation = nil
            keepAlive = nil
        }
    }
}
