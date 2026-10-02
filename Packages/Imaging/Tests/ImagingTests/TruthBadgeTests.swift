import Testing
@testable import Imaging

private func badge(_ source: TruthBadge.Source, percent: Int = 31, fit: Bool = true, edge: Int? = 1616, sensor: Int? = 6000) -> TruthBadge {
    TruthBadge.make(source: source, percent: percent, isFit: fit, longEdge: edge, sensorLongEdge: sensor)
}

@Test func aPreviewAtFitNamesItsSize() {
    #expect(badge(.preview) == TruthBadge(text: "Preview 1616 px", isWarning: false))
}

@Test func aPreviewPastOneToOneIsEnlargedAndWarns() {
    #expect(badge(.preview, percent: 240, fit: false) == TruthBadge(text: "Preview enlarged 2.4×", isWarning: true))
    #expect(badge(.preview, percent: 200, fit: false).text == "Preview enlarged 2×")
    // A small preview shown larger than 1:1 at Fit is enlarged too.
    #expect(badge(.preview, percent: 150, fit: true).isWarning)
}

@Test func aPreviewAtOneToOneIsNotTheSensor() {
    #expect(badge(.preview, percent: 100, fit: false) == TruthBadge(text: "Preview 1:1, not sensor pixels", isWarning: true))
    #expect(badge(.preview, percent: 100, fit: false, sensor: nil).isWarning)
    #expect(badge(.preview, percent: 100, fit: false, edge: 6000) == TruthBadge(text: "Preview 6000 px", isWarning: false))
}

@Test func developingWarnsAndRawDoesNot() {
    #expect(badge(.developing, percent: 100, fit: false) == TruthBadge(text: "Developing", isWarning: true))
    #expect(badge(.raw) == TruthBadge(text: "RAW", isWarning: false))
    #expect(badge(.raw, percent: 100, fit: false) == TruthBadge(text: "RAW 1:1", isWarning: false))
    #expect(badge(.raw, percent: 400, fit: false) == TruthBadge(text: "RAW enlarged 4×", isWarning: false))
}

@Test func aFileIsTheTruthUntilItIsEnlarged() {
    #expect(badge(.file) == TruthBadge(text: "Full file", isWarning: false))
    #expect(badge(.file, percent: 100, fit: false).text == "1:1")
    #expect(badge(.file, percent: 200, fit: false) == TruthBadge(text: "Enlarged 2×", isWarning: true))
}

@Test func theCameraJpegOfAPairSaysSo() {
    #expect(badge(.cameraJPEG) == TruthBadge(text: "Camera JPEG", isWarning: false))
    #expect(badge(.cameraJPEG, percent: 100, fit: false).text == "Camera JPEG 1:1")
    #expect(badge(.cameraJPEG, percent: 200, fit: false) == TruthBadge(text: "Camera JPEG enlarged 2×", isWarning: true))
}

@Test func zoomNeedingMorePixelsThanThePreviewHasAlwaysWarns() {
    for percent in stride(from: 101, through: 400, by: 7) {
        #expect(badge(.preview, percent: percent, fit: false).isWarning)
    }
}
