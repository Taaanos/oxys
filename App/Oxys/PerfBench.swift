import AppKit
import Commands
import Darwin
import Diagnostics
import Library

/// M-26 measurement driver. With `OXYS_BENCH=<scenario>` and `OXYS_OPEN=<folder>` set, the app opens the
/// folder, runs one scenario through the same commands the keys call, writes its numbers with `Perf.record`
/// (set `OXYS_PERF_LOG=<file>`; read it with `PerfTool log`) and quits. Does nothing otherwise.
///
/// Scenarios: `open` (folder open to first image), `nav-prefetched`, `nav-cold`, `nav-held` (30 steps a second),
/// `scrub` (1,000 frames, memory), `cull`, `zoom`, `develop`, `develop-cancel` (V-02), `overlays`, `grid` (scroll 10,000 files), `idle`.
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
        case "zoom":
            for _ in 0..<60 {
                commands.perform("zoom.actual"); await settle(.milliseconds(500))
                commands.perform("zoom.fit"); await settle(.milliseconds(500))
                commands.perform("nav.next"); await settle(.milliseconds(300))
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

    /// Steps forward until the photo on screen is a RAW (the bench folders mix in TIFF scans).
    private static func nextRaw(_ model: AppModel) async {
        if model.folder.currentIndex == model.folder.visible.count - 1 { model.commands.perform("nav.first"); await settle(.milliseconds(400)) }
        for _ in 0..<10 {
            if model.loupe.shown?.url == model.folder.currentURL, model.folder.currentPhoto?.format.isRaw == true { return }
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

    fileprivate static func footprintMB() -> Double {
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
