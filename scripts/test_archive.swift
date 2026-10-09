import AppKit

@main
struct ArchiveChecks {
    static func main() throws {
        let model = BoardModel()
        let p = CGPoint(x: 500, y: 350)
        let q = CGPoint(x: 700, y: 450)
        let rect = CGRect(x: 450, y: 300, width: 220, height: 140)
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.9)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 4, height: 4)).fill(); image.unlockFocus()
        model.append(.stroke(samples: [.init(point: p, width: 2), .init(point: q, width: 5)], color: color))
        model.append(.line(start: p, end: q, width: 3, color: color))
        model.append(.rectangle(rect: rect, width: 4, color: color))
        model.append(.ellipse(rect: rect, width: 5, color: color))
        model.append(.arrow(start: p, end: q, width: 6, color: color))
        model.append(.text(origin: p, string: "中文笔迹测试", fontSize: 18, color: color))
        model.append(.image(rect: rect, image: image))
        model.zoom(by: 2, in: rect)
        model.pan(by: CGPoint(x: 10, y: 10))
        let data = try model.documentData()
        let restored = BoardModel()
        try restored.loadDocument(data)
        precondition(restored.elements.count == 7 && restored.zoom == model.zoom && restored.pan == model.pan)
        guard case let .stroke(samples, restoredColor) = restored.elements[0] else { fatalError("Missing stroke") }
        precondition(samples.count == 2 && samples[1].point == q && samples[1].width == 5)
        precondition(abs((restoredColor.usingColorSpace(.sRGB)?.alphaComponent ?? 0) - 0.9) < 0.001)
        guard case let .text(_, text, _, _) = restored.elements[5] else { fatalError("Missing text") }
        precondition(text == "中文笔迹测试")
        var bad = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        bad["version"] = 99
        do { try restored.loadDocument(JSONSerialization.data(withJSONObject: bad)); fatalError("Accepted unsupported version") }
        catch { precondition(restored.elements.count == 7) }
        do { try restored.loadDocument(Data("broken".utf8)); fatalError("Accepted corrupt file") }
        catch { precondition(restored.elements.count == 7) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try data.write(to: url, options: .atomic)
        let fromDisk = BoardModel()
        try fromDisk.loadDocument(Data(contentsOf: url))
        precondition(fromDisk.elements.count == 7)
        print("PASS: 7 element types, stroke coordinates/widths, color, Chinese text, view state, atomic disk round-trip, invalid-file preservation")
    }
}
