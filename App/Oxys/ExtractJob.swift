import AppKit
import Library
import Observation
import Synchronization
import SwiftUI

/// The background job behind `⇧⌘E` (V-13, V-21): one run at a time, progress while it works, a summary when it ends.
/// It extracts the embedded JPEGs or develops the RAWs to JPEG or HEIC. It reads the originals and writes only into
/// the folder the user chose; nothing blocks a key.
@MainActor
@Observable
final class ExtractJob {
    enum State {
        case idle
        case running(done: Int, total: Int, folder: URL)
        case finished(ExportSummary)
    }

    private(set) var state = State.idle
    /// What the current (or last) job writes.
    private(set) var format = ExportFormat.embeddedJPEG
    @ObservationIgnored private let cancelFlag = Flag()

    /// Set by the main actor, read between files by the worker.
    nonisolated private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set(_ on: Bool) { value.withLock { $0 = on } }
    }

    var isRunning: Bool { if case .running = state { true } else { false } }
    var isShowing: Bool { if case .idle = state { false } else { true } }

    /// Starts the job on a background thread. Does nothing while another job runs. `finished` gets the spoken summary.
    func start(_ sources: [URL], into folder: URL, format: ExportFormat, exactBytes: Bool, quality: Double?, sidecars: [URL: URL],
               removePrivate: Bool = false, finished: @escaping @MainActor @Sendable (String) -> Void) {
        guard !isRunning, !sources.isEmpty else { return }
        cancelFlag.set(false)
        self.format = format
        state = .running(done: 0, total: sources.count, folder: folder)
        let flag = cancelFlag
        Task.detached(priority: .utility) { [weak self] in
            let lastReport = Mutex(ContinuousClock.now)
            let progress: @Sendable (Int) -> Void = { done in
                // At most about 20 updates a second; the last one is the summary.
                let now = ContinuousClock.now
                let due = lastReport.withLock { last in
                    guard now - last >= .milliseconds(50) else { return false }
                    last = now
                    return true
                }
                if due { Task { @MainActor in self?.report(done, of: sources.count, folder: folder) } }
            }
            let cancelled: @Sendable () -> Bool = { flag.isSet }
            let summary: ExportSummary
            if let developed = format.developedFormat {
                summary = DevelopedExporter.run(sources, into: folder, as: developed, quality: quality, sidecars: sidecars, removePrivate: removePrivate,
                                                progress: progress, isCancelled: cancelled)
            } else {
                summary = EmbeddedJPEGExtractor.run(sources, into: folder, exactBytes: exactBytes, sidecars: sidecars,
                                                    removePrivate: removePrivate, progress: progress, isCancelled: cancelled)
            }
            await MainActor.run {
                self?.state = .finished(summary)
                finished(Self.spoken(summary, format: format))
            }
        }
    }

    private func report(_ done: Int, of total: Int, folder: URL) {
        // A late update must not overwrite the summary.
        guard case .running = state else { return }
        state = .running(done: done, total: total, folder: folder)
    }

    /// `⌘.` and the Cancel button. The file being written ends whole; the next one is not started.
    func cancel() { cancelFlag.set(true) }

    func dismiss() {
        if case .finished = state { state = .idle }
    }

    static func noun(_ format: ExportFormat, plural: Bool) -> String {
        let name = format == .developedHEIC ? "HEIC" : "JPEG"
        return plural ? name + "s" : name
    }

    static func spoken(_ s: ExportSummary, format: ExportFormat) -> String {
        var parts = [s.cancelled ? "Export cancelled. \(s.written.formatted()) of \(s.total.formatted()) \(noun(format, plural: true)) saved"
                     : "Exported \(s.written.formatted()) \(noun(format, plural: s.written != 1))"]
        if !s.withoutEmbeddedJPEG.isEmpty { parts.append("\(s.withoutEmbeddedJPEG.count.formatted()) with no embedded JPEG") }
        if !s.couldNotDevelop.isEmpty { parts.append("\(s.couldNotDevelop.count.formatted()) could not be developed") }
        if !s.notRaw.isEmpty { parts.append("\(s.notRaw.count.formatted()) skipped, not RAW") }
        if !s.failed.isEmpty { parts.append("\(s.failed.count.formatted()) failed") }
        return parts.joined(separator: ", ")
    }
}

