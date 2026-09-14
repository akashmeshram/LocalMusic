import Foundation

/// Rewrites the VORBIS_COMMENT and PICTURE metadata blocks of a FLAC file; audio frames are untouched.
public struct FLACTagWriter: TagWriter {
    public init() {}

    public struct Block: Equatable, Sendable {
        public let type: UInt8
        public let data: Data
    }

    static let streamInfo: UInt8 = 0, padding: UInt8 = 1, vorbisComment: UInt8 = 4, picture: UInt8 = 6
    static let managedKeys: Set<String> = ["TITLE", "ARTIST", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM", "TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS", "DISCNUMBER", "GENRE", "DATE", "YEAR", "COMPOSER", "COMMENT", "DESCRIPTION", "MUSICBRAINZ_TRACKID", "MUSICBRAINZ_ALBUMID"]

    public func write(_ tags: TrackTags, to file: URL) async throws {
        let original = try Data(contentsOf: file)
        guard let (blocks, audioOffset) = Self.parse(original) else {
            throw LocalMusicError(kind: .invalidAudio, message: "Not a FLAC file: \(file.lastPathComponent)")
        }
        var kept: [Block] = []
        var existingComments: [String] = []
        var vendor = "LocalMusic"
        for block in blocks {
            switch block.type {
            case Self.vorbisComment:
                let parsed = Self.parseComments(block.data)
                vendor = parsed.vendor
                existingComments = parsed.comments.filter { c in
                    guard let eq = c.firstIndex(of: "=") else { return false }
                    return !Self.managedKeys.contains(String(c[..<eq]).uppercased())
                }
            case Self.picture:
                if case .keep = tags.artwork { kept.append(block) }
            case Self.padding:
                break
            default:
                kept.append(block)
            }
        }
        var comments = existingComments
        func add(_ key: String, _ value: String?) { if let v = value, !v.isEmpty { comments.append("\(key)=\(v)") } }
        add("TITLE", tags.title)
        add("ARTIST", tags.artist)
        add("ALBUMARTIST", tags.albumArtist)
        add("ALBUM", tags.album)
        add("TRACKNUMBER", tags.trackNumber.map(String.init))
        add("TRACKTOTAL", tags.trackTotal.map(String.init))
        add("DISCNUMBER", tags.discNumber.map(String.init))
        add("GENRE", tags.genre)
        add("DATE", tags.year.map(String.init))
        add("COMPOSER", tags.composer)
        add("COMMENT", tags.comment)
        add("MUSICBRAINZ_TRACKID", tags.musicBrainzRecordingID)
        add("MUSICBRAINZ_ALBUMID", tags.musicBrainzReleaseID)

        var ordered: [Block] = []
        if let info = kept.first(where: { $0.type == Self.streamInfo }) { ordered.append(info) }
        ordered.append(Block(type: Self.vorbisComment, data: Self.buildComments(vendor: vendor, comments: comments)))
        ordered += kept.filter { $0.type != Self.streamInfo }
        if case .replace(let image) = tags.artwork {
            ordered.append(Block(type: Self.picture, data: Self.buildPicture(image)))
        }
        ordered.append(Block(type: Self.padding, data: Data(count: 4096)))

        var out = Data("fLaC".utf8)
        for (i, block) in ordered.enumerated() {
            let last = i == ordered.count - 1
            out.append((last ? 0x80 : 0) | block.type)
            let len = UInt32(block.data.count)
            out.append(UInt8((len >> 16) & 0xFF)); out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
            out.append(block.data)
        }
        out.append(original.slice(audioOffset, original.count - audioOffset))
        try TagWriterService.replaceAtomically(file, with: out)
    }

    public static func parse(_ data: Data) -> ([Block], Int)? {
        guard data.count > 8, data.starts(with: Array("fLaC".utf8)) else { return nil }
        var offset = 4
        var blocks: [Block] = []
        while offset + 4 <= data.count {
            let header = data[data.startIndex + offset]
            let type = header & 0x7F
            let length = Int(data.be24(at: offset + 1))
            offset += 4
            guard offset + length <= data.count else { return nil }
            blocks.append(Block(type: type, data: data.slice(offset, length)))
            offset += length
            if header & 0x80 != 0 { break }
        }
        return (blocks, offset)
    }

    public static func parseComments(_ data: Data) -> (vendor: String, comments: [String]) {
        var offset = 0
        let vendorLen = Int(data.le32(at: offset)); offset += 4
        let vendor = String(data: data.slice(offset, vendorLen), encoding: .utf8) ?? ""; offset += vendorLen
        let count = Int(data.le32(at: offset)); offset += 4
        var comments: [String] = []
        for _ in 0..<count {
            guard offset + 4 <= data.count else { break }
            let len = Int(data.le32(at: offset)); offset += 4
            if let s = String(data: data.slice(offset, len), encoding: .utf8) { comments.append(s) }
            offset += len
        }
        return (vendor, comments)
    }

    static func buildComments(vendor: String, comments: [String]) -> Data {
        var d = Data()
        let v = Data(vendor.utf8)
        d.appendLE32(UInt32(v.count)); d.append(v)
        d.appendLE32(UInt32(comments.count))
        for c in comments {
            let cd = Data(c.utf8)
            d.appendLE32(UInt32(cd.count)); d.append(cd)
        }
        return d
    }

    static func buildPicture(_ image: Data) -> Data {
        var d = Data()
        d.appendBE32(3) // front cover
        let mime = Data(ImageSniffer.mimeType(of: image).utf8)
        d.appendBE32(UInt32(mime.count)); d.append(mime)
        d.appendBE32(0) // description length
        let (w, h) = ImageInfo.dimensions(of: image) ?? (0, 0)
        d.appendBE32(UInt32(w)); d.appendBE32(UInt32(h)); d.appendBE32(24); d.appendBE32(0)
        d.appendBE32(UInt32(image.count)); d.append(image)
        return d
    }
}
