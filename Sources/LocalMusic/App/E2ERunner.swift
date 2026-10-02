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
        "now-playing-artwork", "tag-edit", "playlists", "rebuild", "views", "mix", "mix-fail", "video", "identify-network", "mix-live",
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

        case "mix":
            guard env.ffmpegReady else { throw Failure("ffmpeg not available; mixes need it") }
            let before = env.library.tracks.count
            let links = "https://example.com/watch?v=mix-a\nhttps://example.com/watch?v=mix-b, https://example.com/watch?v=mix-c"
            try expect(env.downloads.submitMix(name: "E2E Mix: One/Two", links: links, crossfade: 3), "submit rejected: \(env.downloads.submissionError?.message ?? "?")")
            guard let mixID = env.downloads.mixes.last?.id else { throw Failure("mix not queued") }
            try await waitUntil(120) { self.env.downloads.mixes.first { $0.id == mixID }?.state.isTerminal == true }
            let mix = env.downloads.mixes.first { $0.id == mixID }!
            try expect(mix.state == .complete, "mix state \(mix.state): \(mix.error?.message ?? "") \(mix.technicalLog.suffix(400))")
            try expect(mix.items.allSatisfy { $0.state == .complete }, "items: \(mix.items.map(\.state.label))")
            guard let file = mix.resultFileURL else { throw Failure("no result file") }
            try expect(file.pathExtension == "mp3", "not mp3: \(file.lastPathComponent)")
            try expect(FileManager.default.fileExists(atPath: file.path), "file missing: \(file.path)")
            try expect(PathGuard(root: env.settings.musicDirectory).contains(file), "file outside library")
            try expect(file.path.contains("/Mock Artist/Mixes/"), "not filed under Mixes: \(file.path)")
            try expect(env.library.tracks.count == before + 1, "library count \(env.library.tracks.count) != \(before + 1)")
            guard let track = env.library.trackByID[mix.resultTrackID ?? UUID()] else { throw Failure("mix not indexed") }
            try expect(track.album == DownloadManager.mixAlbum && track.artist == "Mock Artist", "tags \(track.artist ?? "-") / \(track.album ?? "-")")
            // Three 3 s clips with two 1.5 s overlaps (half of the shortest neighbour) → 6 s.
            let probed = try await AudioMetadataReader.read(file)
            try expect(abs(probed.duration - 6) < 0.4, "duration \(probed.duration) ≠ 6")
            try expect(abs(track.duration - 6) < 0.01, "indexed duration \(track.duration)")
            let frames = ID3TagWriter.parse(try Data(contentsOf: file)).frames
            let chapters = ID3TagWriter.chapters(in: frames)
            try expect(chapters.count == 3, "chapters \(chapters.count)")
            try expect(chapters[1].start == 1.5 && chapters[2].start == 3, "chapter starts \(chapters.map(\.start))")
            try expect(frames.contains { $0.id == "CTOC" }, "no CTOC")
            try expect(probed.title == "E2E Mix: One/Two", "title \(probed.title ?? "-")")
            try expect(incomingIsEmpty(), "incoming folder not cleaned")
            // Plays like any other track.
            env.playback.play(track)
            try await waitUntil(10) { self.env.playback.isPlaying }
            env.playback.pause()

        case "mix-fail":
            let before = env.library.tracks.count
            try expect(!env.downloads.submitMix(name: "", links: "https://example.com/a\nhttps://example.com/b", crossfade: 1), "empty name accepted")
            try expect(!env.downloads.submitMix(name: "x", links: "https://example.com/a", crossfade: 1), "single link accepted")
            try expect(!env.downloads.submitMix(name: "x", links: "https://example.com/a\nnot a url", crossfade: 1), "bad link accepted")
            env.downloads.submissionError = nil
            try expect(env.downloads.submitMix(name: "Broken Mix", links: "https://example.com/watch?v=ok-1\nhttps://example.com/watch?v=fail-2\nhttps://example.com/watch?v=ok-3", crossfade: 0), "submit rejected")
            guard let mixID = env.downloads.mixes.last?.id else { throw Failure("mix not queued") }
            try await waitUntil(120) { self.env.downloads.mixes.first { $0.id == mixID }?.state.isTerminal == true }
            let mix = env.downloads.mixes.first { $0.id == mixID }!
            try expect(mix.state == .failed, "expected failed, got \(mix.state)")
            try expect((mix.error?.message ?? "").contains("Song 2"), "error should name song 2: \(mix.error?.message ?? "-")")
            try expect(mix.items[1].state == .failed, "item 2 state \(mix.items[1].state)")
            try expect(env.library.tracks.count == before, "failed mix changed the library")
            try expect(incomingIsEmpty(), "incoming folder not cleaned after failure")
            // Cancelling mid-download leaves nothing behind either.
            try expect(env.downloads.submitMix(name: "Cancelled Mix", links: "https://example.com/watch?v=c-1\nhttps://example.com/watch?v=c-2", crossfade: 0), "submit rejected")
            let cancelID = env.downloads.mixes.last!.id
            try await waitUntil(10) { self.env.downloads.mixes.first { $0.id == cancelID }?.state == .downloading }
            env.downloads.cancel(cancelID)
            try await waitUntil(30) { self.env.downloads.mixes.first { $0.id == cancelID }?.state.isTerminal == true }
            try expect(env.downloads.mixes.first { $0.id == cancelID }?.state == .cancelled, "cancel state")
            try expect(env.library.tracks.count == before, "cancelled mix changed the library")
            try expect(incomingIsEmpty(), "incoming folder not cleaned after cancel")

        case "video":
            guard env.ffmpegReady, let ffprobe = env.tools[.ffprobe]?.path else { throw Failure("ffmpeg/ffprobe not available; video export needs them") }
            // A mix gives us chapters to check in the description file.
            try expect(env.downloads.submitMix(name: "E2E Video Mix", links: "https://example.com/watch?v=v-a\nhttps://example.com/watch?v=v-b", crossfade: 0), "mix submit rejected")
            guard let mixID = env.downloads.mixes.last?.id else { throw Failure("mix not queued") }
            try await waitUntil(120) { self.env.downloads.mixes.first { $0.id == mixID }?.state.isTerminal == true }
            guard let mix = env.downloads.mixes.first(where: { $0.id == mixID }), mix.state == .complete,
                  let track = env.library.trackByID[mix.resultTrackID ?? UUID()] else { throw Failure("mix did not complete") }

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-e2e-video-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let photo = dir.appendingPathComponent("photo.png")
            try solidPNG().write(to: photo)
            let out = dir.appendingPathComponent("E2E Video.mp4")

            // Rejections: output inside the music library, unreadable image.
            try expect(!env.downloads.submitVideoExport(track: track, image: photo, output: env.settings.musicDirectory.appendingPathComponent("x.mp4")), "accepted output inside the library")
            try expect(!env.downloads.submitVideoExport(track: track, image: dir.appendingPathComponent("missing.png"), output: out), "accepted missing image")
            env.downloads.submissionError = nil

            try expect(env.downloads.submitVideoExport(track: track, image: photo, output: out), "submit rejected: \(env.downloads.submissionError?.message ?? "?")")
            guard let videoID = env.downloads.videos.last?.id else { throw Failure("video not queued") }
            try await waitUntil(90) { self.env.downloads.videos.first { $0.id == videoID }?.state.isTerminal == true }
            let job = env.downloads.videos.first { $0.id == videoID }!
            try expect(job.state == .complete, "video state \(job.state): \(job.error?.message ?? "") \(job.technicalLog.suffix(400))")
            try expect(FileManager.default.fileExists(atPath: out.path), "mp4 missing")
            let text = try String(contentsOf: job.descriptionURL, encoding: .utf8)
            try expect(text.hasPrefix("E2E Video Mix\nMock Artist\n"), "description header: \(text.prefix(60))")
            try expect(text.contains("0:00 ") && text.contains("0:03 "), "chapter timestamps missing: \(text)")
            try expect(text.contains("https://example.com/watch?v=v-a") && text.contains("https://example.com/watch?v=v-b"), "sources missing: \(text)")
            let probe = try await ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", out.path])
            let json = (try? JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any]) ?? [:]
            let streams = json["streams"] as? [[String: Any]] ?? []
            let video = streams.first { $0["codec_type"] as? String == "video" } ?? [:]
            let audio = streams.first { $0["codec_type"] as? String == "audio" } ?? [:]
            try expect(video["codec_name"] as? String == "h264" && video["width"] as? Int == 1920 && video["height"] as? Int == 1080, "video stream \(video)")
            try expect(audio["codec_name"] as? String == "aac", "audio stream \(audio)")
            let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
            try expect(abs(duration - 6) < 0.5, "duration \(duration) ≠ 6")
            try expect(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("LocalMusic-video-\(videoID.uuidString)").path), "temp dir not cleaned")

            // A corrupt image fails cleanly and leaves no file behind.
            let bad = dir.appendingPathComponent("bad.png")
            try Data("not an image".utf8).write(to: bad)
            let badOut = dir.appendingPathComponent("Bad.mp4")
            try expect(env.downloads.submitVideoExport(track: track, image: bad, output: badOut), "corrupt image rejected at submit (should fail in the job)")
            let badID = env.downloads.videos.last!.id
            try await waitUntil(60) { self.env.downloads.videos.first { $0.id == badID }?.state.isTerminal == true }
            try expect(env.downloads.videos.first { $0.id == badID }?.state == .failed, "corrupt image did not fail")
            try expect(!FileManager.default.fileExists(atPath: badOut.path), "partial output left behind")

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

        case "mix-live":
            // Real downloads (run without --mock): three sources from different artists → collage cover.
            guard LaunchOptions.values(for: "--e2e-network").first == "1" else { print("  (skipped: pass --e2e-network=1)"); return }
            guard !env.useMockDownloader else { print("  (skipped: needs the real downloader, run without --mock)"); return }
            env.settings.autoQueryMusicBrainz = true
            defer { env.settings.autoQueryMusicBrainz = false }
            env.selectedSidebar = .downloads
            let links = ["https://www.youtube.com/watch?v=sMcWOaJFuw0", "https://archive.org/details/testmp3testfile", "https://www.youtube.com/watch?v=SgJ8dyD01I8"]
            try expect(env.downloads.submitMix(name: "Live Mix", links: links.joined(separator: "\n"), crossfade: 4), "submit rejected: \(env.downloads.submissionError?.message ?? "?")")
            let mixID = env.downloads.mixes.last!.id
            try await waitUntil(600) { self.env.downloads.mixes.first { $0.id == mixID }?.state.isTerminal == true }
            let mix = env.downloads.mixes.first { $0.id == mixID }!
            print(mix.technicalLog.split(separator: "\n").filter { $0.contains("[LocalMusic]") || $0.contains("MusicBrainz") }.joined(separator: "\n"))
            try expect(mix.state == .complete, "mix state \(mix.state): \(mix.error?.message ?? "")")
            guard let file = mix.resultFileURL, let track = env.library.trackByID[mix.resultTrackID ?? UUID()] else { throw Failure("no result") }
            let probed = try await AudioMetadataReader.read(file)
            let chapters = ID3TagWriter.chapters(in: ID3TagWriter.parse(try Data(contentsOf: file)).frames)
            print("  file: \(file.path)\n  artist: \(track.artist ?? "-")  duration: \(Int(probed.duration))s  chapters: \(chapters.map { "\($0.title)@\(Int($0.start))s" })")
            try expect(chapters.count == 3, "chapters \(chapters.count)")
            try expect(track.artist == DownloadManager.variousArtists, "artist \(track.artist ?? "-")")
            guard let art = probed.artwork, let dims = ImageInfo.dimensions(of: art) else { throw Failure("no embedded artwork") }
            print("  artwork: \(dims.0)x\(dims.1), \(art.count) bytes")
            try expect(dims.0 == ArtworkCollage.side, "expected a rendered collage, got \(dims)")
            if let dir = LaunchOptions.screenshotDirectory { try? art.write(to: dir.appendingPathComponent("mix-cover.jpg")) }

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
