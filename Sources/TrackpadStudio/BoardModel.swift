import AppKit

/// Drawing tools only. Text is a one-shot action (`t`), not a mode — committing
/// text must leave the active tool untouched. Raw values are the number keys.
enum BoardTool: Int, CaseIterable {
    case pen = 1
    case highlighter
    case eraser
    case lasso
    case line
    case rectangle
    case ellipse
    case arrow

    var name: String {
        switch self {
        case .pen: return "钢笔"
        case .highlighter: return "荧光笔"
        case .eraser: return "橡皮"
        case .lasso: return "套索"
        case .line: return "直线"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        }
    }

    /// Tools whose stroke is freehand ink.
    var isFreehand: Bool { self == .pen || self == .highlighter }
}

/// Note background, drawn in canvas space so writing stays aligned to it.
enum PaperStyle: String, CaseIterable {
    case blank
    case lined
    case grid
    case dots

    var name: String {
        switch self {
        case .blank: return "空白"
        case .lined: return "横线"
        case .grid: return "方格"
        case .dots: return "点阵"
        }
    }

    /// Line pitch in canvas units.
    static let spacing: CGFloat = 32
}

struct BoardStrokeSample: Codable {
    let point: CGPoint
    let width: CGFloat
}

enum BoardElement {
    case stroke(samples: [BoardStrokeSample], color: NSColor)
    case line(start: CGPoint, end: CGPoint, width: CGFloat, color: NSColor)
    case rectangle(rect: CGRect, width: CGFloat, color: NSColor)
    case ellipse(rect: CGRect, width: CGFloat, color: NSColor)
    case arrow(start: CGPoint, end: CGPoint, width: CGFloat, color: NSColor)
    case text(origin: CGPoint, string: String, fontSize: CGFloat, color: NSColor)
    case image(rect: CGRect, image: NSImage)
}

extension BoardElement {
    /// Same element with its color mapped (display-time theming, recoloring a
    /// selection). A highlighter keeps its translucency.
    func recolored(_ map: (NSColor) -> NSColor) -> BoardElement {
        switch self {
        case let .stroke(samples, color): return .stroke(samples: samples, color: map(color))
        case let .line(a, b, w, color): return .line(start: a, end: b, width: w, color: map(color))
        case let .rectangle(r, w, color): return .rectangle(rect: r, width: w, color: map(color))
        case let .ellipse(r, w, color): return .ellipse(rect: r, width: w, color: map(color))
        case let .arrow(a, b, w, color): return .arrow(start: a, end: b, width: w, color: map(color))
        case let .text(o, str, size, color): return .text(origin: o, string: str, fontSize: size, color: map(color))
        case .image: return self
        }
    }

    func translated(by d: CGPoint) -> BoardElement {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        func t(_ r: CGRect) -> CGRect { r.offsetBy(dx: d.x, dy: d.y) }
        switch self {
        case let .stroke(samples, color):
            return .stroke(samples: samples.map { .init(point: t($0.point), width: $0.width) }, color: color)
        case let .line(a, b, w, color): return .line(start: t(a), end: t(b), width: w, color: color)
        case let .rectangle(r, w, color): return .rectangle(rect: t(r), width: w, color: color)
        case let .ellipse(r, w, color): return .ellipse(rect: t(r), width: w, color: color)
        case let .arrow(a, b, w, color): return .arrow(start: t(a), end: t(b), width: w, color: color)
        case let .text(o, str, size, color): return .text(origin: t(o), string: str, fontSize: size, color: color)
        case let .image(r, image): return .image(rect: t(r), image: image)
        }
    }

    /// Canvas-space bounds including line width.
    var bounds: CGRect {
        func box(_ points: [CGPoint], pad: CGFloat) -> CGRect {
            guard let first = points.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -pad, dy: -pad)
        }
        switch self {
        case let .stroke(samples, _):
            return box(samples.map(\.point), pad: (samples.map(\.width).max() ?? 0) / 2)
        case let .line(a, b, w, _): return box([a, b], pad: w / 2)
        case let .arrow(a, b, w, _): return box([a, b], pad: w / 2 + 14)
        case let .rectangle(r, w, _), let .ellipse(r, w, _):
            return r.standardized.insetBy(dx: -w / 2, dy: -w / 2)
        case let .text(origin, string, fontSize, _):
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            return CGRect(origin: origin, size: (string as NSString).size(withAttributes: [.font: font]))
        case let .image(r, _): return r.standardized
        }
    }

    /// Points that stand for the element's ink, for lasso containment.
    var outlinePoints: [CGPoint] {
        switch self {
        case let .stroke(samples, _): return samples.map(\.point)
        case let .line(a, b, _, _), let .arrow(a, b, _, _):
            return (0...8).map { i in
                let t = CGFloat(i) / 8
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        case let .rectangle(r, _, _):
            let r = r.standardized
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                    CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
        case let .ellipse(r, _, _):
            let r = r.standardized
            return (0..<16).map { i in
                let a = CGFloat(i) / 16 * 2 * .pi
                return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
            }
        case .text, .image:
            let r = bounds
            return [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)]
        }
    }
}

