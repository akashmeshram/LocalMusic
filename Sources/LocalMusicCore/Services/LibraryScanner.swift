import Foundation

public struct ScannedTrack: Sendable {
    public let fileURL: URL
    public let metadata: AudioFileMetadata
    public let fileSize: Int64
    public let modificationDate: Date?
}

/// Walks the library root and reads tags from each audio file. Hidden folders (including
/// `.incoming`) are skipped so partial downloads never appear in the library.
public struct LibraryScanner: Sendable {
    public static let audioExtensions: Set<String> = [
        "m4a", "mp3", "flac", "wav", "aiff", "aif", "aac", "opus", "ogg", "oga", "webm", "mka", "mp4", "alac", "caf", "m4b",
    ]

    public init() {}

    public func audioFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { continue }
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard !url.lastPathComponent.contains(".part") else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Reads metadata for every audio file, a few at a time. `progress` receives (done, total).
    public func scan(root: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [ScannedTrack] {
        let files = audioFiles(in: root)
        let total = files.count
        var results: [ScannedTrack] = []
        results.reserveCapacity(total)
        let concurrency = 6
        var iterator = files.makeIterator()

        try await withThrowingTaskGroup(of: ScannedTrack?.self) { group in
            var inFlight = 0
            func addNext() {
                guard let url = iterator.next() else { return }
                inFlight += 1
                group.addTask { try await Self.scanOne(url) }
            }
            for _ in 0..<concurrency { addNext() }
            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1
                if let result { results.append(result) }
                progress?(results.count, total)
                try Task.checkCancellation()
                addNext()
            }
        }
        return results.sorted { $0.fileURL.path < $1.fileURL.path }
    }

    public static func scanOne(_ url: URL) async throws -> ScannedTrack? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        do {
            let meta = try await AudioMetadataReader.read(url)
            return ScannedTrack(fileURL: url, metadata: meta, fileSize: size, modificationDate: values?.contentModificationDate)
        } catch {
            Log.warning("skipping unreadable file \(url.lastPathComponent): \(error.localizedDescription)", .library)
            return nil
        }
    }

    /// Builds a `TrackRecord` for a scanned file, falling back to the file name for the title
    /// and parent folders for album/artist when tags are missing.
    public static func record(from scanned: ScannedTrack, root: URL, existing: TrackRecord?, artworkFileName: String?) -> TrackRecord {
        let m = scanned.metadata
        let rel = scanned.fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
        let components = rel.split(separator: "/").map(String.init)
        let folderArtist = components.count >= 3 ? components[0] : nil
        let folderAlbum = components.count >= 3 ? components[1] : nil

        var title = m.title ?? scanned.fileURL.deletingPathExtension().lastPathComponent
        if m.title == nil, let range = title.range(of: #"^\d{1,3}\s*-\s*"#, options: .regularExpression) {
            title = String(title[range.upperBound...])
        }

        var record = existing ?? TrackRecord(fileURL: scanned.fileURL, title: title, fileFormat: scanned.fileURL.pathExtension.lowercased())
        record.fileURL = scanned.fileURL
        record.title = title
        record.artist = m.artist ?? (folderArtist == FileOrganizer.unknownArtist ? nil : folderArtist)
        record.albumArtist = m.albumArtist ?? m.artist ?? (folderArtist == FileOrganizer.unknownArtist ? nil : folderArtist)
        record.album = m.album ?? (folderAlbum.flatMap { $0 == FileOrganizer.singlesFolder || $0 == FileOrganizer.unknownAlbum ? nil : Self.stripYearPrefix($0) })
        record.trackNumber = m.trackNumber
        record.discNumber = m.discNumber
        record.genre = m.genre
        record.year = m.year ?? folderAlbum.flatMap(Self.yearPrefix)
        record.composer = m.composer
        record.duration = m.duration
        record.fileFormat = scanned.fileURL.pathExtension.lowercased()
        record.fileSize = scanned.fileSize
        if let artworkFileName { record.artworkFileName = artworkFileName }
        return record
    }

    static func yearPrefix(_ folder: String) -> Int? {
        guard let m = folder.firstMatch(of: #/^(\d{4}) - /#) else { return nil }
        return Int(m.1)
    }

    static func stripYearPrefix(_ folder: String) -> String {
        folder.replacingOccurrences(of: #"^\d{4} - "#, with: "", options: .regularExpression)
    }
}
