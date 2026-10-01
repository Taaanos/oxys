import AppKit
import Canvas
import Commands
import CoreImage
import Diagnostics
import Imaging
import Library
import Observation

/// Drives Loupe: loads the current photo off the main thread, hands it to the canvas, and routes the
/// navigation keys. M-04 replaces the loading with the prefetching pipeline; M-05 replaces the keymap here
/// with the command table.
@MainActor @Observable
final class LoupeController {
    /// The photo on screen and the error (if any) that replaced its image. Updated together with the frame,
    /// so the info strip never describes a different photo than the one shown.
    private(set) var shown: Photo?
    private(set) var shownPixels: (width: Int, height: Int)?
    private(set) var failure: String?

    @ObservationIgnored weak var canvas: LoupeView?
    @ObservationIgnored private var pendingFrameToken: Perf.Token?
    @ObservationIgnored private var router = KeyRouter(keymap: LoupeController.keymap)
    @ObservationIgnored private var monitor: Any?

    static let keymap = Keymap([
        .init(.position(.rightArrow), command: "nav.next", behavior: .repeating),
        .init(.position(.leftArrow), command: "nav.previous", behavior: .repeating),
        .init(.position(.home), command: "nav.first"),
        .init(.position(.end), command: "nav.last"),
    ])

    // MARK: loading

    /// Shows `photo`'s preview. A newer call cancels an older one; the previous frame stays up until the new
    /// one is ready, and `shown` changes with it.
    func load(_ photo: Photo?, in folder: FolderModel) async {
        guard let photo, let canvas else { return }
        let url = photo.url, isRaw = photo.format.isRaw
        let result: Result<(PreparedImage, Int, Int), PreviewError> = await Task.detached(priority: .userInitiated) {
            do {
                let source = try PreviewSource.open(url, isRaw: isRaw)
                let decoded = try source.decodeLoupe(maxPixelSize: 8192)
                guard let gpu = LoupeGPU.shared, let prepared = gpu.prepare(decoded.image, orientation: decoded.orientation)
                else { return .failure(.corrupt) }
                let size = decoded.sourceDisplaySize
                return .success((prepared, size.width, size.height))
            } catch let error as PreviewError {
                return .failure(error)
            } catch {
                return .failure(.corrupt)
            }
        }.value
        guard !Task.isCancelled else { return }
        let token = takeToken()
        shown = photo
        switch result {
        case .success(let (prepared, width, height)):
            folder.setPreview(PreviewInfo(pixelWidth: width, pixelHeight: height), for: url)
            shownPixels = (width, height)
            failure = nil
            canvas.setAccessibilityLabel("\(photo.name), \(width) by \(height) pixels")
            canvas.show(prepared, keyToFrame: token)
        case .failure(let error):
            shownPixels = nil
            failure = error.localizedDescription
            canvas.setAccessibilityLabel("\(photo.name). \(error.localizedDescription)")
            canvas.show(nil, keyToFrame: token)
        }
    }

    private func takeToken() -> Perf.Token? {
        defer { pendingFrameToken = nil }
        return pendingFrameToken
    }

    // MARK: keys

    /// Installs the key monitor. `folder` is read at each key press.
    func start(folder: FolderModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread, but the closure type is not isolated.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.route(event, folder: folder) == true }
            return consumed ? nil : event
        }
    }

    private func route(_ event: NSEvent, folder: FolderModel) -> Bool {
        guard folder.content == .photos, event.window?.isKeyWindow == true,
              let input = KeyInput(event: event, layout: KeyLayout.asciiCapable())
        else { return false }
        let focus: KeyFocus = if let tv = event.window?.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor {
            .textInput
        } else { .canvas }
        let result = router.handle(input, mode: .loupe, focus: focus)
        for case .perform(let id) in result.actions {
            if let step = Self.step(for: id) { navigate(step, folder: folder) }
        }
        return result.consumed
    }

    static func step(for id: CommandID) -> FolderModel.Step? {
        switch id.rawValue {
        case "nav.next": .next
        case "nav.previous": .previous
        case "nav.first": .first
        case "nav.last": .last
        default: nil
        }
    }

    /// The menu items and the keys both come here. The key-to-frame interval starts now and ends when the
    /// canvas has presented the frame; a move that changes nothing (at either end) ends it at once.
    func navigate(_ step: FolderModel.Step, folder: FolderModel) {
        let token = Perf.begin(.keyToFrame)
        if folder.move(step) {
            if let stale = pendingFrameToken { Perf.end(stale) }
            pendingFrameToken = token
        } else {
            Perf.end(token)
        }
    }
}
