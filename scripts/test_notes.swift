import AppKit

// S=Sources/TrackpadStudio
// swiftc -parse-as-library scripts/test_notes.swift $S/{BoardModel,BoardArchive,InkRenderer,NoteLibrary}.swift -o /tmp/tn && /tmp/tn

@main
struct NotesChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS " : "FAIL ") + name)
        if !ok { failures += 1 }
    }
    static func stroke(_ pts: [(CGFloat, CGFloat)], _ color: NSColor = .black) -> BoardElement {
        .stroke(samples: pts.map { BoardStrokeSample(point: CGPoint(x: $0.0, y: $0.1), width: 2) }, color: color)
    }
    static func line(_ y: CGFloat) -> BoardElement {
        stroke(stride(from: 0, through: 100, by: 5).map { (CGFloat($0), y) })
    }

    static func main() {
        // Partial eraser cuts a stroke in two and keeps both halves.
        let m = BoardModel()
        m.append(line(0))
        m.erase(from: CGPoint(x: 50, y: -20), to: CGPoint(x: 50, y: 20), radius: 4, partial: true, recordingUndo: true)
        check(m.elements.count == 2, "partial eraser splits a stroke in two")
        let ok = m.elements.allSatisfy {
            if case let .stroke(s, _) = $0 { return s.allSatisfy { abs($0.point.x - 50) > 4 } }
            return false
        }
        check(ok, "no ink left under the eraser")
        m.erase(from: CGPoint(x: -5, y: 0), to: CGPoint(x: 120, y: 0), radius: 4, partial: true, recordingUndo: false)
        check(m.elements.isEmpty, "erasing along the whole stroke leaves nothing")
        m.undo()
        check(m.elements.count == 1, "one undo restores the whole partial-erase gesture")

        // Shapes go whole even with the partial eraser.
        m.append(.rectangle(rect: CGRect(x: 200, y: 0, width: 100, height: 100), width: 2, color: .black))
        m.erase(from: CGPoint(x: 297, y: 50), to: CGPoint(x: 297, y: 55), radius: 5, partial: true, recordingUndo: true)
        check(m.elements.count == 1, "partial eraser removes a shape whole")

        // Redo.
        m.undo()
        check(m.elements.count == 2 && m.canRedo, "undo makes redo available")
        m.redo()
        check(m.elements.count == 1, "redo re-applies the erase")
        m.undo()
        m.append(line(300))
        check(!m.canRedo, "a new edit clears the redo stack")

        // Lasso, move, recolor.
        let l = BoardModel()
        l.append(line(0))                                                     // 0 inside
        l.append(line(40))                                                    // 1 inside
        l.append(line(500))                                                   // 2 outside
        l.append(stroke([(50, 60), (400, 60)]))                               // 3 mostly outside
        let lasso = [CGPoint(x: -10, y: -10), CGPoint(x: 120, y: -10), CGPoint(x: 120, y: 80), CGPoint(x: -10, y: 80)]
        let picked = l.indices(inLasso: lasso)
        check(picked == IndexSet([0, 1]), "lasso picks elements mostly inside")
        l.translate(picked, by: CGPoint(x: 10, y: 5))
        if case let .stroke(s, _) = l.elements[0] { check(s[0].point == CGPoint(x: 10, y: 5), "translate moves the selection") }
        if case let .stroke(s, _) = l.elements[2] { check(s[0].point.x == 0, "translate leaves the rest alone") }
        l.recolor(picked, to: .red)
        if case let .stroke(_, c) = l.elements[0] { check(c == .red, "recolor changes color") }
        let hl = NSColor.yellow.withAlphaComponent(0.38)
        l.append(stroke([(0, 900), (50, 900)], hl))
        l.recolor(IndexSet([4]), to: .blue)
        if case let .stroke(_, c) = l.elements[4] {
            check(abs(c.alphaComponent - 0.38) < 0.01, "recolored highlighter stays translucent")
        }
        l.undo(); l.undo(); l.undo(); l.undo()   // recolor, append, recolor, move
        if case let .stroke(s, _) = l.elements[0] { check(s[0].point.x == 0, "undo reverts the move") }

        // Paper style survives save / load; loading clears history.
        let d = BoardModel()
        d.append(line(0))
        d.paper = .lined
        let data = try! d.documentData()
        let e = BoardModel()
        try! e.loadDocument(data)
        check(e.paper == .lined && e.elements.count == 1, "paper and content round-trip")
        check(!e.canUndo && !e.canRedo, "loading a note starts with empty history")

        // Note library on a throwaway folder.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-check-\(UUID().uuidString)")
        let lib = NoteLibrary(folder: folder)
        check(lib.notes.isEmpty, "new library is empty")
        let a = lib.create(title: "A")
        let b = lib.create(title: "B")
        check(lib.notes.map(\.title) == ["B", "A"], "newest note first")
        lib.save(a.id, data: data, thumbnail: nil, sync: true)
        check(lib.notes.first?.id == a.id, "saving moves the note to the top")
        lib.rename(b.id, to: "  第二条  ")
        lib.rename(a.id, to: "   ")
        check(lib.info(b.id)?.title == "第二条", "rename trims spaces")
        check(lib.info(a.id)?.title.hasPrefix("笔记 ") == true, "blank title falls back to the date")
        let copy = lib.duplicate(a.id)
        check(copy.map { lib.data(for: $0.id) == data } == true, "duplicate copies content")
        lib.flush()

        let reopened = NoteLibrary(folder: folder)
        // B was never saved, so it has no file and drops out on reload.
        check(Set(reopened.notes.map(\.id)) == Set([a.id, copy!.id]), "reload keeps saved notes only")
        check(reopened.data(for: a.id) == data, "content readable after reload")
        reopened.trash(copy!.id)
        reopened.flush()
        check(!FileManager.default.fileExists(atPath: reopened.noteURL(copy!.id).path), "trash removes the file")
        try? FileManager.default.removeItem(at: folder)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
