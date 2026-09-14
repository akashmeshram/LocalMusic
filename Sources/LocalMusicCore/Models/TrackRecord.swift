import Foundation

/// Immutable snapshot of a library track. The audio file is the source of truth; this is the index row.
public struct TrackRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var fileURL: URL
    public var sourceURL: String?
    public var extractor: String?
    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?
    public var year: Int?
    public var composer: String?
    public var duration: TimeInterval
    public var fileFormat: String
    public var fileSize: Int64
    /// File name inside the artwork cache directory, if any.
    public var artworkFileName: String?
    public var musicBrainzRecordingID: String?
    public var musicBrainzReleaseID: String?
    public var dateAdded: Date
    public var downloadDate: Date?
    public var playCount: Int
    public var isFavorite: Bool
    public var lastPlayedAt: Date?
    public var playbackPosition: TimeInterval?

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        sourceURL: String? = nil,
        extractor: String? = nil,
        title: String,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        genre: String? = nil,
        year: Int? = nil,
        composer: String? = nil,
        duration: TimeInterval = 0,
        fileFormat: String,
        fileSize: Int64 = 0,
        artworkFileName: String? = nil,
        musicBrainzRecordingID: String? = nil,
        musicBrainzReleaseID: String? = nil,
        dateAdded: Date = Date(),
        downloadDate: Date? = nil,
        playCount: Int = 0,
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil,
        playbackPosition: TimeInterval? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.sourceURL = sourceURL
        self.extractor = extractor
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
        self.year = year
        self.composer = composer
        self.duration = duration
        self.fileFormat = fileFormat
        self.fileSize = fileSize
        self.artworkFileName = artworkFileName
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.dateAdded = dateAdded
        self.downloadDate = downloadDate
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
        self.playbackPosition = playbackPosition
    }

    /// Artist shown in lists: album artist first, then artist, then a placeholder.
    public var displayArtist: String { artist ?? albumArtist ?? "Unknown Artist" }
    public var displayAlbum: String { album ?? "Unknown Album" }
    public var yearString: String { year.map(String.init) ?? "" }
    public var sortYear: Int { year ?? 0 }
    public var isRecentlyAdded: Bool { dateAdded > Date().addingTimeInterval(-14 * 24 * 3600) }
    public var formatLabel: String { fileFormat.uppercased() }
}
