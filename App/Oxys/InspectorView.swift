import Commands
import Imaging
import Library
import Metadata
import SwiftUI

/// The inspector sidebar (M-18, `⌥⌘I`): Histogram, EXIF and Sidecar for the active photo, in Grid and in Loupe.
/// "Move Focus to Inspector" (`⌃⌘I`) or a click on a row activates it: `⇥`/`⇧⇥` and `↑`/`↓` walk the rows, `⌘C`
/// copies the focused one, `Esc` hands the keyboard back to the image. The text can also be selected with the pointer.
struct InspectorView: View {
    let model: AppModel

    /// Modification time of the sidecar file, read off the main thread when the photo or its decision changes.
    @State private var lastWrite: Date?
    @State private var exif: ExifInfo?
    /// The last histogram Loupe produced. It stays until the next photo's one arrives, so the section keeps its height while culling.
    @State private var lastHistogram: Histogram?

    private var photo: Photo? { model.folder.currentPhoto }

    private struct Key: Equatable {
        let url: URL?
        let decision: Decision?
        let file: URL?
        let unsaved: Bool
    }

    var body: some View {
        let folder = model.folder
        let photo = photo
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let photo {
                    Text(photo.name).font(.headline.monospaced()).textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    if let companion = photo.companion {
                        Text("RAW+JPEG with \(companion.url.lastPathComponent)").font(.callout).foregroundStyle(.secondary)
                    }
                    histogramSection(photo)
                    exifSection
                    sidecarSection(photo, folder: folder)
                } else {
                    Text("No photo").foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.probeScope, "inspector")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
        .task(id: photo?.url) {
            // Keep the previous photo's rows until the new ones are ready: clearing first makes the column collapse and regrow on every step.
            guard let url = photo?.url else { exif = nil; return }
            let info = await model.loupe.exifInfo(for: url)
            if !Task.isCancelled { exif = info }
        }
        .task(id: Key(url: photo?.url, decision: photo?.decision, file: photo?.sidecar.file, unsaved: photo?.sidecar.unsaved ?? false)) {
            lastWrite = nil
            guard let file = photo.flatMap({ folder.sidecarTarget(for: $0) }) else { return }
            lastWrite = await Task.detached { (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.value
        }
        .onChange(of: rows) { model.inspectorRows = rows.map { ($0.id, $0.label, $0.value) } }
        .onAppear { model.inspectorRows = rows.map { ($0.id, $0.label, $0.value) } }
        .onDisappear { model.deactivateInspector(); model.inspectorRows = [] }
    }

    // MARK: rows

    private struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
        var warning = false
        var copyText: String { value }
    }

    /// The EXIF rows, then the AF rows from the maker note (V-01), which say "AF data not available" for a brand we do not read.
    private var exifRows: [Row] {
        guard let exif else { return [] }
        return (exif.fields + exif.afFields).map { Row(id: "exif.\($0.label)", label: $0.label, value: $0.value) }
    }

    private var sidecarRows: [Row] {
        guard let photo else { return [] }
        let folder = model.folder
        let side = photo.sidecar
        var rows: [Row] = []
        let target = folder.sidecarTarget(for: photo)
        rows.append(Row(id: "sidecar.file", label: "File", value: target?.path ?? "—"))
        let exists = side.file != nil ? "Yes"
            : side.isEmbedded ? "No, the rating is read from the image file"
            : side.isRead ? "No, none yet" : "Not read yet"
        rows.append(Row(id: "sidecar.exists", label: "Exists", value: exists))
        let d = photo.decision
        rows.append(Row(id: "sidecar.rating", label: "Rating",
                        value: d.isReject ? "Rejected" : d.stars == 0 ? "None" : String(repeating: "★", count: d.stars) + String(repeating: "☆", count: 5 - d.stars) + " (\(d.stars))"))
        rows.append(Row(id: "sidecar.label", label: "Label", value: d.label.map { $0.name } ?? side.unknownLabel.map { "\($0) (not one of ours)" } ?? "None"))
        rows.append(Row(id: "sidecar.saved", label: "Saved", value: side.unsaved ? "No, kept in memory" : "Yes", warning: side.unsaved))
        rows.append(Row(id: "sidecar.lastWrite", label: "Last write", value: lastWrite.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "—"))
        if let problem = side.problem { rows.append(Row(id: "sidecar.problem", label: "Problem", value: "\(problem). The file won't be overwritten", warning: true)) }
        if side.unsaved, let failure = folder.lastWriteFailure { rows.append(Row(id: "sidecar.failure", label: "Last error", value: failure, warning: true)) }
        if let outside = side.overwrittenOutsideChange { rows.append(Row(id: "sidecar.outside", label: "Changed outside", value: outside, warning: true)) }
        if let also = side.alsoPresent { rows.append(Row(id: "sidecar.also", label: "Also present", value: "\(also.lastPathComponent), not used")) }
        if folder.unsavedCount > 0 {
            rows.append(Row(id: "sidecar.unsaved", label: "Unsaved in folder", value: "\(folder.unsavedCount)", warning: true))
        }
        return rows
    }

    private var rows: [Row] { exifRows + sidecarRows }

    // MARK: sections

    @ViewBuilder private func histogramSection(_ photo: Photo) -> some View {
        let loupe = model.loupe
        // No placeholder text: the section appears only when this photo's histogram exists (Grid and Compare have none).
        let current = loupe.shown?.url == photo.url ? loupe.histogram : nil
        let inLoupe = model.commands.mode == .loupe
        if let histogram = current ?? (inLoupe ? lastHistogram : nil) {
            section("Histogram") { HistogramView(histogram: histogram) }
                .onChange(of: current?.luminance) { if let current { lastHistogram = current } }
                .onAppear { if let current { lastHistogram = current } }
        }
    }

    @ViewBuilder private var exifSection: some View {
        section("EXIF") {
            if exifRows.isEmpty {
                Text(exif == nil ? "Reading…" : "No EXIF in this file.").foregroundStyle(.secondary)
            } else {
                ForEach(exifRows) { row($0) }
            }
        }
    }

    @ViewBuilder private func sidecarSection(_ photo: Photo, folder: FolderModel) -> some View {
        section("Sidecar") { ForEach(sidecarRows) { row($0) } }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ row: Row) -> some View {
        let focused = model.inspectorActive && model.inspectorFocusID == row.id
        return VStack(alignment: .leading, spacing: 0) {
            Text(row.label).font(.caption).foregroundStyle(.secondary)
            Text(row.value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.warning ? Color.orange : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay { if focused { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.activateInspector(at: row.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.label), \(row.value)")
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}