final class BoardModel {
    static let minimumZoom: CGFloat = 0.2
    static let maximumZoom: CGFloat = 8.0

    private static let panLimit: CGFloat = 1_000_000

    /// Content changed (elements or paper): the note needs saving.
    var onChange: (() -> Void)?
    private(set) var elements: [BoardElement] = [] {
        didSet {
            revision += 1
            lastChangeDirtyRect = pendingDirtyRect
            pendingDirtyRect = nil
            onChange?()
        }
    }
    /// Canvas area the latest change touched, when it was local (an eraser
    /// step): renderers can repaint just that area of their cache.
    private(set) var lastChangeDirtyRect: CGRect?
    private var pendingDirtyRect: CGRect?
    /// Bumped on every element change, so renderers can tell a stale cache.
    private(set) var revision = 0
    /// True when the latest change only appended one element (renderers can
    /// then draw just that element on top of their cache).
    private(set) var lastChangeWasAppend = false
    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGPoint = .zero
    var paper: PaperStyle = .grid {
        didSet {
            guard paper != oldValue else { return }
            revision += 1
            lastChangeWasAppend = false
            lastChangeDirtyRect = nil
            onChange?()
        }
    }

    var isEmpty: Bool { elements.isEmpty }

    func documentData() throws -> Data {
        var archive = BoardArchive(elements: try elements.map { try .init($0) }, zoom: zoom, pan: pan)
        archive.paper = paper.rawValue
        return try JSONEncoder().encode(archive)
    }

    /// Replaces the whole board (opening a note): no undo across notes.
    func loadDocument(_ data: Data) throws {
        let archive = try JSONDecoder().decode(BoardArchive.self, from: data)
        guard archive.version == 1, archive.zoom.isFinite,
              (Self.minimumZoom...Self.maximumZoom).contains(archive.zoom),
              archive.pan.x.isFinite, archive.pan.y.isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = try archive.elements.map { try $0.native() }
        lastChangeWasAppend = false
        let notify = onChange
        onChange = nil
        defer { onChange = notify }
        elements = decoded
        paper = archive.paper.flatMap(PaperStyle.init(rawValue:)) ?? .grid
        zoom = archive.zoom
        pan = clampedPan(archive.pan)
        history.removeAll()
        future.removeAll()
    }

    func canvasToView(_ point: CGPoint, in viewBounds: CGRect) -> CGPoint {
        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        return CGPoint(
            x: center.x + (point.x - center.x) * zoom + pan.x,
            y: center.y + (point.y - center.y) * zoom + pan.y
        )
    }

    func viewToCanvas(_ point: CGPoint, in viewBounds: CGRect) -> CGPoint {
        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        return CGPoint(
            x: center.x + (point.x - center.x - pan.x) / zoom,
            y: center.y + (point.y - center.y - pan.y) / zoom
        )
    }

    func canvasToView(_ rect: CGRect, in viewBounds: CGRect) -> CGRect {
        let a = canvasToView(rect.origin, in: viewBounds)
        let b = canvasToView(
            CGPoint(x: rect.maxX, y: rect.maxY),
            in: viewBounds
        )
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// The canvas → view mapping as a renderer transform.
    func renderer(in viewBounds: CGRect) -> InkRenderer {
        let c = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        return InkRenderer(
            scale: zoom,
            offset: CGPoint(x: c.x * (1 - zoom) + pan.x, y: c.y * (1 - zoom) + pan.y)
        )
    }

    // MARK: Undo / redo

    /// Board state before each undoable operation. Elements are values whose
    /// payload arrays are shared copy-on-write, so a snapshot costs one array
    /// of references, not a deep copy.
    private var history: [[BoardElement]] = []
    private var future: [[BoardElement]] = []
    private let historyLimit = 300

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    private func recordUndo() {
        history.append(elements)
        if history.count > historyLimit { history.removeFirst() }
        future.removeAll()
    }

    @discardableResult
    func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        future.append(elements)
        lastChangeWasAppend = false
        elements = previous
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = future.popLast() else { return false }
        history.append(elements)
        lastChangeWasAppend = false
        elements = next
        return true
    }

    // MARK: Editing

