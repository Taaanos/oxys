import Library
import SwiftUI

/// The window's content: the empty state until a folder is open, then the folder.
/// Until Loupe exists (M-03) an opened folder lands on a stand-in showing the first photo's preview.
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
                PreviewStandIn(folder: folder, photo: folder.photos.first)
            }
        }
        .navigationTitle(folder.folder?.lastPathComponent ?? "Oxys")
        .navigationSubtitle(Self.subtitle(folder))
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in model.handleDrop(urls) }
    }

    static func subtitle(_ folder: FolderModel) -> String {
        guard case .photos = folder.content else { return "" }
        let count = folder.photos.count
        return count == 1 ? "1 photo" : "\(count.formatted()) photos"
    }
}
