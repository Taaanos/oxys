import Canvas
import Library
import SwiftUI

/// Loupe: the canvas, an info strip along the bottom, and an error tile for a file that cannot be previewed.
struct LoupeScreen: View {
    let model: AppModel

    var body: some View {
        let folder = model.folder
        let loupe = model.loupe
        ZStack(alignment: .bottom) {
            LoupeCanvas(controller: loupe)
            if let failure = loupe.failure {
                ErrorTile(name: loupe.shown?.name ?? "", message: failure)
            }
            InfoStrip(photo: loupe.shown, pixels: loupe.shownPixels)
        }
        .background(Color(white: LoupeView.canvasGray))
        .task(id: folder.currentURL) { await loupe.load(folder.currentPhoto, in: folder) }
        .onChange(of: folder.folder) { loupe.reset() }
    }
}

private struct LoupeCanvas: NSViewRepresentable {
    let controller: LoupeController

    func makeNSView(context: Context) -> LoupeView {
        let view = LoupeView()
        controller.canvas = view
        return view
    }

    func updateNSView(_ view: LoupeView, context: Context) {}
}

/// Filename and the size of the preview shown. Stars and label arrive with M-06.
private struct InfoStrip: View {
    let photo: Photo?
    let pixels: (width: Int, height: Int)?

    var body: some View {
        if let photo {
            HStack(spacing: 12) {
                Text(photo.name).font(.callout.monospaced())
                if let pixels {
                    Text("Preview \(max(pixels.width, pixels.height)) px").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.45))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
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
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name). \(message)")
    }
}
