import Foundation

/// A user playlist: an ordered list of track IDs. Order is the array order; duplicates are allowed.
public struct PlaylistRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var sortIndex: Int
    public var trackIDs: [UUID]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), sortIndex: Int = 0, trackIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.trackIDs = trackIDs
    }
}

/// Reads and writes Extended M3U (`.m3u8`, UTF-8) playlists.
public enum PlaylistFile {
    public struct ImportResult: Sendable {
        public var name: String
        public var matched: [TrackRecord]
        public var unmatchedPaths: [String]
    }

    /// Paths are written relative to the playlist file when the track lives under the same
    /// volume tree, so the folder can be moved as a whole; otherwise absolute.
    public static func export(_ tracks: [TrackRecord], name: String, to fileURL: URL) throws {
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        let base = fileURL.deletingLastPathComponent().standardizedFileURL
        for t in tracks {
            let display = "\(t.displayArtist) - \(t.title)"
            lines.append("#EXTINF:\(Int(t.duration.rounded())),\(display)")
            lines.append(relativePath(of: t.fileURL.standardizedFileURL, to: base) ?? t.fileURL.path)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Matches entries to library tracks by resolved file path; unmatched paths are reported.
    public static func importPlaylist(from fileURL: URL, library: [TrackRecord]) throws -> ImportResult {
        let text: String
        if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) { text = utf8 }
        else { text = try String(contentsOf: fileURL, encoding: .isoLatin1) }
        let base = fileURL.deletingLastPathComponent()
        let byPath = Dictionary(library.map { ($0.fileURL.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        var name = fileURL.deletingPathExtension().lastPathComponent
        var matched: [TrackRecord] = []
        var unmatched: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#PLAYLIST:") { name = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("#") { continue }
            let url: URL
            if line.hasPrefix("file://"), let u = URL(string: line) { url = u }
            else if line.hasPrefix("/") { url = URL(fileURLWithPath: line) }
            else { url = base.appendingPathComponent(line.removingPercentEncoding ?? line) }
            if let track = byPath[url.standardizedFileURL.path] { matched.append(track) } else { unmatched.append(line) }
        }
        return ImportResult(name: name, matched: matched, unmatchedPaths: unmatched)
    }

    static func relativePath(of file: URL, to base: URL) -> String? {
        let f = file.pathComponents, b = base.pathComponents
        var common = 0
        while common < min(f.count, b.count), f[common] == b[common] { common += 1 }
        guard common > 1 else { return nil }
        let ups = Array(repeating: "..", count: b.count - common)
        return (ups + f[common...]).joined(separator: "/")
    }
}
