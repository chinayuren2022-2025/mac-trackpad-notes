import AppKit

/// Draws board content into the current NSGraphicsContext through a uniform
/// scale + offset (target = canvas · scale + offset). One renderer serves the
/// live canvas, thumbnails and PDF/PNG export, so they always match.
struct InkRenderer {
    var scale: CGFloat
    var offset: CGPoint

    /// Translucent ink below this alpha is highlighter: multiplied onto the
    /// page so the writing under it stays crisp.
    static let highlighterAlpha: CGFloat = 0.38

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    func canvasPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    func rect(_ r: CGRect) -> CGRect {
        let a = point(r.origin), b = point(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Renderer that fits canvas `content` into `target`, centered.
    static func fitting(_ content: CGRect, into target: CGRect) -> InkRenderer {
        guard content.width > 0, content.height > 0 else {
            return InkRenderer(scale: 1, offset: CGPoint(x: target.midX - content.midX, y: target.midY - content.midY))
        }
        let s = min(target.width / content.width, target.height / content.height)
        return InkRenderer(
            scale: s,
            offset: CGPoint(x: target.midX - content.midX * s, y: target.midY - content.midY * s)
        )
    }

    // MARK: Paper

    func drawPaper(_ style: PaperStyle, in area: CGRect, color: NSColor = .white) {
        color.setFill()
        NSBezierPath(rect: area).fill()
        guard style != .blank, scale > 0 else { return }

        let a = canvasPoint(area.origin), b = canvasPoint(CGPoint(x: area.maxX, y: area.maxY))
        // Keep at least ~9pt between lines on screen: zoomed far out, every
        // second (fourth…) line is drawn instead of a gray wash.
        var spacing = PaperStyle.spacing
        while spacing * scale < 9 { spacing *= 2 }
        let minX = floor(min(a.x, b.x) / spacing) * spacing, maxX = max(a.x, b.x)
        let minY = floor(min(a.y, b.y) / spacing) * spacing, maxY = max(a.y, b.y)

        switch style {
        case .blank:
            break
        case .lined, .grid:
            let path = NSBezierPath()
            var y = minY
            while y <= maxY {
                path.move(to: point(CGPoint(x: minX, y: y)))
                path.line(to: point(CGPoint(x: maxX, y: y)))
                y += spacing
            }
            if style == .grid {
                var x = minX
                while x <= maxX {
                    path.move(to: point(CGPoint(x: x, y: minY)))
                    path.line(to: point(CGPoint(x: x, y: maxY)))
                    x += spacing
                }
            }
            (style == .lined
                ? NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.85, alpha: 0.22)
                : NSColor(calibratedWhite: 0, alpha: 0.075)).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .dots:
            NSColor(calibratedWhite: 0, alpha: 0.22).setFill()
            let r: CGFloat = 1.1
            var y = minY
            while y <= maxY {
                var x = minX
                while x <= maxX {
                    let p = point(CGPoint(x: x, y: y))
                    NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
                    x += spacing
                }
                y += spacing
            }
        }
    }

    // MARK: Elements

    func draw(_ element: BoardElement, alpha: CGFloat = 1) {
        switch element {
        case let .stroke(samples, color):
            drawStroke(samples: samples, color: color.withAlphaComponent(color.alphaComponent * alpha))
        case let .line(start, end, width, color):
            let path = NSBezierPath()
            path.move(to: point(start))
            path.line(to: point(end))
            stroke(path, width: width, color: color.withAlphaComponent(alpha))
        case let .rectangle(r, width, color):
            let path = NSBezierPath(roundedRect: rect(r), xRadius: 3 * scale, yRadius: 3 * scale)
            stroke(path, width: width, color: color.withAlphaComponent(alpha))
        case let .ellipse(r, width, color):
            stroke(NSBezierPath(ovalIn: rect(r)), width: width, color: color.withAlphaComponent(alpha))
        case let .arrow(start, end, width, color):
            drawArrow(start: start, end: end, width: width, color: color.withAlphaComponent(alpha))
        case let .text(origin, string, fontSize, color):
            let font = NSFont.systemFont(ofSize: max(1, fontSize * scale), weight: .medium)
            (string as NSString).draw(
                at: point(origin),
                withAttributes: [.font: font, .foregroundColor: color.withAlphaComponent(alpha)]
            )
        case let .image(r, image):
            image.draw(in: rect(r), from: .zero, operation: .sourceOver, fraction: alpha)
        }
    }

    /// Uniform-width strokes are a stroked path (correct round joins at sharp
    /// turns); older variable-width strokes are filled as a ribbon.
    private func drawStroke(samples: [BoardStrokeSample], color: NSColor) {
        guard !samples.isEmpty else { return }

        var points: [(point: CGPoint, radius: CGFloat)] = []
        points.reserveCapacity(samples.count * 2)
        for sample in smoothed(samples) {
            let viewPoint = point(sample.point)
            let radius = max(0.35, sample.width * scale / 2)
            if let last = points.last,
               hypot(last.point.x - viewPoint.x, last.point.y - viewPoint.y) < 0.05,
               abs(last.radius - radius) < 0.05 {
                continue
            }
            points.append((viewPoint, radius))
        }

        let highlighter = color.alphaComponent < 0.99
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if highlighter { NSGraphicsContext.current?.cgContext.setBlendMode(.multiply) }
        color.setFill()
        color.setStroke()

        guard points.count > 1 else {
            if let only = points.first { fillDot(at: only.point, radius: only.radius) }
            return
        }

        if let radius = points.first?.radius,
           points.allSatisfy({ abs($0.radius - radius) < 0.01 }) {
            let path = NSBezierPath()
            path.move(to: points[0].point)
            for p in points.dropFirst() { path.line(to: p.point) }
            path.lineWidth = radius * 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            return
        }

        var leftEdge: [CGPoint] = [], rightEdge: [CGPoint] = []
        for index in points.indices {
            let previous = points[max(0, index - 1)].point
            let next = points[min(points.count - 1, index + 1)].point
            var dx = next.x - previous.x, dy = next.y - previous.y
            let length = hypot(dx, dy)
            if length < 1e-6 { dx = 1; dy = 0 } else { dx /= length; dy /= length }
            let r = points[index].radius
            let c = points[index].point
            leftEdge.append(CGPoint(x: c.x - dy * r, y: c.y + dx * r))
            rightEdge.append(CGPoint(x: c.x + dy * r, y: c.y - dx * r))
        }
        let path = NSBezierPath()
        path.move(to: leftEdge[0])
        for p in leftEdge.dropFirst() { path.line(to: p) }
        for p in rightEdge.reversed() { path.line(to: p) }
        path.close()
        path.windingRule = .nonZero
        path.fill()
        if let first = points.first { fillDot(at: first.point, radius: first.radius) }
        if let last = points.last { fillDot(at: last.point, radius: last.radius) }
    }

    func fillDot(at p: CGPoint, radius: CGFloat) {
        let d = max(0.7, radius * 2)
        NSBezierPath(ovalIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
    }

    /// Catmull-Rom resampling at ~2.5 target points per step.
    private func smoothed(_ samples: [BoardStrokeSample]) -> [BoardStrokeSample] {
        guard samples.count > 1 else { return samples }
        var result = [samples[0]]
        result.reserveCapacity(samples.count * 2)
        for index in 0..<(samples.count - 1) {
            let p0 = samples[max(0, index - 1)].point
            let p1 = samples[index].point
            let p2 = samples[index + 1].point
            let p3 = samples[min(samples.count - 1, index + 2)].point
            let w1 = samples[index].width, w2 = samples[index + 1].width
            let screenDistance = hypot(p2.x - p1.x, p2.y - p1.y) * scale
            // Int(ceil(nan)) traps, and a trap inside draw() kills the app.
            let steps = screenDistance.isFinite
                ? max(1, min(16, Int(ceil(min(1000, screenDistance) / 2.5))))
                : 1
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(BoardStrokeSample(
                    point: Self.catmullRom(p0, p1, p2, p3, t),
                    width: max(0.2, w1 + (w2 - w1) * t)
                ))
            }
        }
        return result
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func c(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y))
    }

    private func drawArrow(start: CGPoint, end: CGPoint, width: CGFloat, color: NSColor) {
        let s = point(start), e = point(end)
        let length = hypot(e.x - s.x, e.y - s.y)
        let path = NSBezierPath()
        path.move(to: s)
        path.line(to: e)
        if length > .ulpOfOne {
            let angle = atan2(e.y - s.y, e.x - s.x)
            let head = min(14 * scale, length * 0.45)
            for spread in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: e)
                path.line(to: CGPoint(x: e.x - cos(angle + spread) * head, y: e.y - sin(angle + spread) * head))
            }
        }
        stroke(path, width: width, color: color)
    }

    private func stroke(_ path: NSBezierPath, width: CGFloat, color: NSColor) {
        color.setStroke()
        path.lineWidth = max(0.2, width * scale)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
