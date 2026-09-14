import Foundation
import AVFoundation

/// Writes iTunes-style atoms into M4A/MP4 files through `AVAssetExportSession` with the
/// passthrough preset, so the AAC/ALAC stream is copied, not re-encoded.
public struct MP4TagWriter: TagWriter {
    public init() {}

    static let managed: Set<AVMetadataIdentifier> = [
        .iTunesMetadataSongName, .iTunesMetadataArtist, .iTunesMetadataAlbumArtist, .iTunesMetadataAlbum,
        .iTunesMetadataTrackNumber, .iTunesMetadataDiscNumber, .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre,
        .iTunesMetadataReleaseDate, .iTunesMetadataComposer, .iTunesMetadataUserComment, .iTunesMetadataCoverArt,
        .commonIdentifierTitle, .commonIdentifierArtist, .commonIdentifierAlbumName, .commonIdentifierArtwork,
        .commonIdentifierCreationDate, .commonIdentifierAuthor, .commonIdentifierType,
    ]

    public func write(_ tags: TrackTags, to file: URL) async throws {
        let asset = AVURLAsset(url: file)
        let existing = try await asset.load(.metadata)
        var items: [AVMetadataItem] = existing.filter { item in
            guard let id = item.identifier else { return true }
            if Self.managed.contains(id) { return false }
            if id.rawValue.hasPrefix("itsk/----:com.apple.iTunes:MusicBrainz") { return false }
            return true
        }
        if case .keep = tags.artwork, let art = existing.first(where: { $0.identifier == .iTunesMetadataCoverArt || $0.identifier == .commonIdentifierArtwork }) {
            items.append(art)
        }
        items += Self.items(for: tags)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw LocalMusicError(kind: .toolFailed, message: "Could not open \(file.lastPathComponent) for tag editing.")
        }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).lmtmp.m4a")
        try? FileManager.default.removeItem(at: tmp)
        session.outputURL = tmp
        session.outputFileType = file.pathExtension.lowercased() == "m4b" ? .m4a : (file.pathExtension.lowercased() == "mp4" ? .mp4 : .m4a)
        session.metadata = items
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw LocalMusicError(kind: .toolFailed, message: "Could not write tags to \(file.lastPathComponent).",
                                  technicalDetails: session.error?.localizedDescription)
        }
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    static func item(_ id: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?, dataType: String? = nil) -> AVMetadataItem? {
        guard let value else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value
        item.extendedLanguageTag = "und"
        if let dataType { item.dataType = dataType }
        return item
    }

    static func items(for tags: TrackTags) -> [AVMetadataItem] {
        var list: [AVMetadataItem?] = [
            item(.iTunesMetadataSongName, tags.title as NSString),
            item(.iTunesMetadataArtist, tags.artist as NSString?),
            item(.iTunesMetadataAlbumArtist, tags.albumArtist as NSString?),
            item(.iTunesMetadataAlbum, tags.album as NSString?),
            item(.iTunesMetadataUserGenre, tags.genre as NSString?),
            item(.iTunesMetadataReleaseDate, tags.year.map { String($0) as NSString }),
            item(.iTunesMetadataComposer, tags.composer as NSString?),
            item(.iTunesMetadataUserComment, tags.comment as NSString?),
        ]
        if let n = tags.trackNumber {
            var d = Data([0, 0]); d.appendBE16(UInt16(clamping: n)); d.appendBE16(UInt16(clamping: tags.trackTotal ?? 0)); d.append(contentsOf: [0, 0])
            list.append(item(.iTunesMetadataTrackNumber, d as NSData))
        }
        if let disc = tags.discNumber {
            var d = Data([0, 0]); d.appendBE16(UInt16(clamping: disc)); d.appendBE16(0)
            list.append(item(.iTunesMetadataDiscNumber, d as NSData))
        }
        if let mbid = tags.musicBrainzRecordingID {
            list.append(item(AVMetadataIdentifier("itsk/----:com.apple.iTunes:MusicBrainz Track Id"), mbid as NSString))
        }
        if let rel = tags.musicBrainzReleaseID {
            list.append(item(AVMetadataIdentifier("itsk/----:com.apple.iTunes:MusicBrainz Album Id"), rel as NSString))
        }
        if case .replace(let image) = tags.artwork {
            let type = ImageSniffer.mimeType(of: image) == "image/png" ? "com.apple.metadata.datatype.PNG" : "com.apple.metadata.datatype.JPEG"
            list.append(item(.iTunesMetadataCoverArt, image as NSData, dataType: type))
        }
        return list.compactMap { $0 }
    }
}
