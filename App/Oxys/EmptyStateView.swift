import AppKit
import SwiftUI

/// The empty state shown before a folder is open. SwiftUI owns the layout,
/// AppKit owns the pixels. It does nothing yet; M-01 makes it a drop target.
struct EmptyStateView: NSViewRepresentable {
    func makeNSView(context: Context) -> EmptyStateNSView {
        EmptyStateNSView()
    }

    func updateNSView(_ nsView: EmptyStateNSView, context: Context) {}
}

final class EmptyStateNSView: NSView {
    static let message = "Drop a folder or press ⌘O"

    private var reportedFirstDraw = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.message)
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
        let text = NSAttributedString(string: Self.message, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))

        if !reportedFirstDraw {
            reportedFirstDraw = true
            LaunchMetrics.reportFirstWindow()
        }
    }
}
