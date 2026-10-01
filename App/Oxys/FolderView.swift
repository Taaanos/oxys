import AppKit
import Library
import SwiftUI

/// The window's content: the empty state until a folder is open, then the folder.
/// An opened folder lands in Loupe on its first photo.
struct FolderView: View {
    let model: AppModel

    var body: some View {
        let folder = model.folder
        Group {
            switch folder.content {
            case .none:
                EmptyStateView(message: EmptyStateNSView.message)
            case .opening:
                EmptyStateView(message: "Opening…")
            case .empty(let hasSubfolderPhotos):
                EmptyStateView(message: hasSubfolderPhotos
                               ? "No photos in this folder, but its subfolders have some. Open one of them."
                               : "No photos in this folder.")
            case .failed(let reason):
                EmptyStateView(message: "Couldn't open this folder: \(reason)")
            case .photos:
                LoupeScreen(model: model)
            }
        }
        .overlay(alignment: .top) {
            if let banner = folder.banner {
                WriteBanner(banner: banner, unsaved: folder.unsavedCount, model: model)
            }
        }
        .navigationTitle(folder.folder?.lastPathComponent ?? "Oxys")
        .navigationSubtitle(Self.subtitle(folder))
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in model.handleDrop(urls) }
    }

    static func subtitle(_ folder: FolderModel) -> String {
        guard case .photos = folder.content else { return "" }
        let count = folder.photos.count
        let photos = count == 1 ? "1 photo" : "\(count.formatted()) photos"
        let new = folder.newFileCount
        guard new > 0 else { return photos }
        return "\(photos) · \(new == 1 ? "1 new file" : "\(new) new files"), reload with ⌥⌘R"
    }
}

/// The non-modal notice for a read-only folder or a failed write. It never takes focus and never blocks a key.
private struct WriteBanner: View {
    let banner: FolderModel.Banner
    let unsaved: Int
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).accessibilityHidden(true)
            Text(message).lineLimit(2)
            Spacer(minLength: 8)
            if case .writeFailed = banner {
                Button("Retry") { model.folder.retryUnsaved() }
            }
            if showsSave {
                Button("Save Decisions To…") { Task { await model.saveDecisionsElsewhere() } }
            }
            Button("Dismiss") { model.folder.dismissBanner() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .onAppear { announce() }
        .onChange(of: message) { announce() }
    }

    private var showsSave: Bool {
        if case .savedCopy = banner { return false }
        return true
    }

    private var icon: String {
        if case .savedCopy = banner { "checkmark.circle" } else { "exclamationmark.triangle.fill" }
    }

    private var message: String {
        switch banner {
        case .readOnly:
            "This folder is read-only. Your decisions are kept in memory; save them to another folder, then move the .xmp files next to the photos."
        case .writeFailed(let reason):
            "\(unsaved == 1 ? "1 decision is" : "\(unsaved) decisions are") not saved: \(reason). They are kept in memory."
        case .savedCopy(let folder, let count):
            "Saved \(count == 1 ? "1 sidecar" : "\(count) sidecars") to \(folder.lastPathComponent). Move them next to the photos to reunite them."
        }
    }

    private func announce() {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
