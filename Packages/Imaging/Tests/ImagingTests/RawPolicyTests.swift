import Testing
@testable import Imaging

@Test func neverBlocksEverything() {
    #expect(!RawPolicy.allowsDevelop(.never))
    #expect(RawPolicy.allowsDevelop(.onDemand) && RawPolicy.allowsDevelop(.always))
    #expect(RawPolicy.effective(setting: .never, sessionAlways: true) == .never)
    #expect(RawPolicy.toggledSession(setting: .never, sessionAlways: false) == nil)
}

@Test func shiftRSwitchesTheSessionToAlwaysAndBack() {
    #expect(RawPolicy.effective(setting: .onDemand, sessionAlways: false) == .onDemand)
    #expect(RawPolicy.toggledSession(setting: .onDemand, sessionAlways: false) == true)
    #expect(RawPolicy.effective(setting: .onDemand, sessionAlways: true) == .always)
    #expect(RawPolicy.toggledSession(setting: .onDemand, sessionAlways: true) == false)
    #expect(RawPolicy.effective(setting: .always, sessionAlways: false) == .always)
}

private func auto(mode: RawMode = .onDemand, automatic: Bool = true, raw: Bool = true, fit: Bool = false,
                  percent: Int = 100, preview: Int? = 1616, sensor: Int? = 6000) -> Bool {
    RawPolicy.developsAtActualSize(mode: mode, automatic: automatic, isRaw: raw, isFit: fit, percent: percent,
                                   previewLongEdge: preview, sensorLongEdge: sensor)
}

@Test func oneToOneDevelopsWhenThePreviewIsSmaller() {
    #expect(auto())
    #expect(auto(mode: .always))
    #expect(auto(percent: 400))
    #expect(!auto(preview: 6000))            // the preview already has every pixel
    #expect(auto(preview: nil, sensor: nil)) // unknown: develop
    #expect(!auto(fit: true))
    #expect(!auto(percent: 50))
    #expect(!auto(automatic: false))
    #expect(!auto(mode: .never))
    #expect(!auto(raw: false))
}

@Test func dimensionsParse() {
    #expect(RawPolicy.longEdge(ofDimensions: "6000 × 4000") == 6000)
    #expect(RawPolicy.longEdge(ofDimensions: "4000 × 6000") == 6000)
    #expect(RawPolicy.longEdge(ofDimensions: "big") == nil)
    #expect(RawPolicy.longEdge(ofDimensions: nil) == nil)
}

@Test func neighborsAreAheadThenBehindWithinTheFolder() {
    #expect(RawPolicy.neighbors(of: 5, count: 10, forward: true) == [6, 4])
    #expect(RawPolicy.neighbors(of: 5, count: 10, forward: false) == [4, 6])
    #expect(RawPolicy.neighbors(of: 0, count: 10, forward: true) == [1])
    #expect(RawPolicy.neighbors(of: 9, count: 10, forward: true) == [8])
    #expect(RawPolicy.neighbors(of: 0, count: 1, forward: true).isEmpty)
}
