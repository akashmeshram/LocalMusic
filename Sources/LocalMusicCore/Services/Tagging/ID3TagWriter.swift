import Foundation

/// Rewrites the ID3v2 tag at the start of an MP3 (as ID3v2.4, UTF-8) leaving the audio frames
/// untouched. Frames the app does not manage (lyrics, TXXX, …) are carried over.
public struct ID3TagWriter: TagWriter {
    public init() {}

    static let managedFrames: Set<String> = ["TIT2", "TPE1", "TPE2", "TALB", "TRCK", "TPOS", "TCON", "TYER", "TDRC", "TDRL", "TORY", "TCOM", "COMM", "UFID", "TXXX:MUSICBRAINZ ALBUM ID"]
    static let padding = 1024

    public struct Frame: Equatable, Sendable {
        public let id: String
        public let data: Data
    }

    public struct ParsedTag: Sendable {
        public var frames: [Frame]
        /// Byte offset where audio data begins.
        public var audioOffset: Int
    }

    public func write(_ tags: TrackTags, to file: URL) async throws {
        let original = try Data(contentsOf: file)
        let parsed = Self.parse(original)
        var frames: [Frame] = parsed.frames.filter { !Self.isManaged($0) }
        if case .keep = tags.artwork {
            // keep existing APIC frames
        } else {
            frames.removeAll { $0.id == "APIC" }
        }
        if !tags.chapters.isEmpty {
            frames.removeAll { $0.id == "CHAP" || $0.id == "CTOC" }
        }
        frames += Self.frames(for: tags)
        let tag = Self.buildTag(frames: frames)
        var out = Data(capacity: tag.count + original.count - parsed.audioOffset)
        out.append(tag)
        out.append(original.slice(parsed.audioOffset, original.count - parsed.audioOffset))
        try TagWriterService.replaceAtomically(file, with: out)
    }

    static func isManaged(_ frame: Frame) -> Bool {
        if managedFrames.contains(frame.id) { return true }
        if frame.id == "TXXX", let desc = txxxDescription(frame.data)?.uppercased(),
           desc.hasPrefix("MUSICBRAINZ") { return true }
        return false
    }

    static func txxxDescription(_ data: Data) -> String? {
        guard data.count > 1 else { return nil }
        let encoding = data[data.startIndex]
        let body = data.slice(1, data.count - 1)
        if encoding == 0 || encoding == 3 {
            guard let nul = body.firstIndex(of: 0) else { return nil }
            return String(data: body[body.startIndex..<nul], encoding: encoding == 0 ? .isoLatin1 : .utf8)
        }
        return nil
    }

    // MARK: Parsing

    public static func parse(_ data: Data) -> ParsedTag {
        guard data.count >= 10, data.starts(with: [0x49, 0x44, 0x33]) else { return ParsedTag(frames: [], audioOffset: 0) }
        let major = data[data.startIndex + 3]
        let flags = data[data.startIndex + 5]
        let size = Int(syncsafe(data.be32(at: 6)))
        var tagEnd = 10 + size
        if flags & 0x10 != 0 { tagEnd += 10 }
        tagEnd = min(tagEnd, data.count)
        var frames: [Frame] = []
        let unsynchronised = flags & 0x80 != 0
        guard major == 3 || major == 4, !unsynchronised else {
            // v2.2 or unsynchronised tags: drop the old frames, we rewrite ours.
            return ParsedTag(frames: [], audioOffset: tagEnd)
        }
        var offset = 10
        if flags & 0x40 != 0 { // extended header
            let extSize = major == 4 ? Int(syncsafe(data.be32(at: offset))) : Int(data.be32(at: offset)) + 4
            offset += extSize
        }
        while offset + 10 <= tagEnd {
            let idData = data.slice(offset, 4)
            guard let id = String(data: idData, encoding: .isoLatin1), id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { break }
            let frameSize = major == 4 ? Int(syncsafe(data.be32(at: offset + 4))) : Int(data.be32(at: offset + 4))
            let frameFlags = data.be32(at: offset + 8) >> 16
            offset += 10
            guard frameSize > 0, offset + frameSize <= tagEnd else { break }
            let compressedOrEncrypted = major == 4 ? (frameFlags & 0x000C) != 0 : (frameFlags & 0x00C0) != 0
            if !compressedOrEncrypted {
                frames.append(Frame(id: id, data: data.slice(offset, frameSize)))
            }
            offset += frameSize
        }
        return ParsedTag(frames: frames, audioOffset: tagEnd)
    }

    static func syncsafe(_ v: UInt32) -> UInt32 {
        ((v & 0x7F000000) >> 3) | ((v & 0x007F0000) >> 2) | ((v & 0x00007F00) >> 1) | (v & 0x0000007F)
    }

    static func toSyncsafe(_ v: Int) -> UInt32 {
        let u = UInt32(v)
        return ((u & 0x0FE00000) << 3) | ((u & 0x001FC000) << 2) | ((u & 0x00003F80) << 1) | (u & 0x0000007F)
    }

    // MARK: Building

    static func text(_ id: String, _ value: String?) -> Frame? {
        guard let value, !value.isEmpty else { return nil }
        var d = Data([0x03])
        d.append(Data(value.utf8))
        return Frame(id: id, data: d)
    }

