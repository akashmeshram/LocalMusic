import Foundation
import Observation
import AppKit
import LocalMusicCore

@MainActor
@Observable
final class LibraryViewModel {
    private(set) var tracks: [TrackRecord] = []
    var searchText = ""
    var sortOrder: [KeyPathComparator<TrackRecord>] = [KeyPathComparator(\.dateAdded, order: .reverse)]
    private(set) var isScanning = false
    private(set) var scanProgress: (done: Int, total: Int)?
    var errorMessage: String?

    private unowned let env: AppEnvironment
    private let scanner = LibraryScanner()

    init(env: AppEnvironment) {
        self.env = env
    }

    var trackByID: [TrackRecord.ID: TrackRecord] {
        Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    // MARK: Loading

    func load() async {
        do {
            tracks = try await env.store.allTracks()
        } catch {
            errorMessage = LocalMusicError.wrap(error).message
        }
    }

    /// Scans the music folder, adds new files, updates changed ones and drops rows whose file is gone.
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = nil
        defer { isScanning = false; scanProgress = nil }
        let root = env.settings.musicDirectory
        do {
            try AppPaths.ensureDirectories(musicRoot: root)
            let existing = Dictionary(uniqueKeysWithValues: tracks.map { ($0.fileURL.path, $0) })
            let scanned = try await scanner.scan(root: root) { done, total in
                Task { @MainActor [weak self] in self?.scanProgress = (done, total) }
            }
            var records: [TrackRecord] = []
            for item in scanned {
                var artworkName: String?
                if let data = item.metadata.artwork { artworkName = try? env.artwork.store(data) }
                records.append(LibraryScanner.record(from: item, root: root, existing: existing[item.fileURL.path], artworkFileName: artworkName))
            }
            try await env.store.upsert(records)
            let removed = try await env.store.deleteTracks(notIn: Set(scanned.map(\.fileURL.path)))
            Log.info("scan complete: \(records.count) files, \(removed) removed", .library)
            await load()
        } catch {
            errorMessage = LocalMusicError.wrap(error).message
            Log.error("scan failed: \(error)", .library)
        }
    }

    /// Drops the index and rebuilds it from the files on disk.
    func rebuild() async {
        do {
            try await env.store.deleteAll()
            tracks = []
            await rescan()
        } catch {
            errorMessage = LocalMusicError.wrap(error).message
        }
    }

    func upsert(_ record: TrackRecord) async {
        do {
            try await env.store.upsert([record])
            if let i = tracks.firstIndex(where: { $0.id == record.id || $0.fileURL == record.fileURL }) {
                tracks[i] = record
            } else {
                tracks.insert(record, at: 0)
            }
        } catch {
            errorMessage = LocalMusicError.wrap(error).message
        }
    }

    // MARK: Queries

    func tracks(for scope: SidebarItem) -> [TrackRecord] {
        var result = tracks
        switch scope {
        case .recentlyAdded: result = result.filter(\.isRecentlyAdded)
        case .favorites: result = result.filter(\.isFavorite)
        default: break
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { t in
                t.title.localizedCaseInsensitiveContains(query)
                    || t.displayArtist.localizedCaseInsensitiveContains(query)
                    || t.displayAlbum.localizedCaseInsensitiveContains(query)
                    || (t.genre?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return result.sorted(using: sortOrder)
    }

    // MARK: Actions

    func recordPlay(_ track: TrackRecord) async {
        try? await env.store.recordPlay(id: track.id)
        if let i = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[i].playCount += 1
            tracks[i].lastPlayedAt = Date()
        }
    }

    func toggleFavorite(_ track: TrackRecord) async {
        let newValue = !track.isFavorite
        try? await env.store.setFavorite(id: track.id, newValue)
        if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i].isFavorite = newValue }
    }

    func reveal(_ track: TrackRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([track.fileURL])
    }

    func copySourceURL(_ track: TrackRecord) {
        guard let url = track.sourceURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Writes edited tags into the file, moves it if its organized path changed, and updates the index.
    func save(tags: TrackTags, for track: TrackRecord) async throws {
        let normalized = tags.normalized
        guard PathGuard(root: env.settings.musicDirectory).contains(track.fileURL) else {
            throw LocalMusicError(kind: .pathEscapesLibrary, message: "This file is outside the music folder.")
        }
        let wasPlaying = env.playback.currentTrack?.id == track.id
        if wasPlaying { env.playback.stop() }
        try await env.tagWriter.write(normalized, to: track.fileURL)

        var record = track
        normalized.apply(to: &record)
        switch normalized.artwork {
        case .replace(let data): record.artworkFileName = try? env.artwork.store(data)
        case .remove: record.artworkFileName = nil
        case .keep: break
        }
        if env.settings.autoOrganize {
            let organizer = FileOrganizer(root: env.settings.musicDirectory, folderTemplate: env.settings.folderTemplate, filenameTemplate: env.settings.filenameTemplate)
            let target = organizer.destinationURL(for: normalized.organizeMetadata, fileExtension: track.fileURL.pathExtension)
            if target.standardizedFileURL != track.fileURL.standardizedFileURL {
                let source = track.fileURL
                let moved = try await Task.detached { try organizer.move(source, to: target) }.value
                organizer.pruneEmptyDirectories(from: source)
                record.fileURL = moved
            }
        }
        record.fileSize = (try? record.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? record.fileSize
        await upsert(record)
        Log.info("saved tags for \(record.title)", .metadata)
    }

    /// Applies a MusicBrainz candidate: tags, cover art when available, then the normal save path.
    func apply(candidate: ScoredCandidate, to track: TrackRecord) async throws {
        var tags = candidate.tags(over: TrackTags(record: track))
        if env.settings.replaceThumbnailsWithAlbumArt,
           let art = await env.coverArt.frontCover(releaseID: candidate.release?.id, releaseGroupID: candidate.release?.releaseGroupID) {
            tags.artwork = .replace(art)
        }
        tags.comment = track.sourceURL
        try await save(tags: tags, for: track)
    }

    /// Runs the MusicBrainz stage for an existing track and returns the ranked candidates.
    func reidentify(_ track: TrackRecord) async -> RecordingIdentifier.Outcome {
        var seed = TrackTags(record: track)
        let parsed = TitleCleaner.parse(track.title, uploader: track.artist)
        if parsed.artist != nil, seed.artist == nil { seed.artist = parsed.artist }
        seed.title = parsed.title
        return await env.identifier.identify(tags: seed, duration: track.duration, file: track.fileURL, options: env.identifierOptions)
    }

    /// Moves files to the Trash (never a hard delete) and removes the index rows.
    func delete(_ selected: [TrackRecord]) async {
        let root = env.settings.musicDirectory
        let guardian = PathGuard(root: root)
        var removedIDs: [UUID] = []
        for track in selected {
            if env.playback.currentTrack?.id == track.id { env.playback.stop() }
            do {
                let url = try guardian.validated(track.fileURL)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                FileOrganizer(root: root).pruneEmptyDirectories(from: url)
                removedIDs.append(track.id)
                Log.info("trashed \(url.lastPathComponent)", .library)
            } catch {
                errorMessage = LocalMusicError.wrap(error, message: "Could not delete “\(track.title)”.").message
            }
        }
        try? await env.store.delete(ids: removedIDs)
        tracks.removeAll { removedIDs.contains($0.id) }
    }
}
