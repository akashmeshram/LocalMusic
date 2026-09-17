import Foundation
import AppKit
import LocalMusicCore

/// End-to-end scenarios that drive the real app (view models, services, files, playback) inside
/// a throwaway `--profile`. Launched with `--e2e=all` or `--e2e=name,name`; results are written as
/// JSON to `--e2e-report=<path>` and the process exits non-zero on any failure.
@MainActor
final class E2ERunner {
    struct Result: Codable {
        let scenario: String
        let passed: Bool
        let message: String
        let seconds: Double
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    let env: AppEnvironment
    private var results: [Result] = []

    init(env: AppEnvironment) {
        self.env = env
    }

    static let all: [String] = [
        "download-single", "download-fail", "download-playlist", "duplicate-policies", "playback",
        "now-playing-artwork", "tag-edit", "playlists", "rebuild", "views", "identify-network",
    ]

    func run(_ names: [String]) async -> Bool {
        let list = names == ["all"] ? Self.all : names
        setvbuf(stdout, nil, _IONBF, 0) // a crash must not swallow the lines printed before it
        // Mock scenarios must be offline and deterministic; the network scenario calls the identifier directly.
        env.settings.autoQueryMusicBrainz = false
        Log.info("E2E start: \(list.joined(separator: ", "))", .app)
        for name in list {
            let t0 = Date()
            Log.info("E2E scenario: \(name)", .app)
            print("RUN  \(name)")
            do {
                try await scenario(name)
                results.append(Result(scenario: name, passed: true, message: "ok", seconds: Date().timeIntervalSince(t0)))
                print("PASS \(name)")
            } catch {
                results.append(Result(scenario: name, passed: false, message: "\(error)", seconds: Date().timeIntervalSince(t0)))
                print("FAIL \(name): \(error)")
            }
        }
        if let path = LaunchOptions.values(for: "--e2e-report").first,
           let data = try? JSONEncoder().encode(results) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        let failed = results.filter { !$0.passed }.count
        print("E2E: \(results.count - failed)/\(results.count) passed")
        return failed == 0
    }

    // MARK: Scenarios

