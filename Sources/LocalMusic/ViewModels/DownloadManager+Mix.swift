import Foundation
import LocalMusicCore

/// The mix pipeline: fetch every song → identify each one → join with ffmpeg → tag with
/// chapters and a composite cover → organize → index. Only the mix reaches the library.
extension DownloadManager {
    static let mixAlbum = "Mixes"
    static let variousArtists = "Various Artists"

    struct MixSource: Sendable {
        var index: Int
        var fileURL: URL
        var duration: TimeInterval
        var tags: TrackTags
        var artwork: Data?
    }

    /// Parses one link per line (commas and whitespace also separate), validates each, and
    /// queues the mix. Returns `false` and sets `submissionError` when the input is unusable.
    @discardableResult
    func submitMix(name: String, links: String, crossfade: TimeInterval) -> Bool {
        submissionError = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            submissionError = LocalMusicError(kind: .malformedURL, message: "Give the mix a name.")
            return false
        }
        let pieces = links.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " || $0 == "\t" }).map(String.init)
        var urls: [URL] = []
        for piece in pieces {
            guard let url = URLValidator.normalize(piece) else {
                submissionError = LocalMusicError(kind: .malformedURL, message: "“\(piece)” is not a valid http(s) link.")
                return false
            }
            if !urls.contains(url) { urls.append(url) }
        }
        guard urls.count >= 2 else {
            submissionError = LocalMusicError(kind: .malformedURL, message: "A mix needs at least two different links.")
            return false
        }
        guard env.ytdlpReady else {
            submissionError = LocalMusicError(kind: .toolMissing, message: "yt-dlp is not installed. Run: brew install yt-dlp ffmpeg")
            return false
        }
        guard env.ffmpegReady else {
            submissionError = LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to build mixes. Run: brew install ffmpeg")
            return false
        }
        let mix = MixJob(name: trimmedName, urls: urls, crossfade: max(0, min(crossfade, 12)))
        appendMix(mix)
        Log.info("queued mix “\(trimmedName)” with \(urls.count) songs, crossfade \(mix.crossfade)s", .download)
        if env.settings.autoStartDownloads { pump() }
        return true
    }

    func startMix(_ id: UUID) {
        guard mixTasks[id] == nil else { return }
        mixTasks[id] = Task { [weak self] in
            await self?.runMix(id)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.taskFinished(id, state: self.mixes.first { $0.id == id }?.state ?? .failed)
            }
        }
    }

    private func log(_ id: UUID, _ line: String) {
        updateMix(id) { if $0.technicalLog.utf8.count < 200_000 { $0.technicalLog += line + "\n" } }
    }

    private func updateItem(_ id: UUID, _ index: Int, _ body: (inout MixItem) -> Void) {
        updateMix(id) { mix in if mix.items.indices.contains(index) { body(&mix.items[index]) } }
    }

    // MARK: Pipeline

    private func runMix(_ id: UUID) async {
        guard let mix = mixes.first(where: { $0.id == id }) else { return }
        let root = env.settings.musicDirectory
        let jobDir = AppPaths.incomingDirectory(musicRoot: root).appendingPathComponent("mix-\(id.uuidString)", isDirectory: true)

        do {
            try Task.checkCancellation()
            guard let downloader = env.makeDownloader() else {
                throw LocalMusicError(kind: .toolMissing, message: "yt-dlp is not installed. Run: brew install yt-dlp ffmpeg")
            }
            guard env.ffmpegReady else {
                throw LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to build mixes. Run: brew install ffmpeg")
            }
            try AppPaths.ensureDirectories(musicRoot: root)
            if let free = AppPaths.availableCapacity(at: root), free < 500 * 1024 * 1024 {
                throw LocalMusicError(kind: .lowDiskSpace, message: "Less than 500 MB free on the music volume.", technicalDetails: "available: \(free) bytes")
            }
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)

            // 1. Fetch + identify every song, a few at a time, keeping the user's order.
            updateMix(id) { $0.state = .downloading; $0.phase = nil }
            let limit = max(1, env.settings.maxConcurrentDownloads)
            var sources: [MixSource] = []
            let items = mix.items
            try await withThrowingTaskGroup(of: MixSource.self) { group in
                var next = 0
                while next < min(limit, items.count) {
                    let index = next; next += 1
                    group.addTask { @Sendable @MainActor [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.fetch(items[index], index: index, mixID: id, into: jobDir, downloader: downloader)
                    }
                }
                while let source = try await group.next() {
                    sources.append(source)
                    if next < items.count {
                        let index = next; next += 1
                        group.addTask { @Sendable @MainActor [weak self] in
                            guard let self else { throw CancellationError() }
                            return try await self.fetch(items[index], index: index, mixID: id, into: jobDir, downloader: downloader)
                        }
                    }
                }
            }
            sources.sort { $0.index < $1.index }
            try Task.checkCancellation()

            // 2. Join with ffmpeg.
            updateMix(id) { $0.state = .processing; $0.phase = "Building mix (\(sources.count) songs)" }
            let inputs = sources.map { MixBuilder.Input(url: $0.fileURL, title: $0.tags.title, duration: $0.duration) }
            let output = jobDir.appendingPathComponent(FilenameSanitizer.sanitize(mix.name, fallback: "Mix") + ".mp3")
            let builder = MixBuilder(ffmpeg: env.ffmpegService.ffmpeg)
            let plan = try await builder.build(inputs, crossfade: mix.crossfade, bitrateKbps: env.settings.mixBitrate, output: output) { [weak self] line in
                Task { @MainActor in self?.log(id, line) }
            }
            log(id, "[LocalMusic] mix built: \(DurationFormatter.string(plan.totalDuration)), overlaps \(plan.overlaps.map { String(format: "%.1fs", $0) }.joined(separator: ", "))")

            // 3. Tags: one artist if every song shares it, otherwise Various Artists.
            let artists = Set(sources.compactMap { $0.tags.artist?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
            let artist = artists.count == 1 ? sources.first { $0.tags.artist != nil }?.tags.artist ?? Self.variousArtists : Self.variousArtists
            let cover = ArtworkCollage.compose(sources.compactMap { s in
                s.artwork.map { ArtworkCollage.Source(albumKey: ArtworkCollage.albumKey(album: s.tags.album, albumArtist: s.tags.albumArtist, artist: s.tags.artist), image: $0) }
            })
            let distinctCovers = ArtworkCollage.distinct(sources.compactMap { s in
                s.artwork.map { ArtworkCollage.Source(albumKey: ArtworkCollage.albumKey(album: s.tags.album, albumArtist: s.tags.albumArtist, artist: s.tags.artist), image: $0) }
            }).count
            log(id, "[LocalMusic] cover: \(distinctCovers == 0 ? "none" : distinctCovers == 1 ? "shared album art" : "collage of \(min(distinctCovers, ArtworkCollage.maxTiles)) covers")")
            var comment = "Mix of \(sources.count) songs\n"
            for (i, s) in sources.enumerated() {
                comment += "\(i + 1). \(s.tags.artist.map { "\($0) – " } ?? "")\(s.tags.title)\n   \(mix.items[s.index].sourceURL.absoluteString)\n"
            }
            var tags = TrackTags(title: mix.name, artist: artist, albumArtist: artist, album: Self.mixAlbum, genre: "Mix",
                                 year: Calendar.current.component(.year, from: Date()), comment: comment,
                                 artwork: cover.map { .replace($0) } ?? .remove)
            tags.chapters = plan.chapters

            // Duplicate check on the mix itself (same name/artist/length already in the library?).
            var replacing: TrackRecord?
            let candidate = DuplicateDetector.Candidate(artist: artist, title: mix.name, duration: plan.totalDuration)
            if let match = DuplicateDetector.matches(for: candidate, in: env.library.tracks).first {
                log(id, "[LocalMusic] possible duplicate of \(match.track.fileURL.lastPathComponent): \(match.summary)")
                switch await askDuplicate(id, match: match) {
                case .skip:
                    try? FileManager.default.removeItem(at: jobDir)
                    updateMix(id) { $0.state = .cancelled; $0.finishedAt = Date(); $0.note = "Skipped — duplicate of “\(match.track.title)”"; $0.resultTrackID = match.track.id }
                    return
                case .keepBoth: break
                case .replace: replacing = match.track
                }
            }
            try Task.checkCancellation()
            try await ID3TagWriter().write(tags, to: output)

            // 4. Organize
            updateMix(id) { $0.state = .organizing; $0.phase = nil }
            if let old = replacing {
                await env.library.delete([old])
                log(id, "[LocalMusic] replaced \(old.fileURL.lastPathComponent)")
            }
            let organizer = FileOrganizer(root: root, folderTemplate: env.settings.folderTemplate, filenameTemplate: env.settings.filenameTemplate)
            let meta = OrganizeMetadata(title: mix.name, artist: artist, albumArtist: artist, album: Self.mixAlbum)
            let placed: URL
            if env.settings.autoOrganize {
                placed = try await Task.detached { try organizer.place(output, as: meta) }.value
            } else {
                let flat = root.appendingPathComponent(output.lastPathComponent)
                placed = try await Task.detached { try organizer.move(output, to: flat) }.value
            }

            // 5. Index
            let artworkName = cover.flatMap { try? env.artwork.store($0) }
            let size = (try? placed.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            var record = TrackRecord(fileURL: placed, sourceURL: nil, extractor: "mix", title: mix.name, duration: plan.totalDuration,
                                     fileFormat: "mp3", fileSize: size, artworkFileName: artworkName, downloadDate: Date())
            tags.apply(to: &record)
            await env.library.upsert(record)
            try? FileManager.default.removeItem(at: jobDir)

            updateMix(id) { mix in
                mix.state = .complete
                mix.finishedAt = Date()
                mix.resultFileURL = placed
                mix.resultTrackID = record.id
                mix.note = "Complete — \(sources.count) songs, \(DurationFormatter.string(plan.totalDuration))"
            }
            Log.info("mix complete: \(placed.path)", .download)
        } catch {
            try? FileManager.default.removeItem(at: jobDir)
            let lmError = LocalMusicError.wrap(error)
            if lmError.kind == .cancelled || Task.isCancelled || error is CancellationError {
                updateMix(id) { mix in
                    mix.state = .cancelled; mix.finishedAt = Date(); mix.error = nil
                    for i in mix.items.indices where !mix.items[i].state.isTerminal { mix.items[i].state = .cancelled }
                }
                Log.info("mix cancelled: \(mix.name)", .download)
            } else {
                updateMix(id) { mix in
                    mix.state = .failed
                    mix.finishedAt = Date()
                    mix.error = lmError
                    for i in mix.items.indices where !mix.items[i].state.isTerminal { mix.items[i].state = .cancelled }
                    if let details = lmError.technicalDetails, !mix.technicalLog.contains(details) { mix.technicalLog += "\n" + details }
                }
                Log.error("mix failed (\(lmError.kind.rawValue)): \(mix.name) — \(lmError.message)", .download)
            }
        }
    }

    /// Downloads one song into `dir/item-N`, identifies it and picks its artwork. Errors carry
    /// the song's position so the mix can say which link broke.
    private func fetch(_ item: MixItem, index: Int, mixID id: UUID, into dir: URL, downloader: any MediaDownloading) async throws -> MixSource {
        let itemDir = dir.appendingPathComponent("item-\(index + 1)", isDirectory: true)
        updateItem(id, index) { $0.state = .downloading; $0.fraction = 0 }
        log(id, "[LocalMusic] song \(index + 1): \(item.sourceURL.absoluteString)")
        do {
            let request = DownloadRequest(url: item.sourceURL, destinationDirectory: itemDir, format: .original,
                                          ffmpegDirectory: env.ffmpegDirectory, archiveFile: nil,
                                          embedMetadata: true, embedThumbnail: true)
            let result = try await downloader.download(request, onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.updateItem(id, index) { item in
                        if let f = progress.fraction { item.fraction = f }
                        if let phase = progress.phase, phase != "download", phase != "downloading", phase != "finished" { item.state = .processing }
                    }
                }
            }, onLog: { [weak self] line in
                Task { @MainActor in self?.log(id, "  [\(index + 1)] " + line) }
            })
            try Task.checkCancellation()

            var embedded = try await AudioMetadataReader.read(result.fileURL)
            if embedded.duration <= 0 {
                embedded.duration = try await env.ffmpegService.probe(result.fileURL).duration
            }
            guard embedded.duration > 0 else {
                throw LocalMusicError(kind: .invalidAudio, message: "Song \(index + 1) is not a valid audio file.", technicalDetails: result.fileURL.path)
            }

            updateItem(id, index) { $0.state = .identifying }
            let identified = env.metadata.identify(source: result.metadata, embedded: embedded, fallbackTitle: item.title, uploader: nil)
            var tags = identified.tags
            var artwork: Data? = embedded.artwork
            if env.settings.autoQueryMusicBrainz {
                let outcome = await env.identifier.identify(tags: tags, duration: embedded.duration, file: result.fileURL, options: env.identifierOptions)
                try Task.checkCancellation()
                if let best = outcome.accepted {
                    tags = best.tags(over: tags)
                    log(id, "  [\(index + 1)] MusicBrainz match \(best.recording.id) (\(String(format: "%.2f", best.score)))")
                    if env.settings.replaceThumbnailsWithAlbumArt,
                       let art = await env.coverArt.frontCover(releaseID: best.release?.id, releaseGroupID: best.release?.releaseGroupID) {
                        artwork = art
                    }
                } else if let error = outcome.error {
                    log(id, "  [\(index + 1)] MusicBrainz: \(error.message)")
                }
            }
            if artwork == nil, let thumb = result.metadata.thumbnailURL {
                if let raw = try? await env.artworkService.fetch(thumb) {
                    artwork = env.artworkService.normalized(env.artworkService.squared(raw))
                }
            }
            updateItem(id, index) { $0.state = .complete; $0.fraction = 1; $0.title = tags.title; $0.artist = tags.artist }
            log(id, "  [\(index + 1)] \(tags.artist.map { "\($0) – " } ?? "")\(tags.title) (\(DurationFormatter.string(embedded.duration)))")
            return MixSource(index: index, fileURL: result.fileURL, duration: embedded.duration, tags: tags, artwork: artwork)
        } catch {
            let wrapped = LocalMusicError.wrap(error)
            if wrapped.kind == .cancelled || error is CancellationError {
                updateItem(id, index) { $0.state = .cancelled }
                throw error
            }
            updateItem(id, index) { $0.state = .failed; $0.errorMessage = wrapped.message }
            throw LocalMusicError(kind: wrapped.kind, message: "Song \(index + 1) failed: \(wrapped.message)", technicalDetails: wrapped.technicalDetails)
        }
    }
}
