import Foundation
import Imaging
import Synchronization

/// What a job writes (V-13, V-21).
public enum ExportFormat: String, Sendable, CaseIterable {
    /// The largest JPEG inside the RAW, not re-encoded.
    case embeddedJPEG
    /// The RAW developed at the decoder's defaults, as 8-bit sRGB JPEG.
    case developedJPEG
    /// The RAW developed at the decoder's defaults, as 10-bit Display P3 HEIC.
    case developedHEIC

    public var isDeveloped: Bool { self != .embeddedJPEG }
    /// The format to develop to; nil for the embedded JPEG.
    public var developedFormat: DevelopedFormat? {
        switch self {
        case .embeddedJPEG: nil
        case .developedJPEG: .jpeg
        case .developedHEIC: .heic
        }
    }
    public var fileExtension: String { self == .developedHEIC ? "heic" : "jpg" }
}

/// Why one file was not written.
public enum ExportFailure: Error, Equatable {
    /// A JPEG, HEIC or TIFF original: nothing to extract or develop.
    case notRaw
    case noEmbeddedJPEG
    /// The system decoder gave no full-size image for this RAW (or the encoder failed).
    case cannotDevelop(String)
}

/// One file that was written.
public struct ExportedFile: Sendable, Equatable {
    public var output: URL
    /// The name was taken, so a suffix was added.
    public var renamed: Bool
    /// The Exif was written from the RAW (or built from its few known fields).
    public var exifAdded: Bool
    public var xmpAdded: Bool
    /// The RAW has a maker note and it could not be copied.
    public var makerNoteSkipped: Bool
    /// The RAW's XMP was there but could not be read, so the file has none.
    public var xmpSkipped = false
    /// What of the file's own attributes could not be copied; empty when all was.
    public var attributeWarnings: [String]
}

/// The result of a job: what was written, and everything that was not, with the reason.
public struct ExportSummary: Sendable, Equatable {
    public struct Item: Sendable, Equatable { public var name: String; public var detail: String }
    public var total = 0
    public var written = 0
    public var exifAdded = 0
    public var xmpAdded = 0
    /// Source name and the name it got, when the plain name was taken.
    public var renamed: [Item] = []
    public var makerNoteSkipped: [String] = []
    public var xmpSkipped: [String] = []
    /// Source name and what was not copied.
    public var attributeWarnings: [Item] = []
    public var withoutEmbeddedJPEG: [String] = []
    /// Developed export only: source name and why the RAW could not be developed.
    public var couldNotDevelop: [Item] = []
    public var notRaw: [String] = []
    public var failed: [Item] = []
    public var cancelled = false
    public var destination: URL?
    /// The job removed location and serial numbers (V-22).
    public var removedPrivate = false

    public init() {}
    public var hasProblems: Bool {
        !withoutEmbeddedJPEG.isEmpty || !couldNotDevelop.isEmpty || !notRaw.isEmpty || !failed.isEmpty
            || !makerNoteSkipped.isEmpty || !xmpSkipped.isEmpty || !attributeWarnings.isEmpty
    }
}

enum SafeWrite {
    /// Writes `bytes` into `folder` as `stem.ext` (`stem-1.ext`, `stem-2.ext`... when taken) with the attributes of
    /// `source`. The bytes go to a hidden temporary file, then it is renamed with RENAME_EXCL: the final name appears
    /// whole, and an existing file is never replaced, even by something that appeared a moment ago.
    static func place(_ bytes: Data, in folder: URL, stem: String, ext: String, attributesFrom source: URL) throws
        -> (output: URL, renamed: Bool, warnings: [String]) {
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).oxys-partial")
        var warnings: [String] = []
        do {
            try bytes.write(to: temporary)
            warnings = FileAttributes.copy(from: source, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        var attempt = 0
        while true {
            let name = attempt == 0 ? "\(stem).\(ext)" : "\(stem)-\(attempt).\(ext)"
            let target = folder.appendingPathComponent(name)
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return (target, attempt > 0, warnings)
            }
            let code = errno
            guard code == EEXIST, attempt < 9_999 else {
                try? FileManager.default.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            attempt += 1
        }
    }
}

enum ExportRunner {
    /// Runs `perFile` over `sources` and returns when it is done. Files are worked on by `parallelism` threads; files
    /// whose names would collide (`IMG_1.ARW`, `IMG_1.NEF`) stay in one thread, in order, so the suffixes do not
    /// depend on timing. `isCancelled` is checked before each file; a file is written whole, so a cancel leaves no
    /// partial file. `progress` gets the number of files done, from any thread.
    static func run(_ sources: [URL], into folder: URL, parallelism: Int, removedPrivate: Bool = false,
                    progress: @Sendable (Int) -> Void, isCancelled: @Sendable () -> Bool,
                    perFile: @Sendable (URL) throws -> ExportedFile) -> ExportSummary {
        enum Outcome { case done(ExportedFile), noJPEG, notRaw, cannotDevelop(String), failed(String) }
        let outcomes = Mutex([Outcome?](repeating: nil, count: sources.count))
        let finished = Mutex(0)

        var groups: [String: [Int]] = [:]
        for (i, url) in sources.enumerated() { groups[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(i) }
        let work = Array(groups.values).sorted { $0[0] < $1[0] }

        let next = Mutex(0)
        let workers = max(1, min(parallelism, work.count))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                let g = next.withLock { n -> Int in defer { n += 1 }; return n }
                guard g < work.count else { return }
                for i in work[g] {
                    guard !isCancelled() else { continue }
                    let outcome: Outcome
                    do {
                        outcome = .done(try perFile(sources[i]))
                    } catch is CancellationError {
                        continue
                    } catch ExportFailure.notRaw {
                        outcome = .notRaw
                    } catch ExportFailure.noEmbeddedJPEG {
                        outcome = .noJPEG
                    } catch ExportFailure.cannotDevelop(let reason) {
                        outcome = .cannotDevelop(reason)
                    } catch {
                        outcome = .failed(error.localizedDescription)
                    }
                    outcomes.withLock { $0[i] = outcome }
                    progress(finished.withLock { $0 += 1; return $0 })
                }
            }
        }

        var summary = ExportSummary()
        summary.total = sources.count
        summary.destination = folder
        summary.removedPrivate = removedPrivate
        for (i, source) in sources.enumerated() {
            let name = source.lastPathComponent
            switch outcomes.withLock({ $0[i] }) {
            case nil: summary.cancelled = true
            case .done(let result):
                summary.written += 1
                if result.exifAdded { summary.exifAdded += 1 }
                if result.xmpAdded { summary.xmpAdded += 1 }
                if result.makerNoteSkipped { summary.makerNoteSkipped.append(name) }
                if result.xmpSkipped { summary.xmpSkipped.append(name) }
                if !result.attributeWarnings.isEmpty {
                    summary.attributeWarnings.append(.init(name: name, detail: result.attributeWarnings.joined(separator: ", ")))
                }
                if result.renamed { summary.renamed.append(.init(name: name, detail: result.output.lastPathComponent)) }
            case .noJPEG: summary.withoutEmbeddedJPEG.append(name)
            case .notRaw: summary.notRaw.append(name)
            case .cannotDevelop(let reason): summary.couldNotDevelop.append(.init(name: name, detail: reason))
            case .failed(let message): summary.failed.append(.init(name: name, detail: message))
            }
        }
        return summary
    }
}