    private func scenario(_ name: String) async throws {
        switch name {
        case "download-single":
            let before = env.library.tracks.count
            let job = try await download("https://example.com/watch?v=e2e-single")
            try expect(job.state == .complete, "job state \(job.state)")
            guard let file = job.resultFileURL else { throw Failure("no result file") }
            try expect(FileManager.default.fileExists(atPath: file.path), "file missing: \(file.path)")
            try expect(PathGuard(root: env.settings.musicDirectory).contains(file), "file outside library")
            try expect(file.path.contains("/Mock Artist/2024 - Mock Album/"), "not organized: \(file.path)")
            try expect(env.library.tracks.count == before + 1, "library count \(env.library.tracks.count) != \(before + 1)")
            try expect(incomingIsEmpty(), "incoming folder not cleaned")

        case "download-fail":
            let before = env.library.tracks.count
            let job = try await download("https://example.com/watch?v=fail-me")
            try expect(job.state == .failed, "expected failed, got \(job.state)")
            try expect(job.error?.kind == .videoUnavailable, "error kind \(String(describing: job.error?.kind))")
            try expect(!job.technicalLog.isEmpty, "technical log empty")
            try expect(env.library.tracks.count == before, "failed job changed the library")
            try expect(incomingIsEmpty(), "incoming folder not cleaned after failure")

        case "download-playlist":
            let before = env.library.tracks.count
            await env.downloads.submit("https://example.com/playlist?list=e2e")
            guard let playlist = env.downloads.pendingPlaylist else { throw Failure("no playlist preview") }
            try expect(playlist.entries.count == 5, "expected 5 entries, got \(playlist.entries.count)")
            env.downloads.pendingPlaylist = nil
            let chosen = Array(playlist.entries.dropLast()) // deselect one
            env.downloads.enqueue(chosen, playlist: playlist)
            try await waitUntil(60) { self.env.downloads.unfinishedCount == 0 }
            let done = env.downloads.jobs.filter { $0.playlistTitle == playlist.title }
            try expect(done.count == 4 && done.allSatisfy { $0.state == .complete }, "playlist jobs: \(done.map(\.state.label))")
            try expect(env.library.tracks.count == before + 4, "library count \(env.library.tracks.count) != \(before + 4)")
            // ≥ 3 finished jobs → notification path (requestAuthorization callback) has run by now.
            try await Task.sleep(for: .milliseconds(500))

        case "duplicate-policies":
            let url = "https://example.com/watch?v=e2e-single"
            env.settings.duplicatePolicy = .replace
            let before = env.library.tracks.count
            print("  step: replace policy")
            let replaced = try await download(url)
            try expect(replaced.state == .complete, "replace job \(replaced.state)")
            try expect(env.library.tracks.count == before, "replace changed count to \(env.library.tracks.count)")
            env.settings.duplicatePolicy = .skip
            print("  step: skip policy")
            let skipped = try await download(url)
            try expect(skipped.state == .cancelled && (skipped.note ?? "").contains("Skipped"), "skip: \(skipped.state) \(skipped.note ?? "")")
            env.settings.duplicatePolicy = .ask
            print("  step: ask policy")
            let id = try await submitOnly(url)
            try await waitUntil(30) { self.env.downloads.jobs.first { $0.id == id }?.pendingDuplicate != nil }
            env.downloads.resolveDuplicate(id, .keepBoth)
            try await waitUntil(60) { self.env.downloads.jobs.first { $0.id == id }?.state.isTerminal == true }
            let kept = env.downloads.jobs.first { $0.id == id }!
            try expect(kept.state == .complete, "keep-both \(kept.state)")
            try expect(env.library.tracks.count == before + 1, "keep-both count \(env.library.tracks.count)")
            env.settings.duplicatePolicy = .ask

        case "playback":
            let tracks = env.library.tracks.sorted { $0.title < $1.title }
            try expect(tracks.count >= 2, "need ≥2 tracks")
            env.playback.volume = 0
            env.playback.play(tracks, startingAt: 0)
            try expect(env.playback.isPlaying, "not playing")
            try await Task.sleep(for: .milliseconds(1200))
            try expect(env.playback.currentTime > 0.4, "time did not advance: \(env.playback.currentTime)")
            env.playback.next()
            try expect(env.playback.currentTrack?.id == tracks[1].id, "next did not advance")
            env.playback.previous()
            try expect(env.playback.currentTrack?.id == tracks[0].id, "previous did not go back")
            env.playback.seek(to: 1)
            try await Task.sleep(for: .milliseconds(400))
            try expect(abs(env.playback.currentTime - 1) < 0.5, "seek off: \(env.playback.currentTime)")
            env.playback.pause()
            try expect(!env.playback.isPlaying, "pause failed")
            env.playback.toggleShuffle(); env.playback.cycleRepeat()
            env.playback.stop()
            try expect(env.playback.currentTrack == nil, "stop failed")

        case "now-playing-artwork":
            guard var track = env.library.tracks.first else { throw Failure("no tracks") }
            let png = solidPNG()
            track.artworkFileName = try env.artwork.store(png)
            await env.library.upsert(track)
            env.playback.volume = 0
            env.playback.play(track)
            try await Task.sleep(for: .milliseconds(600))
            env.playback.seek(to: 0.5)
            try await Task.sleep(for: .milliseconds(400))
            env.playback.stop()

        case "tag-edit":
            guard let track = env.library.tracks.first else { throw Failure("no tracks") }
            guard env.tagWriter.canWrite(fileExtension: track.fileURL.pathExtension) else {
                print("  (skipped: cannot tag .\(track.fileURL.pathExtension) without ffmpeg)"); return
            }
            var tags = TrackTags(record: track)
            tags.title = "E2E Edited Title"; tags.artist = "E2E Artist"; tags.albumArtist = "E2E Artist"; tags.album = "E2E Album"; tags.year = 2001; tags.trackNumber = 3
            tags.artwork = .replace(solidPNG())
            try await env.library.save(tags: tags, for: track)
            guard let updated = env.library.trackByID[track.id] else { throw Failure("record vanished") }
            try expect(updated.title == "E2E Edited Title" && updated.album == "E2E Album", "record not updated")
            try expect(updated.fileURL.path.hasSuffix("E2E Artist/2001 - E2E Album/03 - E2E Edited Title.\(track.fileURL.pathExtension)"), "not reorganized: \(updated.fileURL.path)")
            try expect(FileManager.default.fileExists(atPath: updated.fileURL.path), "moved file missing")
            try expect(!FileManager.default.fileExists(atPath: track.fileURL.path), "old file still present")

        case "playlists":
            let ids = env.library.tracks.prefix(3).map(\.id)
            try expect(ids.count == 3, "need 3 tracks")
            let p = await env.library.createPlaylist(name: "E2E Mix", trackIDs: Array(ids.prefix(2)))
            await env.library.addTracks([ids[2]], toPlaylist: p.id)
            await env.library.movePlaylistItems(p.id, from: IndexSet(integer: 2), to: 0)
            try expect(env.library.playlist(id: p.id)?.trackIDs == [ids[2], ids[0], ids[1]], "reorder wrong: \(env.library.playlist(id: p.id)?.trackIDs ?? [])")
            await env.library.renamePlaylist(p.id, to: "E2E Mix Renamed")
            let file = env.settings.musicDirectory.appendingPathComponent("e2e.m3u8")
            try env.library.exportPlaylist(p.id, to: file)
            let (imported, unmatched) = try await env.library.importPlaylist(from: file)
            try expect(unmatched == 0 && imported.trackIDs == [ids[2], ids[0], ids[1]], "import mismatch (unmatched \(unmatched))")
            await env.library.removeFromPlaylist(p.id, offsets: IndexSet(integer: 0))
            try expect(env.library.playlist(id: p.id)?.trackIDs.count == 2, "remove failed")
            await env.library.deletePlaylist(imported.id)
            try expect(env.library.playlists.contains { $0.id == p.id } && !env.library.playlists.contains { $0.id == imported.id }, "delete failed")
            try? FileManager.default.removeItem(at: file)

        case "rebuild":
            let before = env.library.tracks.count
            let favorite = env.library.tracks.first!
            await env.library.toggleFavorite(favorite)
            await env.library.rebuild()
            try expect(env.library.tracks.count == before, "rebuild count \(env.library.tracks.count) != \(before)")
            try expect(env.library.tracks.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) }, "rebuilt index references missing files")
            let favPath = favorite.fileURL.resolvingSymlinksInPath().path
            try expect(env.library.tracks.contains { $0.fileURL.resolvingSymlinksInPath().path == favPath && $0.isFavorite }, "favorite lost on rebuild")
            try expect(env.library.tracks.allSatisfy { $0.sourceURL != nil } || env.tools[.ffmpeg]?.isUsable != true, "source URLs not recovered from tags")

