/// Variance of the Laplacian: a numeric sharpness measure for comparing two renderings of the same crop.
/// Higher means more high-frequency energy. Only ratios between renderings of the same crop mean anything.
public enum SharpnessMetric {
    /// `luma` is row-major, `width * height` samples (any scale; callers use 0...1).
    /// Applies the 4-neighbour Laplacian to interior pixels and returns the variance of the result.
    public static func laplacianVariance(luma: [Float], width: Int, height: Int) -> Double {
        precondition(luma.count == width * height, "luma size mismatch")
        guard width >= 3, height >= 3 else { return 0 }
        var sum = 0.0, sumSquares = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let l = Double(luma[i - 1] + luma[i + 1] + luma[i - width] + luma[i + width] - 4 * luma[i])
                sum += l
                sumSquares += l * l
            }
        }
        let n = Double((width - 2) * (height - 2))
        let mean = sum / n
        return sumSquares / n - mean * mean
    }
}
