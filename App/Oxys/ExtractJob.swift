import AppKit
import Library
import Observation
import Synchronization
import SwiftUI

/// The background job behind `⇧⌘E` (V-13): one run at a time, progress while it works, a summary when it ends.
/// It reads the originals and writes only into the folder the user chose; nothing blocks a key.
@MainActor
@Observable
final class ExtractJob {
    enum State {
        case idle
        case running(done: Int, total: Int, folder: URL)
        case finished(EmbeddedJPEGExtractor.Summary)
    }

    private(set) var state = State.idle
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
    func start(_ sources: [URL], into folder: URL, exactBytes: Bool, finished: @escaping @MainActor @Sendable (String) -> Void) {
        guard !isRunning, !sources.isEmpty else { return }
        cancelFlag.set(false)
        state = .running(done: 0, total: sources.count, folder: folder)
        let flag = cancelFlag
        Task.detached(priority: .utility) { [weak self] in
            let lastReport = Mutex(ContinuousClock.now)
            let summary = EmbeddedJPEGExtractor.run(sources, into: folder, exactBytes: exactBytes, progress: { done in
                // At most about 20 updates a second; the last one is the summary.
                let now = ContinuousClock.now
                let due = lastReport.withLock { last in
                    guard now - last >= .milliseconds(50) else { return false }
                    last = now
                    return true
                }
                if due { Task { @MainActor in self?.report(done, of: sources.count, folder: folder) } }
            }, isCancelled: { flag.isSet })
            await MainActor.run {
                self?.state = .finished(summary)
                finished(Self.spoken(summary))
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

    static func spoken(_ s: EmbeddedJPEGExtractor.Summary) -> String {
        var parts = [s.cancelled ? "Extraction cancelled. \(s.written.formatted()) of \(s.total.formatted()) JPEGs saved"
                     : "Extracted \(s.written.formatted()) \(s.written == 1 ? "JPEG" : "JPEGs")"]
        if !s.withoutEmbeddedJPEG.isEmpty { parts.append("\(s.withoutEmbeddedJPEG.count.formatted()) with no embedded JPEG") }
        if !s.notRaw.isEmpty { parts.append("\(s.notRaw.count.formatted()) skipped, not RAW") }
        if !s.failed.isEmpty { parts.append("\(s.failed.count.formatted()) failed") }
        return parts.joined(separator: ", ")
    }
}

/// Progress, then the summary, as a plate at the bottom left. Not modal and never takes focus: `⌘.` cancels or closes it.
struct ExtractPlate: View {
    let job: ExtractJob

    var body: some View {
        Group {
            switch job.state {
            case .idle:
                EmptyView()
            case .running(let done, let total, let folder):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extracting JPEGs to \(folder.lastPathComponent)").font(.callout.weight(.semibold))
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .tint(.white)
                        .accessibilityLabel("Extraction progress")
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
        .infoPlate(cornerRadius: 10)
        .padding(.leading, 12)
        .padding(.bottom, 44)
        .accessibilityElement(children: .contain)
    }
}

private struct SummaryView: View {
    let summary: EmbeddedJPEGExtractor.Summary
    let job: ExtractJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.cancelled ? "Extraction cancelled" : "Extraction done").font(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(headline).font(.callout).foregroundStyle(Plate.secondary)
            if summary.exifAdded > 0 {
                Text("\(summary.exifAdded.formatted()) got the RAW's orientation, camera and date added in an EXIF block. The image data is unchanged.")
                    .font(.caption).foregroundStyle(Plate.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if summary.hasProblems || !summary.renamed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        list("No embedded JPEG", summary.withoutEmbeddedJPEG, icon: "exclamationmark.triangle.fill")
                        list("Not a RAW file, skipped", summary.notRaw, icon: "minus.circle")
                        list("Failed", summary.failed.map { "\($0.name): \($0.detail)" }, icon: "xmark.octagon.fill")
                        list("Renamed, the name was taken", summary.renamed.map { "\($0.name) → \($0.detail)" }, icon: "arrow.right.circle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
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

    private var headline: String {
        let saved = "\(summary.written.formatted()) of \(summary.total.formatted()) saved to \(summary.destination?.lastPathComponent ?? "the folder")."
        return saved
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                PlateLabel(text: "\(title) (\(items.count.formatted()))", systemImage: icon, tint: Plate.warning).font(.callout)
                ForEach(items.prefix(50), id: \.self) { Text($0).font(.caption).lineLimit(1).truncationMode(.middle) }
                if items.count > 50 { Text("and \((items.count - 50).formatted()) more").font(.caption).foregroundStyle(Plate.secondary) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
