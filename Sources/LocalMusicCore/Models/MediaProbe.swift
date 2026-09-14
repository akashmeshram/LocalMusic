import Foundation

/// A single downloadable item discovered by probing a URL.
public struct MediaEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let title: String
    public let uploader: String?
    public let duration: TimeInterval?
    public let thumbnailURL: URL?
    public let playlistIndex: Int?

    public init(id: String, url: URL, title: String, uploader: String? = nil, duration: TimeInterval? = nil,
                thumbnailURL: URL? = nil, playlistIndex: Int? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.playlistIndex = playlistIndex
    }
}

public struct PlaylistInfo: Hashable, Sendable {
    public let title: String
    public let url: URL
    public let uploader: String?
    public let entries: [MediaEntry]

    public init(title: String, url: URL, uploader: String? = nil, entries: [MediaEntry]) {
        self.title = title
        self.url = url
        self.uploader = uploader
        self.entries = entries
    }
}

public enum MediaProbe: Sendable {
    case single(MediaEntry)
    case playlist(PlaylistInfo)
}

/// Output format policy for downloads.
public enum PreferredFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Keep the original stream (prefer M4A/AAC). Only non-playable codecs (Opus/Vorbis) are converted to M4A.
    case original
    case m4a
    case mp3

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .original: "Original (prefer M4A)"
        case .m4a: "Always M4A (AAC)"
        case .mp3: "Always MP3"
        }
    }
}

public struct DownloadRequest: Sendable {
    public let url: URL
    public let destinationDirectory: URL
    public let format: PreferredFormat
    public let ffmpegDirectory: URL?
    public let archiveFile: URL?
    public let embedMetadata: Bool
    public let embedThumbnail: Bool

    public init(url: URL, destinationDirectory: URL, format: PreferredFormat, ffmpegDirectory: URL?,
                archiveFile: URL?, embedMetadata: Bool = true, embedThumbnail: Bool = true) {
        self.url = url
        self.destinationDirectory = destinationDirectory
        self.format = format
        self.ffmpegDirectory = ffmpegDirectory
        self.archiveFile = archiveFile
        self.embedMetadata = embedMetadata
        self.embedThumbnail = embedThumbnail
    }
}

/// Metadata yt-dlp knew about the source, read from its `.info.json`.
public struct SourceMetadata: Hashable, Sendable {
    public var id: String?
    public var title: String?
    public var track: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var uploader: String?
    public var channel: String?
    public var releaseYear: Int?
    public var uploadDate: Date?
    public var duration: TimeInterval?
    public var thumbnailURL: URL?
    public var webpageURL: URL?
    public var extractor: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?

    public init() {}
}

public struct DownloadResult: Sendable {
    public let fileURL: URL
    public let infoJSONURL: URL?
    public let metadata: SourceMetadata
    public let log: String

    public init(fileURL: URL, infoJSONURL: URL?, metadata: SourceMetadata, log: String) {
        self.fileURL = fileURL
        self.infoJSONURL = infoJSONURL
        self.metadata = metadata
        self.log = log
    }
}
