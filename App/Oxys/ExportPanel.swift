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
    private let caption = NSTextField(wrappingLabelWithString: "")

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
        menu.target = self
        menu.action = #selector(formatChanged)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 380
        caption.setAccessibilityElement(false)   // VoiceOver reads it as the menu's help instead
        formatChanged()
    }

    static func title(_ format: ExportFormat) -> String {
        switch format {
        case .embeddedJPEG: "Embedded JPEG"
        case .developedJPEG: "Developed JPEG"
        case .developedHEIC: "Developed HEIC"
        }
    }

    /// One short sentence about what the file is, then what it keeps. Shown under the menu.
    static func detail(_ format: ExportFormat) -> String {
        switch format {
        case .embeddedJPEG:
            "The camera's own JPEG from inside the RAW, not changed. The fastest choice. Keeps EXIF, your rating, file dates and tags."
        case .developedJPEG:
            "The RAW developed at full size by macOS. sRGB, 8-bit: opens the same everywhere. Keeps EXIF, GPS, your rating, file dates and tags."
        case .developedHEIC:
            "The RAW developed at full size by macOS. Display P3, 10-bit: more colors, smoother gradients. Keeps EXIF, GPS, your rating, file dates and tags, but no maker note."
        }
    }

    @objc private func formatChanged() {
        let format = formats[max(0, menu.indexOfSelectedItem)]
        caption.stringValue = Self.detail(format)
        menu.setAccessibilityHelp(Self.detail(format))
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

        // A label column and a field column, as in the Save panel: "Format:" right-aligned, the menu and its caption
        // left-aligned under each other. The insets match the toolbar of the panel above (about 20 pt).
        let label = NSTextField(labelWithString: "Format:")
        label.setAccessibilityElement(false)
        let grid = NSGridView(views: [[label, menu], [NSGridCell.emptyContentView, caption]])
        grid.columnSpacing = 8
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 0).yPlacement = .center
        let container = NSStackView(views: [grid])
        container.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        panel.accessoryView = container

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