        case "views":
            let items: [SidebarItem] = [.songs, .albums, .artists, .recentlyAdded, .favorites, .downloads] + env.library.playlists.prefix(1).map({ .playlist($0.id) })
            for item in items {
                env.selectedSidebar = item
                try await Task.sleep(for: .milliseconds(250))
            }
            if !env.library.tracks.isEmpty {
                env.library.searchText = "Mock"
                try await Task.sleep(for: .milliseconds(150))
                try expect(!env.library.tracks(for: .songs).isEmpty, "search returned nothing")
            }
            env.library.searchText = ""
            env.selectedSidebar = .songs

        case "identify-network":
            guard LaunchOptions.values(for: "--e2e-network").first == "1" else { print("  (skipped: pass --e2e-network=1)"); return }
            let outcome = await env.identifier.identify(tags: TrackTags(title: "Jóga", artist: "Björk"), duration: 305, file: nil, options: env.identifierOptions)
            if let error = outcome.error { throw Failure("MusicBrainz: \(error.message)") }
            try expect(outcome.accepted?.release?.title == "Homogenic", "expected Homogenic, got \(outcome.accepted?.summary ?? "nothing")")
            let art = await env.coverArt.frontCover(releaseID: outcome.accepted?.release?.id, releaseGroupID: outcome.accepted?.release?.releaseGroupID)
            try expect((art?.count ?? 0) > 10_000, "no cover art")

        default:
            throw Failure("unknown scenario")
        }
    }

    // MARK: Helpers

    /// Submits without waiting for completion (used when the job is expected to pause on a decision).
    private func submitOnly(_ url: String) async throws -> UUID {
        let before = Set(env.downloads.jobs.map(\.id))
        Task { await env.downloads.submit(url) }
        try await waitUntil(10) { self.env.downloads.jobs.contains { !before.contains($0.id) } }
        return env.downloads.jobs.first { !before.contains($0.id) }!.id
    }

    private func download(_ url: String) async throws -> DownloadJob {
        let before = Set(env.downloads.jobs.map(\.id))
        await env.downloads.submit(url)
        if let e = env.downloads.submissionError { throw Failure("submission: \(e.message)") }
        guard let id = env.downloads.jobs.first(where: { !before.contains($0.id) })?.id else { throw Failure("job not queued") }
        try await waitUntil(90) { self.env.downloads.jobs.first { $0.id == id }?.state.isTerminal == true }
        return env.downloads.jobs.first { $0.id == id }!
    }

    private func waitUntil(_ seconds: Double, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw Failure("timed out after \(Int(seconds))s") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func expect(_ ok: Bool, _ message: @autoclosure () -> String) throws {
        if !ok { throw Failure(message()) }
    }

    private func incomingIsEmpty() -> Bool {
        let dir = AppPaths.incomingDirectory(musicRoot: env.settings.musicDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }

    private func solidPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPurple.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
