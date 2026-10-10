import CoreGraphics
import Foundation

/// A plane-to-plane perspective map (3×3, row-major, last entry 1).
struct Homography: Codable, Equatable {
    var m: [Double]

    func map(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    var inverse: Homography? {
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-12 else { return nil }
        let inv = [A, -(b * i - c * h), b * f - c * e,
                   B, a * i - c * g, -(a * f - c * d),
                   C, -(a * h - b * g), a * e - b * d].map { $0 / det }
        return Homography(m: inv.map { $0 / inv[8] })
    }

    /// Weighted least squares through point pairs (at least four, not
    /// three on a line). Coordinates should be of order 1.
    static func fit(_ pairs: [(from: CGPoint, to: CGPoint, weight: Double)]) -> Homography? {
        guard pairs.count >= 4 else { return nil }
        // Normal equations for h0…h7 with h8 = 1.
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for pair in pairs {
            let x = Double(pair.from.x), y = Double(pair.from.y)
            let u = Double(pair.to.x), v = Double(pair.to.y)
            let w = pair.weight
            for (row, rhs) in [([x, y, 1, 0, 0, 0, -u * x, -u * y], u), ([0, 0, 0, x, y, 1, -v * x, -v * y], v)] {
                for r in 0..<8 {
                    atb[r] += w * row[r] * rhs
                    for c in 0..<8 { ata[r * 8 + c] += w * row[r] * row[c] }
                }
            }
        }
        guard let h = solve(ata, atb, n: 8) else { return nil }
        return Homography(m: h + [1])
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var a = a, b = b
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0 * n + col]) < abs(a[$1 * n + col]) }!
            guard abs(a[pivot * n + col]) > 1e-14 else { return nil }
            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            for r in (col + 1)..<n {
                let f = a[r * n + col] / a[col * n + col]
                guard f != 0 else { continue }
                for k in col..<n { a[r * n + k] -= f * a[col * n + k] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n { s -= a[r * n + k] * x[k] }
            x[r] = s / a[r * n + r]
        }
        return x
    }
}

/// Where the trackpad sits in the camera picture. Starts from its four
/// corners (dragged by hand, or found automatically), then keeps learning
/// from every frame in which the pen touches the pad: the pad reports the
/// true position, the tip tracker the pixel. Image points are camera
/// pixels (origin top-left); pad points are normalized like `TouchSample`
/// (0…1, origin bottom-left, y = 1 along the keyboard).
struct PadCalibration: Codable, Equatable {
    struct Pair: Codable, Equatable {
        var image: CGPoint
        var pad: CGPoint
    }
    /// Pad corners in the image, in the order of `PadCalibration.padCorners`.
    var corners: [CGPoint]
    var imageSize: CGSize
    private(set) var pairs: [Pair] = []
    /// Consecutive touches far from where the map put them: the phone moved.
    private(set) var misses = 0
    private(set) var toPad: Homography
    private(set) var toImage: Homography

    /// Bottom-left, top-left, top-right, bottom-right.
    static let padCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0)]
    static let maxPairs = 200
    /// A touch further than this from its predicted spot (pad units, about
    /// 6–10 mm) does not teach the map once it is established.
    static let outlier: CGFloat = 0.08
    /// Touches before the outlier test applies.
    static let established = 20

    init?(corners: [CGPoint], imageSize: CGSize) {
        guard corners.count == 4, imageSize.width > 0, imageSize.height > 0 else { return nil }
        self.corners = corners
        self.imageSize = imageSize
        toPad = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        toImage = toPad
        guard refit() else { return nil }
    }

    func pad(at image: CGPoint) -> CGPoint {
        toPad.map(CGPoint(x: image.x / imageSize.width, y: image.y / imageSize.height))
    }

    func image(at pad: CGPoint) -> CGPoint {
        let p = toImage.map(pad)
        return CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)
    }

    var isLost: Bool { misses >= 8 }

    /// Which way the pen body runs from a tip touching `pad`, in camera
    /// pixels: toward the writing hand's side and toward the writer.
    func shaft(at pad: CGPoint, leftHanded: Bool) -> CGVector {
        let tip = image(at: pad)
        let body = image(at: CGPoint(x: pad.x + (leftHanded ? -0.04 : 0.04), y: pad.y - 0.04))
        return CGVector(dx: body.x - tip.x, dy: body.y - tip.y)
    }

    /// The pen touched `pad` while the tracker saw it at `image`.
    mutating func learn(image: CGPoint, pad: CGPoint) {
        let guess = self.pad(at: image)
        if pairs.count >= Self.established, hypot(guess.x - pad.x, guess.y - pad.y) > Self.outlier {
            misses += 1
            return
        }
        misses = 0
        pairs.append(Pair(image: image, pad: pad))
        if pairs.count > Self.maxPairs { pairs.removeFirst(pairs.count - Self.maxPairs) }
        refit()
    }

    mutating func setCorners(_ corners: [CGPoint]) {
        guard corners.count == 4 else { return }
        self.corners = corners
        pairs = []
        misses = 0
        refit()
    }

    @discardableResult
    private mutating func refit() -> Bool {
        let size = imageSize
        let scale = { (p: CGPoint) in CGPoint(x: p.x / size.width, y: p.y / size.height) }
        // The corners count like a few touches each: enough to hold the map
        // in place at first, outvoted once touches cover the pad.
        var data = zip(corners, Self.padCorners).map { (from: scale($0), to: $1, weight: 4.0) }
        data += pairs.map { (from: scale($0.image), to: $0.pad, weight: 1.0) }
        guard let forward = Homography.fit(data), let back = forward.inverse else { return false }
        toPad = forward
        toImage = back
        return true
    }
}
