import AppKit
import SwiftUI

/// The empty state shown before a folder is open. SwiftUI owns the layout,
/// AppKit owns the pixels. Also shows the one-line messages for an opening, empty or unreadable folder.
struct EmptyStateView: NSViewRepresentable {
    var message: String

    func makeNSView(context: Context) -> EmptyStateNSView {
        EmptyStateNSView(message: message)
    }

    func updateNSView(_ nsView: EmptyStateNSView, context: Context) {
        nsView.message = message
    }
}

final class EmptyStateNSView: NSView {
    static let message = "Drop a folder or press ⌘O"

    var message: String {
        didSet {
            guard message != oldValue else { return }
            setAccessibilityLabel(message)
            needsDisplay = true
        }
    }

    private var reportedFirstDraw = false

    init(message: String = EmptyStateNSView.message) {
        self.message = message
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSAttributedString(string: message, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))

        if !reportedFirstDraw {
            reportedFirstDraw = true
            LaunchMetrics.reportFirstWindow()
        }
    }
}
