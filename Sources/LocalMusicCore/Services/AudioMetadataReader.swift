import Foundation
import AVFoundation

/// Tags read from an audio file via AVFoundation (works for M4A, MP3, FLAC, WAV, AIFF, CAF).
public struct AudioFileMetadata: Sendable, Hashable {
    public var title: String?
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
    public var duration: TimeInterval = 0
    public var artwork: Data?
    public var isPlayable: Bool = true

    public init() {}
}

public enum AudioMetadataReader {
    public static func read(_ url: URL) async throws -> AudioFileMetadata {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var meta = AudioFileMetadata()
        do {
            let (duration, common, all, playable) = try await asset.load(.duration, .commonMetadata, .metadata, .isPlayable)
            meta.duration = duration.isNumeric ? CMTimeGetSeconds(duration) : 0
            meta.isPlayable = playable
            try await fill(&meta, common: common, all: all)
        } catch {
            throw LocalMusicError(kind: .invalidAudio, message: "Could not read \(url.lastPathComponent).", technicalDetails: error.localizedDescription)
        }
        return meta
    }

    private static func fill(_ meta: inout AudioFileMetadata, common: [AVMetadataItem], all: [AVMetadataItem]) async throws {
        func first(_ identifiers: [AVMetadataIdentifier]) -> AVMetadataItem? {
            for id in identifiers {
                if let item = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id).first { return item }
                if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: id).first { return item }
            }
            return nil
        }
        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            guard let item = first(identifiers) else { return nil }
            if let s = try? await item.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespaces) }
            if let n = try? await item.load(.numberValue) { return n.stringValue }
            return nil
        }

        meta.title = await string([.commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription])
        meta.artist = await string([.commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer])
        meta.albumArtist = await string([.iTunesMetadataAlbumArtist, .id3MetadataBand])
        meta.album = await string([.commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle])
        meta.composer = await string([.iTunesMetadataComposer, .id3MetadataComposer, .commonIdentifierAuthor])
        meta.genre = await string([.iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .id3MetadataContentType, .quickTimeMetadataGenre])
        meta.comment = await string([.iTunesMetadataUserComment, .id3MetadataComments])

        // Track / disc numbers. iTunes stores binary "0 0 track total 0 0"; ID3 stores "3/12".
        if let item = first([.iTunesMetadataTrackNumber]) {
            if let data = try? await item.load(.dataValue), data.count >= 6 {
                meta.trackNumber = Int(data[2]) << 8 | Int(data[3])
                meta.trackTotal = Int(data[4]) << 8 | Int(data[5])
            } else if let n = try? await item.load(.numberValue) { meta.trackNumber = n.intValue }
        }
        if meta.trackNumber == nil, let s = await string([.id3MetadataTrackNumber]) {
            let parts = s.split(separator: "/")
            meta.trackNumber = parts.first.flatMap { Int($0) }
            meta.trackTotal = parts.count > 1 ? Int(parts[1]) : nil
        }
        if let item = first([.iTunesMetadataDiscNumber]) {
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                meta.discNumber = Int(data[2]) << 8 | Int(data[3])
            } else if let n = try? await item.load(.numberValue) { meta.discNumber = n.intValue }
        }
        if meta.discNumber == nil, let s = await string([.id3MetadataPartOfASet]) {
            meta.discNumber = s.split(separator: "/").first.flatMap { Int($0) }
        }
        if meta.trackNumber == 0 { meta.trackNumber = nil }
        if meta.discNumber == 0 { meta.discNumber = nil }

        if let dateString = await string([.iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime, .id3MetadataOriginalReleaseYear, .commonIdentifierCreationDate]) {
            meta.year = parseYear(dateString)
        }
        if let item = first([.commonIdentifierArtwork, .iTunesMetadataCoverArt, .id3MetadataAttachedPicture]) {
            meta.artwork = try? await item.load(.dataValue)
        }
    }

    public static func parseYear(_ s: String) -> Int? {
        guard let range = s.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        let y = Int(s[range]) ?? 0
        return (1000...2999).contains(y) ? y : nil
    }
}
