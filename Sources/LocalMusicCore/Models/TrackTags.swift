import Foundation

public enum ArtworkChange: Sendable, Hashable {
    case keep
    case replace(Data)
    case remove
}

/// The editable tag set written into audio files.
public struct TrackTags: Sendable, Hashable {
    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var genre: String?
    public var year: Int?
    public var composer: String?
    public var comment: String?
    public var musicBrainzRecordingID: String?
    public var musicBrainzReleaseID: String?
    public var artwork: ArtworkChange

    public init(title: String, artist: String? = nil, albumArtist: String? = nil, album: String? = nil,
                trackNumber: Int? = nil, trackTotal: Int? = nil, discNumber: Int? = nil, genre: String? = nil,
                year: Int? = nil, composer: String? = nil, comment: String? = nil,
                musicBrainzRecordingID: String? = nil, musicBrainzReleaseID: String? = nil, artwork: ArtworkChange = .keep) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.genre = genre
        self.year = year
        self.composer = composer
        self.comment = comment
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.artwork = artwork
    }

    public init(record r: TrackRecord) {
        self.init(title: r.title, artist: r.artist, albumArtist: r.albumArtist, album: r.album,
                  trackNumber: r.trackNumber, discNumber: r.discNumber, genre: r.genre, year: r.year,
                  composer: r.composer, musicBrainzRecordingID: r.musicBrainzRecordingID,
                  musicBrainzReleaseID: r.musicBrainzReleaseID)
    }

    public var organizeMetadata: OrganizeMetadata {
        OrganizeMetadata(title: title, artist: artist, albumArtist: albumArtist, album: album, year: year,
                         trackNumber: trackNumber, discNumber: discNumber, genre: genre)
    }

    /// Copies the tag fields onto a record (artwork is handled by the caller).
    public func apply(to record: inout TrackRecord) {
        record.title = title
        record.artist = artist
        record.albumArtist = albumArtist
        record.album = album
        record.trackNumber = trackNumber
        record.discNumber = discNumber
        record.genre = genre
        record.year = year
        record.composer = composer
        record.musicBrainzRecordingID = musicBrainzRecordingID
        record.musicBrainzReleaseID = musicBrainzReleaseID
    }

    static func blankToNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Trims every field; empty strings become nil.
    public var normalized: TrackTags {
        var t = self
        t.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.artist = Self.blankToNil(artist)
        t.albumArtist = Self.blankToNil(albumArtist)
        t.album = Self.blankToNil(album)
        t.genre = Self.blankToNil(genre)
        t.composer = Self.blankToNil(composer)
        t.comment = Self.blankToNil(comment)
        if t.trackNumber == 0 { t.trackNumber = nil }
        if t.discNumber == 0 { t.discNumber = nil }
        if let y = t.year, !(1000...2999).contains(y) { t.year = nil }
        return t
    }
}
