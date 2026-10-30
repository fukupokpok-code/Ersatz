import Foundation

/// Blur score for the Blurry filter, on a gray image about 512 px on the long side.
///
/// The old score (Laplacian variance of a 64x64 thumbnail) rated almost every photo
/// sharp: shrinking a photo that far hides blur, and it could not see camera shake.
/// This one measures how wide edges are, separately in four directions:
///
/// * For each pixel and direction it compares the contrast across a 9 px span with the
///   steepest single-pixel step inside it. A crisp edge does most of its change in one
///   step (ratio near 1); an edge smeared over n pixels gets about 1/n. That ratio
///   does not depend on contrast or on how much texture a photo has.
/// * Out-of-focus blur widens edges in every direction. Motion blur and camera shake
///   widen them along the movement only, so each tile keeps its *worst* direction.
/// * The photo is split into 4x4 tiles and scored by its second-sharpest textured tile,
///   so a sharp subject on a soft background (bokeh) is not called blurry.
///
/// The result is 0...100. Calibrated on photos with synthetic blur: sharp ones score
/// about 50-100, a 1 px Gaussian or a 4 px shake or motion streak about 25-45.
public enum BlurDetector {
    public static let defaultThreshold: Double = 45
    /// Long side of the gray image the score expects.
    public static let workingSize = 512
    static let span = 4
    static let edgeContrast = 20
    static let tiles = 4
    static let minimumEdgePixels = 20

    /// The four directions: horizontal, both diagonals, vertical.
    static let directions: [(dx: Int, dy: Int)] = [(1, 0), (1, 1), (0, 1), (1, -1)]

    public static func sharpness(gray: [UInt8], width: Int, height: Int) -> Double {
        let scores = tileScores(gray: gray, width: width, height: height)
        guard !scores.isEmpty else { return 0 }
        let sorted = scores.sorted()
        let pick = sorted.count > 1 ? sorted[sorted.count - 2] : sorted[0]
        return min(100, max(0, pick * 100))
    }

    /// The worst-direction edge ratio of each textured tile, 0...1.
    static func tileScores(gray: [UInt8], width: Int, height: Int) -> [Double] {
        let r = span
        guard width > 2 * r + 4, height > 2 * r + 4, gray.count >= width * height else { return [] }
        let innerW = width - 2 * r
        let innerH = height - 2 * r
        let tileCount = tiles * tiles
        // [tile][direction]
        var steepSum = [Double](repeating: 0, count: tileCount * 4)
        var spanSum = [Double](repeating: 0, count: tileCount * 4)
        var edgeCount = [Int](repeating: 0, count: tileCount * 4)
        var steps = [Int16](repeating: 0, count: width * height)
        gray.withUnsafeBufferPointer { g in
            for (d, direction) in directions.enumerated() {
                let offset = direction.dy * width + direction.dx
                // steps[p] = |g[p + d] - g[p]| wherever p + d is inside the image.
                for y in 0..<height {
                    let ny = y + direction.dy
                    guard ny >= 0, ny < height else { continue }
                    for x in 0..<width {
                        let nx = x + direction.dx
                        guard nx >= 0, nx < width else { continue }
                        let p = y * width + x
                        steps[p] = Int16(abs(Int(g[p + offset]) - Int(g[p])))
                    }
                }
                steps.withUnsafeBufferPointer { s in
                    for y in r..<(height - r) {
                        let ty = min(tiles - 1, (y - r) * tiles / innerH)
                        for x in r..<(width - r) {
                            let p = y * width + x
                            let contrast = abs(Int(g[p + r * offset]) - Int(g[p - r * offset]))
                            guard contrast > edgeContrast else { continue }
                            var steepest: Int16 = 0
                            var k = -r
                            while k < r {
                                let value = s[p + k * offset]
                                if value > steepest { steepest = value }
                                k += 1
                            }
                            let tx = min(tiles - 1, (x - r) * tiles / innerW)
                            let slot = (ty * tiles + tx) * 4 + d
                            steepSum[slot] += Double(steepest)
                            spanSum[slot] += Double(contrast)
                            edgeCount[slot] += 1
                        }
                    }
                }
            }
        }
        var scores: [Double] = []
        for tile in 0..<tileCount {
            var worst = Double.infinity
            var textured = true
            for d in 0..<4 {
                let slot = tile * 4 + d
                guard edgeCount[slot] >= minimumEdgePixels, spanSum[slot] > 0 else {
                    textured = false
                    break
                }
                worst = min(worst, steepSum[slot] / spanSum[slot])
            }
            if textured { scores.append(worst) }
        }
        return scores
    }

    /// Size to render a `width` x `height` image at for `sharpness(gray:width:height:)`.
    public static func workingDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (workingSize, workingSize) }
        let scale = min(1, Double(workingSize) / Double(max(width, height)))
        return (max(16, Int((Double(width) * scale).rounded())), max(16, Int((Double(height) * scale).rounded())))
    }
}