/// Progress, then the summary, as a plate at the bottom left. Not modal and never takes focus: `⌘.` cancels or closes it.
struct ExtractPlate: View {
    let job: ExtractJob
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer {
        Group {
            switch job.state {
            case .idle:
                EmptyView()
            case .running(let done, let total, let folder):
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(job.format.isDeveloped ? "Developing" : "Extracting") \(ExtractJob.noun(job.format, plural: true)) to \(folder.lastPathComponent)")
                        .font(.callout.weight(.semibold))
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(.white)
                        .accessibilityLabel("Export progress")
                        .accessibilityValue("\(done.formatted()) of \(total.formatted()) files")
                    HStack {
                        Text("\(done.formatted()) of \(total.formatted())").foregroundStyle(Plate.secondary).monospacedDigit()
                        Spacer()
                        Button("Cancel") { job.cancel() }
                    }
                    .font(.callout)
                }
            case .finished(let summary):
                SummaryView(summary: summary, job: job)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .glassPlate(in: .rect(cornerRadius: 10), transition: reduceMotion ? .identity : .materialize)
        }
        .padding(.leading, 12)
        .padding(.bottom, 44)
        .accessibilityElement(children: .contain)
    }
}

private struct SummaryView: View {
    let summary: ExportSummary
    let job: ExtractJob
    /// Height of the lists, so the scroll area is no taller than they are.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.cancelled ? "Export cancelled" : "Export done").font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(headline).font(.callout).foregroundStyle(Plate.secondary)
            if summary.exifAdded > 0 {
                Text(note).font(.caption).foregroundStyle(Plate.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if summary.hasProblems || !summary.renamed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        list("No embedded JPEG", summary.withoutEmbeddedJPEG, icon: "exclamationmark.triangle.fill")
                        list("Could not be developed", summary.couldNotDevelop.map { "\($0.name): \($0.detail)" }, icon: "xmark.octagon.fill")
                        list("XMP not copied (the packet could not be read)", summary.xmpSkipped, icon: "exclamationmark.triangle.fill")
                        list("Maker note not copied", summary.makerNoteSkipped, icon: "info.circle", tint: Plate.secondary,
                             note: "It could not be moved into the new file. Most apps do not read maker notes.")
                        list("File attributes not fully copied", summary.attributeWarnings.map { "\($0.name): \($0.detail)" }, icon: "exclamationmark.triangle.fill")
                        list("Not a RAW file, skipped", summary.notRaw, icon: "minus.circle")
                        list("Failed", summary.failed.map { "\($0.name): \($0.detail)" }, icon: "xmark.octagon.fill")
                        list("Renamed, the name was taken", summary.renamed.map { "\($0.name) → \($0.detail)" }, icon: "arrow.right.circle", tint: Plate.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // A scroll view takes all the height it may; this one is only as tall as its lists, up to 160 pt.
                .frame(height: listHeight > 0 ? min(listHeight, 160) : 160)
            }
            HStack {
                if let folder = summary.destination, summary.written > 0 {
                    Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                }
                Spacer()
                Button("Close") { job.dismiss() }
            }
            .font(.callout)
        }
    }

    /// What the written files carry, in one paragraph.
    private var note: String {
        let format = job.format
        let what = summary.removedPrivate
            ? ["EXIF"] + (summary.xmpAdded > 0 ? ["XMP (rating and label)"] : [])
            : ["EXIF"] + (format.isDeveloped ? ["GPS"] : []) + (summary.xmpAdded > 0 ? ["XMP (rating and label)"] : [])
        let who = summary.exifAdded == summary.written
            ? (summary.written == 1 ? "The file got" : "All \(summary.written.formatted()) files got")
            : "\(summary.exifAdded.formatted()) of \(summary.written.formatted()) files got"
        var text = "\(who) the RAW's \(what.formatted(.list(type: .and, width: .standard))). File dates, permissions and extended attributes were copied."
        if summary.removedPrivate { text += " Location, owner name, serial numbers and the maker note were removed." }
        switch format {
        case .embeddedJPEG: text += " The image data is unchanged."
        case .developedJPEG: text += " Developed at the decoder's defaults, as sRGB."
        case .developedHEIC: text += " Developed at the decoder's defaults, as 10-bit Display P3. A HEIC holds no maker note."
        }
        return text
    }

    private var headline: String {
        let saved = "\(summary.written.formatted()) of \(summary.total.formatted()) saved to \(summary.destination?.lastPathComponent ?? "the folder")."
        return saved
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], icon: String, tint: Color = Plate.warning, note: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                PlateLabel(text: "\(title) (\(items.count.formatted()))", systemImage: icon, tint: tint).font(.callout)
                if let note { Text(note).font(.caption).foregroundStyle(Plate.secondary).fixedSize(horizontal: false, vertical: true) }
                ForEach(items.prefix(50), id: \.self) { Text($0).font(.caption).lineLimit(1).truncationMode(.middle) }
                if items.count > 50 { Text("and \((items.count - 50).formatted()) more").font(.caption).foregroundStyle(Plate.secondary) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
