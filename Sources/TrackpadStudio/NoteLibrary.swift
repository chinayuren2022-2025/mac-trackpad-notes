import AppKit

struct NoteInfo: Codable, Equatable {
    let id: String
    var title: String
    let created: Date
    var modified: Date
}

/// All notes live in one folder: `<id>.json` (a BoardArchive), `<id>.png`
/// (list thumbnail) and `index.json` (titles and dates, so the list opens
/// without parsing every note). The index is rebuilt from the files if it
/// is lost or out of date.
final class NoteLibrary {
    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackpadStudio-Handwriting/Notes", isDirectory: true)
    }

    let folder: URL
    /// Newest first.
    private(set) var notes: [NoteInfo] = []
    private let io = DispatchQueue(label: "notes.io")

    init(folder: URL = NoteLibrary.defaultFolder) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }
    func noteURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }
    func thumbnailURL(_ id: String) -> URL { folder.appendingPathComponent(id + ".png") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var indexed = (try? decoder.decode([NoteInfo].self, from: Data(contentsOf: indexURL))) ?? []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
        )) ?? []
        let ids = Set(files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        indexed.removeAll { !ids.contains($0.id) }
        // Note files the index doesn't know (index lost, or copied in by hand).
        for id in ids where !indexed.contains(where: { $0.id == id }) {
            let values = try? noteURL(id).resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let modified = values?.contentModificationDate ?? Date()
            indexed.append(NoteInfo(id: id, title: Self.defaultTitle(for: modified),
                                    created: values?.creationDate ?? modified, modified: modified))
        }
        notes = indexed.sorted { $0.modified > $1.modified }
        writeIndex()
    }

    private func writeIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(notes) else { return }
        let url = indexURL
        io.async { try? data.write(to: url, options: .atomic) }
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "笔记 " + formatter.string(from: date)
    }

    func info(_ id: String) -> NoteInfo? { notes.first { $0.id == id } }

    /// A new, empty note at the top of the list (written on first save).
    @discardableResult
    func create(title: String? = nil, data: Data? = nil) -> NoteInfo {
        let now = Date()
        let note = NoteInfo(id: UUID().uuidString, title: title ?? Self.defaultTitle(for: now), created: now, modified: now)
        notes.insert(note, at: 0)
        if let data { try? data.write(to: noteURL(note.id), options: .atomic) }
        writeIndex()
        return note
    }

    func data(for id: String) -> Data? {
        io.sync {}   // a save still in flight must land first
        return try? Data(contentsOf: noteURL(id))
    }

    /// Saves content off the main thread. `sync` blocks until written (quit).
    func save(_ id: String, data: Data, thumbnail: Data?, sync: Bool = false) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].modified = Date()
        let note = notes.remove(at: index)
        notes.insert(note, at: 0)
        let (url, thumbURL) = (noteURL(id), thumbnailURL(id))
        let work = {
            try? data.write(to: url, options: .atomic)
            if let thumbnail {
                try? thumbnail.write(to: thumbURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: thumbURL)
            }
        }
        if sync { io.sync(execute: work) } else { io.async(execute: work) }
        writeIndex()
        if sync { io.sync {} }
    }

    func rename(_ id: String, to title: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].title = trimmed.isEmpty ? Self.defaultTitle(for: notes[index].created) : trimmed
        writeIndex()
    }

    @discardableResult
    func duplicate(_ id: String) -> NoteInfo? {
        guard let original = info(id) else { return nil }
        let copy = create(title: original.title + " 副本", data: data(for: id))
        try? FileManager.default.copyItem(at: thumbnailURL(id), to: thumbnailURL(copy.id))
        return copy
    }

    /// Moves the note to the Trash (recoverable from Finder).
    func trash(_ id: String) {
        io.sync {}
        for url in [noteURL(id), thumbnailURL(id)] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        notes.removeAll { $0.id == id }
        writeIndex()
    }

    func thumbnail(_ id: String) -> NSImage? {
        NSImage(contentsOf: thumbnailURL(id))
    }

    /// Blocks until every queued write is on disk.
    func flush() {
        io.sync {}
    }
}
