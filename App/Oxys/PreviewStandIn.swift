import CoreImage
import Imaging
import Library
import SwiftUI

/// Shows the first photo's embedded preview, or an error tile. Replaced by the Loupe canvas in M-03, which
/// will also take over the loading (and M-04 the caching).
struct PreviewStandIn: View {
    let folder: FolderModel
    let photo: Photo?

    private enum Phase {
        case loading
        case shown(CGImage, CGSize)
        case failed(String)
    }

    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                Color.clear
            case .shown(let image, let size):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("\(photo?.name ?? "Photo"), \(Int(size.width)) by \(Int(size.height)) pixels")
            case .failed(let message):
                ErrorTile(name: photo?.name ?? "", message: message)
            }
        }
        .task(id: photo?.url) { await load() }
    }

    private func load() async {
        guard let photo else { return }
        phase = .loading
        let url = photo.url, isRaw = photo.format.isRaw
        let result: Result<(CGImage, CGSize), PreviewError> = await Task.detached(priority: .userInitiated) {
            do {
                let source = try PreviewSource.open(url, isRaw: isRaw)
                let decoded = try source.decodeLoupe(maxPixelSize: 3000)
                let upright = CIImage(cgImage: decoded.image).oriented(decoded.orientation)
                guard let image = CIContext().createCGImage(upright, from: upright.extent,
                                                            format: .RGBA8, colorSpace: decoded.image.colorSpace)
                else { return .failure(.corrupt) }
                let size = decoded.sourceDisplaySize
                return .success((image, CGSize(width: size.width, height: size.height)))
            } catch let error as PreviewError {
                return .failure(error)
            } catch {
                return .failure(.corrupt)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (image, size)):
            folder.setPreview(PreviewInfo(pixelWidth: Int(size.width), pixelHeight: Int(size.height)), for: url)
            phase = .shown(image, size)
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
    }
}

/// What a file that cannot be previewed shows: its name and why, never a crash or a blank frame.
private struct ErrorTile: View {
    let name: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(name).font(.title3.monospaced())
            Text(message)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name). \(message)")
    }
}