    static func frames(for tags: TrackTags) -> [Frame] {
        var f: [Frame] = []
        f.append(text("TIT2", tags.title)!)
        if let x = text("TPE1", tags.artist) { f.append(x) }
        if let x = text("TPE2", tags.albumArtist) { f.append(x) }
        if let x = text("TALB", tags.album) { f.append(x) }
        if let n = tags.trackNumber {
            f.append(text("TRCK", tags.trackTotal.map { "\(n)/\($0)" } ?? "\(n)")!)
        }
        if let d = tags.discNumber { f.append(text("TPOS", "\(d)")!) }
        if let x = text("TCON", tags.genre) { f.append(x) }
        if let y = tags.year { f.append(text("TDRC", "\(y)")!) }
        if let x = text("TCOM", tags.composer) { f.append(x) }
        if let c = tags.comment, !c.isEmpty {
            var d = Data([0x03]); d.append(Data("eng".utf8)); d.append(0); d.append(Data(c.utf8))
            f.append(Frame(id: "COMM", data: d))
        }
        if let mbid = tags.musicBrainzRecordingID {
            var d = Data("http://musicbrainz.org".utf8); d.append(0); d.append(Data(mbid.utf8))
            f.append(Frame(id: "UFID", data: d))
        }
        if let rel = tags.musicBrainzReleaseID {
            var d = Data([0x03]); d.append(Data("MusicBrainz Album Id".utf8)); d.append(0); d.append(Data(rel.utf8))
            f.append(Frame(id: "TXXX", data: d))
        }
        if case .replace(let image) = tags.artwork {
            var d = Data([0x00])
            d.append(Data(ImageSniffer.mimeType(of: image).utf8)); d.append(0)
            d.append(0x03) // front cover
            d.append(0)    // empty description
            d.append(image)
            f.append(Frame(id: "APIC", data: d))
        }
        f += chapterFrames(tags.chapters)
        return f
    }

    // MARK: Chapters (ID3v2 Chapter Frame Addendum)

    static func chapterElementID(_ index: Int) -> String { "chp\(index)" }

    /// One CHAP frame per chapter (with an embedded TIT2) plus a top-level ordered CTOC.
    static func chapterFrames(_ chapters: [TrackChapter]) -> [Frame] {
        guard !chapters.isEmpty else { return [] }
        var frames: [Frame] = []
        var toc = Data(); toc.append(Data("toc".utf8)); toc.append(0)
        toc.append(0x03) // top-level + ordered
        toc.append(UInt8(min(chapters.count, 255)))
        for (i, chapter) in chapters.prefix(255).enumerated() {
            let element = chapterElementID(i)
            toc.append(Data(element.utf8)); toc.append(0)
            var d = Data(element.utf8); d.append(0)
            d.appendBE32(UInt32(max(0, chapter.start) * 1000))
            d.appendBE32(UInt32(max(chapter.start, chapter.end) * 1000))
            d.appendBE32(0xFFFF_FFFF); d.appendBE32(0xFFFF_FFFF) // byte offsets unused
            if let title = text("TIT2", chapter.title) {
                d.append(Data(title.id.utf8)); d.appendBE32(toSyncsafe(title.data.count)); d.appendBE16(0); d.append(title.data)
            }
            frames.append(Frame(id: "CHAP", data: d))
        }
        frames.insert(Frame(id: "CTOC", data: toc), at: 0)
        return frames
    }

    /// Reads chapters back out of parsed CHAP frames (for tests, diagnostics and the reader).
    public static func chapters(in frames: [Frame]) -> [TrackChapter] {
        frames.filter { $0.id == "CHAP" }.compactMap { frame -> TrackChapter? in
            let d = frame.data
            guard let nul = d.firstIndex(of: 0) else { return nil }
            var offset = nul - d.startIndex + 1
            guard d.count >= offset + 16 else { return nil }
            let start = Double(d.be32(at: offset)) / 1000; let end = Double(d.be32(at: offset + 4)) / 1000
            offset += 16
            var title = ""
            while offset + 10 <= d.count {
                guard let id = String(data: d.slice(offset, 4), encoding: .isoLatin1) else { break }
                let size = Int(syncsafe(d.be32(at: offset + 4)))
                offset += 10
                guard size > 0, offset + size <= d.count else { break }
                if id == "TIT2" { title = textValue(Frame(id: id, data: d.slice(offset, size))) ?? "" }
                offset += size
            }
            return TrackChapter(title: title, start: start, end: end)
        }
    }

    static func buildTag(frames: [Frame]) -> Data {
        var body = Data()
        for frame in frames {
            body.append(Data(frame.id.utf8))
            body.appendBE32(toSyncsafe(frame.data.count))
            body.appendBE16(0)
            body.append(frame.data)
        }
        body.append(Data(count: padding))
        var tag = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
        tag.appendBE32(toSyncsafe(body.count))
        tag.append(body)
        return tag
    }

    /// Decodes a text frame (used by tests and diagnostics).
    public static func textValue(_ frame: Frame) -> String? {
        guard let enc = frame.data.first else { return nil }
        let body = frame.data.slice(1, frame.data.count - 1)
        let encoding: String.Encoding = switch enc { case 0: .isoLatin1; case 1: .utf16; case 2: .utf16BigEndian; default: .utf8 }
        return String(data: body, encoding: encoding)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
