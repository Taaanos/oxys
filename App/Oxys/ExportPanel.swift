import AppKit
import Imaging
import Library

/// The folder panel behind `⇧⌘E` (V-21): the usual open panel for a folder, with a Format menu under it. It refuses a
/// folder that holds any of the photos: Oxys writes nothing but sidecars into a photographer's folders.
@MainActor
final class ExportPanel: NSObject, NSOpenSavePanelDelegate {
    private let sources: [URL]
    private let formats: [ExportFormat]
    private let menu = NSPopUpButton(frame: .zero, pullsDown: false)

    /// `remembered` is the raw value of the format used last time.
    init(sources: [URL], remembered: String?) {
        self.sources = sources
        // A format the system cannot write is not offered.
        formats = ExportFormat.allCases.filter { format in
            format.developedFormat.map(DevelopedRenderer.isSupported) ?? true
        }
        super.init()
        menu.addItems(withTitles: formats.map(Self.title))
        menu.selectItem(at: formats.firstIndex { $0.rawValue == remembered } ?? 0)
        menu.setAccessibilityLabel("Export format")
        menu.setAccessibilityHelp("Choose the embedded JPEG, or the RAW developed to JPEG or HEIC")
    }

    static func title(_ format: ExportFormat) -> String {
        switch format {
        case .embeddedJPEG: "Embedded JPEG (the camera's own, unchanged)"
        case .developedJPEG: "Developed JPEG (sRGB, 8-bit)"
        case .developedHEIC: "Developed HEIC (Display P3, 10-bit)"
        }
    }

    /// Shows the panel. Nil when the user cancels.
    func run(lastFolder: String?) -> (URL, ExportFormat)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = sources.count == 1 ? "Choose a folder for the exported photo" : "Choose a folder for \(sources.count.formatted()) exported photos"
        if let lastFolder { panel.directoryURL = URL(fileURLWithPath: lastFolder, isDirectory: true) }
        panel.delegate = self

        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, menu])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        panel.accessoryView = row
        label.setAccessibilityElement(false)

        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        return (destination, formats[max(0, menu.indexOfSelectedItem)])
    }

    // MARK: NSOpenSavePanelDelegate

    nonisolated func panel(_ sender: Any, validate url: URL) throws {
        let chosen = url.resolvingSymlinksInPath().standardizedFileURL
        let holds = sources.contains { $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == chosen }
        if holds {
            throw NSError(domain: "dev.oxys.export", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Choose another folder.",
                NSLocalizedRecoverySuggestionErrorKey: "This folder holds the photos. Oxys writes only sidecars into a photo folder.",
            ])
        }
    }
}
