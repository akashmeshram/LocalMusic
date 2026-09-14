import Foundation
import Observation
import AppKit
import LocalMusicCore

@MainActor
@Observable
final class LibraryViewModel {
    private(set) var tracks: [TrackRecord] = []
    private(set) var playlists: [PlaylistRecord] = []
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
            playlists = try await env.store.playlists()
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

    // MARK: Grouping

    struct AlbumGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let year: Int?
        let tracks: [TrackRecord]
        var artworkFileName: String? { tracks.first { $0.artworkFileName != nil }?.artworkFileName }
        var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
        var isSingles: Bool { title == FileOrganizer.singlesFolder }
    }

    struct ArtistGroup: Identifiable, Hashable {
        let id: String
        let name: String
        let albums: [AlbumGroup]
        var tracks: [TrackRecord] { albums.flatMap(\.tracks) }
        var artworkFileName: String? { albums.first { $0.artworkFileName != nil }?.artworkFileName }
    }

    static func albumKey(_ t: TrackRecord) -> (artist: String, album: String) {
        (t.albumArtist ?? t.artist ?? FileOrganizer.unknownArtist, t.album ?? FileOrganizer.singlesFolder)
    }

    /// Albums grouped by (album artist, album); tracks without an album form a per-artist "Singles" group.
    var albums: [AlbumGroup] { makeAlbums(matching: searchText) }

    var artists: [ArtistGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var byArtist: [String: [AlbumGroup]] = [:]
        for album in makeAlbums(matching: "") {
            byArtist[album.artist.lowercased(), default: []].append(album)
        }
        return byArtist.values.map { list in ArtistGroup(id: list[0].artist.lowercased(), name: list[0].artist, albums: list) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func makeAlbums(matching search: String) -> [AlbumGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var groups: [String: [TrackRecord]] = [:]
        for t in tracks {
            let k = Self.albumKey(t)
            groups[k.artist.lowercased() + "\u{1F}" + k.album.lowercased(), default: []].append(t)
        }
        return groups.map { key, list -> AlbumGroup in
            let k = Self.albumKey(list[0])
            let sorted = list.sorted { a, b in
                if (a.discNumber ?? 1) != (b.discNumber ?? 1) { return (a.discNumber ?? 1) < (b.discNumber ?? 1) }
                if (a.trackNumber ?? 999) != (b.trackNumber ?? 999) { return (a.trackNumber ?? 999) < (b.trackNumber ?? 999) }
                return a.title.caseInsensitiveCompare(b.title) == .orderedAscending
            }
            return AlbumGroup(id: key, title: k.album, artist: k.artist, year: sorted.compactMap(\.year).min(), tracks: sorted)
        }
        .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
        .sorted { a, b in
            let artistOrder = a.artist.caseInsensitiveCompare(b.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            if a.isSingles != b.isSingles { return !a.isSingles }
            if (a.year ?? 0) != (b.year ?? 0) { return (a.year ?? 0) < (b.year ?? 0) }
            return a.title.caseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: Playlists

    func playlist(id: UUID) -> PlaylistRecord? { playlists.first { $0.id == id } }

    func tracks(inPlaylist id: UUID) -> [TrackRecord] {
        guard let p = playlist(id: id) else { return [] }
        let byID = trackByID
        return p.trackIDs.compactMap { byID[$0] }
    }

    @discardableResult
    func createPlaylist(name: String = "New Playlist", trackIDs: [UUID] = []) async -> PlaylistRecord {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "New Playlist" : name
        var unique = base
        var n = 2
        while playlists.contains(where: { $0.name == unique }) { unique = "\(base) \(n)"; n += 1 }
        let p = PlaylistRecord(name: unique, sortIndex: (playlists.map(\.sortIndex).max() ?? -1) + 1, trackIDs: trackIDs)
        playlists.append(p)
        try? await env.store.savePlaylist(p)
        Log.info("created playlist “\(unique)”", .library)
        return p
    }

    func renamePlaylist(_ id: UUID, to name: String) async {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        playlists[i].name = trimmed
        try? await env.store.savePlaylist(playlists[i])
    }

    func deletePlaylist(_ id: UUID) async {
        playlists.removeAll { $0.id == id }
        try? await env.store.deletePlaylist(id: id)
    }

    func addTracks(_ ids: [UUID], toPlaylist playlistID: UUID) async {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs += ids
        try? await env.store.savePlaylist(playlists[i])
    }

    func removeFromPlaylist(_ playlistID: UUID, offsets: IndexSet) async {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets)
        try? await env.store.savePlaylist(playlists[i])
    }

    func movePlaylistItems(_ playlistID: UUID, from source: IndexSet, to destination: Int) async {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.move(fromOffsets: source, toOffset: destination)
        try? await env.store.savePlaylist(playlists[i])
    }

    func exportPlaylist(_ id: UUID, to url: URL) throws {
        guard let p = playlist(id: id) else { return }
        try PlaylistFile.export(tracks(inPlaylist: id), name: p.name, to: url)
    }

    /// Returns the number of entries that could not be matched to library tracks.
    func importPlaylist(from url: URL) async throws -> (PlaylistRecord, unmatched: Int) {
        let result = try PlaylistFile.importPlaylist(from: url, library: tracks)
        let p = await createPlaylist(name: result.name, trackIDs: result.matched.map(\.id))
        return (p, result.unmatchedPaths.count)
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
