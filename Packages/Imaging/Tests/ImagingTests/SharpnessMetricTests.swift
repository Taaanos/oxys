import Testing
@testable import Imaging

@Suite struct SharpnessMetricTests {
    @Test func flatImageHasZeroVariance() {
        let flat = [Float](repeating: 0.5, count: 16 * 16)
        #expect(SharpnessMetric.laplacianVariance(luma: flat, width: 16, height: 16) == 0)
    }

    @Test func linearRampHasZeroVariance() {
        var ramp = [Float](); for _ in 0..<16 { for x in 0..<16 { ramp.append(Float(x) / 16) } }
        #expect(SharpnessMetric.laplacianVariance(luma: ramp, width: 16, height: 16) < 1e-9)
    }

    @Test func sharpEdgeScoresHigherThanSoftEdge() {
        func edge(softness: Int) -> [Float] {
            var px = [Float]()
            for _ in 0..<32 { for x in 0..<32 {
                let t = Float(x - 16 + softness) / Float(2 * softness)
                px.append(min(1, max(0, t)))
            } }
            return px
        }
        let sharp = SharpnessMetric.laplacianVariance(luma: edge(softness: 1), width: 32, height: 32)
        let soft = SharpnessMetric.laplacianVariance(luma: edge(softness: 6), width: 32, height: 32)
        #expect(sharp > soft * 10)
    }

    @Test func tinyImageIsZero() {
        #expect(SharpnessMetric.laplacianVariance(luma: [1, 2, 3, 4], width: 2, height: 2) == 0)
    }
}
