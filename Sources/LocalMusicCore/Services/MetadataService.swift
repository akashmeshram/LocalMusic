import Foundation

/// How a track's metadata was decided. Higher levels are trusted more.
public enum MetadataOrigin: String, Sendable, Codable {
    case titleHeuristic, embeddedTags, sourceSite, musicBrainz, manual
}

public struct IdentifiedMetadata: Sendable, Hashable {
    public var tags: TrackTags
    public var origin: MetadataOrigin
    /// 0…1; only MusicBrainz matches carry a meaningful score in Phase 3.
    public var confidence: Double

    public init(tags: TrackTags, origin: MetadataOrigin, confidence: Double) {
        self.tags = tags
        self.origin = origin
        self.confidence = confidence
    }
}

/// Stages 1–3 of the identification pipeline: read what the source and the file know, clean the
/// noise, and extract probable artist/title/album/year without inventing anything.
/// Stage 4+ (MusicBrainz lookup, scoring, thresholds) plugs in on top of this result.
public struct MetadataService: Sendable {
    public init() {}

    public func identify(source: SourceMetadata, embedded: AudioFileMetadata, fallbackTitle: String, uploader: String?) -> IdentifiedMetadata {
        let channel = TitleCleaner.cleanUploader(source.uploader ?? source.channel ?? uploader)
        let rawTitle = source.title ?? embedded.title ?? fallbackTitle
        let parsed = TitleCleaner.parse(rawTitle, uploader: channel)

        // 1. Structured metadata from the site (YouTube Music, Bandcamp, SoundCloud often provide it).
        if let track = source.track, let artist = source.artist {
            var tags = TrackTags(title: track, artist: artist, albumArtist: source.albumArtist ?? artist,
                                 album: source.album ?? embedded.album, trackNumber: source.trackNumber ?? embedded.trackNumber,
                                 trackTotal: embedded.trackTotal, discNumber: source.discNumber ?? embedded.discNumber,
                                 genre: source.genre ?? embedded.genre, year: source.releaseYear ?? embedded.year, composer: embedded.composer)
            tags.title = TitleCleaner.clean(track)
            return IdentifiedMetadata(tags: tags, origin: .sourceSite, confidence: 0.9)
        }

        // 2. Tags already inside the file (Bandcamp FLACs, tagged MP3s). yt-dlp's own
        //    --embed-metadata stamps the upload title and channel name, which is not real tagging.
        let stampedByDownloader = embedded.title.map { t in
            source.title.map { StringSimilarity.fold($0) == StringSimilarity.fold(t) } ?? false
        } ?? false
        if let title = embedded.title, let artist = embedded.artist, !stampedByDownloader, !Self.looksLikeUploadTitle(title) {
            let tags = TrackTags(title: TitleCleaner.clean(title), artist: artist, albumArtist: embedded.albumArtist ?? artist,
                                 album: embedded.album, trackNumber: embedded.trackNumber, trackTotal: embedded.trackTotal,
                                 discNumber: embedded.discNumber, genre: embedded.genre, year: embedded.year ?? source.releaseYear,
                                 composer: embedded.composer)
            return IdentifiedMetadata(tags: tags, origin: .embeddedTags, confidence: 0.8)
        }

        // 3. Heuristics on the upload title. "Artist - Title" beats the channel name; a "- Topic"
        //    or VEVO channel is a reliable artist; a plain channel name is only a weak hint.
        var title = parsed.title
        if let feat = parsed.featuring { title += " (feat. \(feat))" }
        var artist = parsed.artist ?? source.artist
        var confidence = 0.5
        if artist == nil, let channel {
            let reliableChannel = (source.uploader ?? source.channel ?? uploader)?.contains("Topic") == true
                || (source.uploader ?? uploader)?.uppercased().hasSuffix("VEVO") == true
            artist = channel
            confidence = reliableChannel ? 0.6 : 0.3
        }
        // Year and genre from downloader-stamped tags are the upload date and the site category, not music metadata.
        let embeddedYear = stampedByDownloader ? nil : embedded.year
        let embeddedGenre = stampedByDownloader ? nil : embedded.genre
        let tags = TrackTags(title: title, artist: artist, albumArtist: artist, album: source.album ?? (stampedByDownloader ? nil : embedded.album),
                             trackNumber: source.trackNumber, discNumber: source.discNumber, genre: source.genre ?? embeddedGenre,
                             year: source.releaseYear ?? parsed.year ?? embeddedYear, composer: embedded.composer)
        return IdentifiedMetadata(tags: tags, origin: .titleHeuristic, confidence: confidence)
    }

    /// True when embedded tags look like they were stamped from an upload title by a downloader.
    static func looksLikeUploadTitle(_ title: String) -> Bool {
        TitleCleaner.clean(title) != title.trimmingCharacters(in: .whitespaces)
    }
}