    func append(_ element: BoardElement) {
        recordUndo()
        lastChangeWasAppend = true
        elements.append(element)
    }

    /// Appends several elements as one undo step (paste); returns their indices.
    @discardableResult
    func append(contentsOf added: [BoardElement]) -> IndexSet {
        guard !added.isEmpty else { return [] }
        recordUndo()
        lastChangeWasAppend = added.count == 1
        let start = elements.count
        elements += added
        return IndexSet(start..<elements.count)
    }

    func remove(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        recordUndo()
        lastChangeWasAppend = false
        elements = elements.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
    }

    func translate(_ indices: IndexSet, by delta: CGPoint) {
        guard !indices.isEmpty, delta != .zero else { return }
        recordUndo()
        lastChangeWasAppend = false
        var next = elements
        for i in indices where next.indices.contains(i) { next[i] = next[i].translated(by: delta) }
        elements = next
    }

    func recolor(_ indices: IndexSet, to color: NSColor) {
        guard !indices.isEmpty else { return }
        recordUndo()
        lastChangeWasAppend = false
        var next = elements
        for i in indices where next.indices.contains(i) {
            // A highlighter stays translucent in its new color.
            next[i] = next[i].recolored { color.withAlphaComponent($0.alphaComponent) }
        }
        elements = next
    }

    func clear() {
        guard !elements.isEmpty else { return }
        recordUndo()
        lastChangeWasAppend = false
        elements.removeAll(keepingCapacity: true)
    }

