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
    /// V-22: off unless the user turned it on (and then it stays on, the next time).
    private let removePrivate = NSButton(checkboxWithTitle: "Remove location and serial numbers", target: nil, action: nil)

    /// `remembered` is the raw value of the format used last time; `rememberedRemovePrivate` the switch's last state.
    init(sources: [URL], remembered: String?, rememberedRemovePrivate: Bool = false) {
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
        removePrivate.state = rememberedRemovePrivate ? .on : .off
        removePrivate.setAccessibilityHelp(Self.removePrivateHelp)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = Self.captionWidth
        caption.setAccessibilityElement(false)   // VoiceOver reads it as the menu's help instead
        formatChanged()
    }

    /// The caption wraps at this width, so its height is the same whichever format is chosen.
    static let captionWidth: CGFloat = 440

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
            "The camera's own JPEG from inside the RAW, unchanged. The fastest choice. Keeps EXIF, GPS location, rating, file dates and tags."
        case .developedJPEG:
            "Full size, developed by macOS. sRGB, 8-bit: opens the same everywhere. Keeps EXIF, GPS location, rating, file dates and tags."
        case .developedHEIC:
            "Full size, developed by macOS. Display P3, 10-bit: more colors, smoother gradients. Keeps EXIF, GPS location, rating, file dates and tags; no maker note."
        }
    }

    /// What the switch takes out, for the VoiceOver help and the summary.
    static let removePrivateHelp = "Takes out the GPS position, the camera owner name, the camera and lens serial numbers and the maker note, and the place and contact fields of IPTC and XMP. The rating and label stay for a developed file, and not for an unchanged embedded JPEG."

    @objc private func formatChanged() {
        let format = formats[max(0, menu.indexOfSelectedItem)]
        caption.stringValue = Self.detail(format)
        menu.setAccessibilityHelp(Self.detail(format))
    }

    /// Shows the panel. Nil when the user cancels.
    func run(lastFolder: String?) -> (URL, ExportFormat, removePrivate: Bool)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = sources.count == 1 ? "Choose a folder for the exported photo" : "Choose a folder for \(sources.count.formatted()) exported photos"
        if let lastFolder { panel.directoryURL = URL(fileURLWithPath: lastFolder, isDirectory: true) }
        panel.delegate = self

        // A label column and a field column, as in the Save panel: "Format:" right-aligned, the menu and its caption
        // left-aligned under each other. The grid is pinned 20 pt from the left, the edge of the panel's own controls.
        // The panel centers an accessory view that is only as wide as its content, so the view is full width.
        let label = NSTextField(labelWithString: "Format:")
        label.setAccessibilityElement(false)
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.widthAnchor.constraint(equalToConstant: 170).isActive = true   // does not change with the item
        removePrivate.translatesAutoresizingMaskIntoConstraints = false
        let grid = NSGridView(views: [[label, menu], [NSGridCell.emptyContentView, caption], [NSGridCell.emptyContentView, removePrivate]])
        grid.columnSpacing = 8
        grid.rowSpacing = 4
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.row(at: 0).yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false

        // Height for the tallest caption, so the panel does not resize when the choice changes.
        let chosen = menu.indexOfSelectedItem
        var height: CGFloat = 0
        for (i, format) in formats.enumerated() {
            menu.selectItem(at: i)
            caption.stringValue = Self.detail(format)
            height = max(height, grid.fittingSize.height)
        }
        menu.selectItem(at: chosen)
        formatChanged()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: height + 16))
        container.autoresizingMask = [.width]
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        ])
        panel.accessoryView = container

        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        return (destination, formats[max(0, menu.indexOfSelectedItem)], removePrivate.state == .on)
    }

    // MARK: NSOpenSavePanelDelegate

    nonisolated func panel(_ sender: Any, validate url: URL) throws {
        let chosen = url.resolvingSymlinksInPath().standardizedFileURL
        let holds = sources.contains { $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == chosen }
        if holds {
            throw NSError(domain: "com.thanosam.oxys.export", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Choose another folder.",
                NSLocalizedRecoverySuggestionErrorKey: "This folder holds the photos. Oxys writes only sidecars into a photo folder.",
            ])
        }
    }
}
