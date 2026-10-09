import AppKit

/// Local, versioned document format. Colors and images use portable values.
/// Fields added after version 1 are optional, so older files still open.
struct BoardArchive: Codable {
    var version = 1
    let elements: [Element]
    let zoom: CGFloat
    let pan: CGPoint
    /// `PaperStyle` raw value; absent in files from before paper styles.
    var paper: String?

    struct Color: Codable {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        init(_ color: NSColor) throws {
            guard let rgb = color.usingColorSpace(.sRGB) else { throw CocoaError(.fileWriteUnknown) }
            r = rgb.redComponent; g = rgb.greenComponent
            b = rgb.blueComponent; a = rgb.alphaComponent
        }
        var native: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    enum Element: Codable {
        case stroke([BoardStrokeSample], Color)
        case line(CGPoint, CGPoint, CGFloat, Color)
        case rectangle(CGRect, CGFloat, Color)
        case ellipse(CGRect, CGFloat, Color)
        case arrow(CGPoint, CGPoint, CGFloat, Color)
        case text(CGPoint, String, CGFloat, Color)
        case image(CGRect, Data)

        init(_ element: BoardElement) throws {
            switch element {
            case let .stroke(samples, color): self = .stroke(samples, try Color(color))
            case let .line(a, b, width, color): self = .line(a, b, width, try Color(color))
            case let .rectangle(rect, width, color): self = .rectangle(rect, width, try Color(color))
            case let .ellipse(rect, width, color): self = .ellipse(rect, width, try Color(color))
            case let .arrow(a, b, width, color): self = .arrow(a, b, width, try Color(color))
            case let .text(origin, text, size, color): self = .text(origin, text, size, try Color(color))
            case let .image(rect, image):
                guard let data = Self.compressed(image) else { throw CocoaError(.fileWriteUnknown) }
                self = .image(rect, data)
            }
        }

        func native() throws -> BoardElement {
            switch self {
            case let .stroke(samples, color): return .stroke(samples: samples, color: color.native)
            case let .line(a, b, width, color): return .line(start: a, end: b, width: width, color: color.native)
            case let .rectangle(rect, width, color): return .rectangle(rect: rect, width: width, color: color.native)
            case let .ellipse(rect, width, color): return .ellipse(rect: rect, width: width, color: color.native)
            case let .arrow(a, b, width, color): return .arrow(start: a, end: b, width: width, color: color.native)
            case let .text(origin, text, size, color): return .text(origin: origin, string: text, fontSize: size, color: color.native)
            case let .image(rect, data):
                guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                return .image(rect: rect, image: image)
            }
        }

        /// PNG when the image has transparency, JPEG otherwise — TIFF made a
        /// pasted screenshot tens of megabytes.
        private static func compressed(_ image: NSImage) -> Data? {
            if let cached = image.representations.first as? NSBitmapImageRep,
               let png = cached.representation(using: cached.hasAlpha ? .png : .jpeg,
                                               properties: cached.hasAlpha ? [:] : [.compressionFactor: 0.85]) {
                return png
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.hasAlpha
                ? rep.representation(using: .png, properties: [:])
                : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        }
    }
}