    /// Erases along the eraser's path from `a` to `b` (canvas space).
    /// `partial`: strokes lose only the ink under the eraser (split into
    /// pieces); shapes, text and images always go whole. Otherwise every
    /// element touched goes whole. Returns whether anything changed.
    /// Pass `recordingUndo` on the first hit of a gesture, so one eraser
    /// gesture undoes in one ⌘Z and a gesture that hits nothing adds no step.
    @discardableResult
    func erase(
        from a: CGPoint, to b: CGPoint, radius: CGFloat,
        partial: Bool = false, recordingUndo: Bool
    ) -> Bool {
        var next: [BoardElement] = []
        next.reserveCapacity(elements.count)
        var changed = false
        var dirty = CGRect.null
        // Cheap box test first: most of the page is nowhere near the eraser.
        let sweep = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -radius, dy: -radius)
        for element in elements {
            let box = element.bounds
            guard box.intersects(sweep), Self.touches(element, segmentFrom: a, to: b, radius: radius) else {
                next.append(element)
                continue
            }
            changed = true
            dirty = dirty.union(box)
            if partial, case let .stroke(samples, color) = element {
                let reach = radius + (samples.map(\.width).max() ?? 0) / 2
                next += Self.split(samples, erasingFrom: a, to: b, reach: reach)
                    .map { .stroke(samples: $0, color: color) }
            }
        }
        guard changed else { return false }
        if recordingUndo { recordUndo() }
        lastChangeWasAppend = false
        // A little slack for antialiasing and arrow heads.
        pendingDirtyRect = dirty.insetBy(dx: -3, dy: -3)
        elements = next
        return true
    }

    /// The runs of a stroke left after removing every sample — and every
    /// connecting segment — within `reach` of the eraser segment.
    static func split(
        _ samples: [BoardStrokeSample], erasingFrom a: CGPoint, to b: CGPoint, reach: CGFloat
    ) -> [[BoardStrokeSample]] {
        var pieces: [[BoardStrokeSample]] = []
        var current: [BoardStrokeSample] = []
        for (i, sample) in samples.enumerated() {
            if distanceFromSegment(sample.point, start: a, end: b) <= reach {
                if !current.isEmpty { pieces.append(current); current = [] }
                continue
            }
            if let last = current.last, i > 0,
               segmentDistance(last.point, sample.point, a, b) <= reach {
                pieces.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { pieces.append(current) }
        // A lone leftover sample would render as a stray dot.
        return pieces.filter { $0.count > 1 }
    }

    // MARK: Selection

    /// Elements mostly inside the closed lasso polygon (canvas space).
    func indices(inLasso polygon: [CGPoint]) -> IndexSet {
        guard polygon.count >= 3 else { return [] }
        var box = CGRect.null
        for p in polygon { box = box.union(CGRect(origin: p, size: .zero)) }
        var result = IndexSet()
        for (i, element) in elements.enumerated() where element.bounds.intersects(box) {
            let points = element.outlinePoints
            guard !points.isEmpty else { continue }
            let inside = points.filter { Self.contains(polygon, $0) }.count
            if CGFloat(inside) >= CGFloat(points.count) * 0.6 { result.insert(i) }
        }
        return result
    }

    func bounds(of indices: IndexSet) -> CGRect {
        indices.reduce(CGRect.null) { box, i in
            elements.indices.contains(i) ? box.union(elements[i].bounds) : box
        }
    }

    var contentBounds: CGRect {
        bounds(of: IndexSet(elements.indices))
    }

    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: View

    /// Applies a scale step while keeping the canvas point under the view center fixed.
    func zoom(by factor: CGFloat, in viewBounds: CGRect) {
        guard factor.isFinite, factor > 0 else { return }

        let viewCenter = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        let anchoredCanvasPoint = viewToCanvas(viewCenter, in: viewBounds)
        let requestedZoom = zoom * factor
        zoom = min(Self.maximumZoom, max(Self.minimumZoom, requestedZoom))

        pan = clampedPan(
            CGPoint(
                x: -(anchoredCanvasPoint.x - viewCenter.x) * zoom,
                y: -(anchoredCanvasPoint.y - viewCenter.y) * zoom
            )
        )
    }

    /// Simultaneous zoom + pan: scales by `factor`, then translates so `anchor`
    /// (a canvas point) lands exactly on `viewPoint`. Because the pan is derived
    /// from the post-clamp zoom, a clamped zoom cannot accumulate drift.
    func navigate(
        scale factor: CGFloat,
        anchor: CGPoint,
        to viewPoint: CGPoint,
        in viewBounds: CGRect
    ) {
        guard factor.isFinite, factor > 0,
              anchor.x.isFinite, anchor.y.isFinite,
              viewPoint.x.isFinite, viewPoint.y.isFinite else { return }

        zoom = min(Self.maximumZoom, max(Self.minimumZoom, zoom * factor))

        let center = CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        pan = clampedPan(
            CGPoint(
                x: viewPoint.x - center.x - (anchor.x - center.x) * zoom,
                y: viewPoint.y - center.y - (anchor.y - center.y) * zoom
            )
        )
    }

    func pan(by delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        pan = clampedPan(
            CGPoint(x: pan.x + delta.x, y: pan.y + delta.y)
        )
    }

    func resetView() {
        zoom = 1
        pan = .zero
    }

    private func clampedPan(_ proposed: CGPoint) -> CGPoint {
        CGPoint(
            x: min(Self.panLimit, max(-Self.panLimit, proposed.x)),
            y: min(Self.panLimit, max(-Self.panLimit, proposed.y))
        )
    }

    // MARK: Geometry

    /// Outline hit for the eraser: shapes are erased by touching their line,
    /// never by writing inside them.
    private static func touches(
        _ element: BoardElement,
        segmentFrom a: CGPoint,
        to b: CGPoint,
        radius: CGFloat
    ) -> Bool {
        func near(_ polyline: [CGPoint], width: CGFloat) -> Bool {
            let reach = radius + max(0, width) / 2
            guard let first = polyline.first else { return false }
            if polyline.count == 1 {
                return distanceFromSegment(first, start: a, end: b) <= reach
            }
            return zip(polyline, polyline.dropFirst()).contains {
                segmentDistance($0.0, $0.1, a, b) <= reach
            }
        }

        switch element {
        case let .stroke(samples, _):
            let width = samples.map(\.width).max() ?? 0
            return near(samples.map(\.point), width: width)
        case let .line(start, end, width, _), let .arrow(start, end, width, _):
            return near([start, end], width: width)
        case let .rectangle(rect, width, _):
            let r = rect.standardized
            return near([
                CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                CGPoint(x: r.minX, y: r.minY),
            ], width: width)
        case let .ellipse(rect, width, _):
            let r = rect.standardized
            let points = (0...48).map { i -> CGPoint in
                let angle = CGFloat(i) / 48 * 2 * .pi
                return CGPoint(x: r.midX + cos(angle) * r.width / 2,
                               y: r.midY + sin(angle) * r.height / 2)
            }
            return near(points, width: width)
        case .text, .image:
            let box = element.bounds.insetBy(dx: -radius, dy: -radius)
            return box.contains(a) || box.contains(b)
        }
    }

    private static func segmentDistance(
        _ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint
    ) -> CGFloat {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2)
        let d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)),
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return 0
        }
        return min(
            distanceFromSegment(p1, start: q1, end: q2),
            distanceFromSegment(p2, start: q1, end: q2),
            distanceFromSegment(q1, start: p1, end: p2),
            distanceFromSegment(q2, start: p1, end: p2)
        )
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func distanceFromSegment(
        _ point: CGPoint,
        start: CGPoint,
        end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > .ulpOfOne else { return distance(point, start) }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / lengthSquared
        let t = min(1, max(0, projection))
        let nearest = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return distance(point, nearest)
    }
}
