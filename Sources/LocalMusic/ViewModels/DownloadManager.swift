import Foundation
import Observation
import UserNotifications
import LocalMusicCore

/// Owns the download queue. Each job runs as its own `Task` and walks the pipeline
/// download → process → identify → organize → index. Failures are isolated per job.
@MainActor
@Observable
final class DownloadManager {
    private(set) var jobs: [DownloadJob] = []
    var pendingPlaylist: PlaylistInfo?
    private(set) var isProbing = false
    var submissionError: LocalMusicError?

    private unowned let env: AppEnvironment
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var duplicateDecisions: [UUID: CheckedContinuation<DuplicateDecision, Never>] = [:]
    /// Jobs finished since the queue was last idle, for the completion notification.
    private var finishedSinceIdle: (complete: Int, failed: Int) = (0, 0)

    init(env: AppEnvironment) {
        self.env = env
    }

    var activeJobs: [DownloadJob] { jobs.filter { $0.state.isActive } }
    var waitingJobs: [DownloadJob] { jobs.filter { $0.state == .waiting } }
    var unfinishedCount: Int { jobs.filter { !$0.state.isTerminal }.count }

    // MARK: Submission

    /// Validates and probes user input. Single items are queued immediately; playlists are
    /// surfaced via `pendingPlaylist` so the user can review and deselect entries.
    func submit(_ text: String) async {
        submissionError = nil
        guard let url = URLValidator.normalize(text) else {
            submissionError = LocalMusicError(kind: .malformedURL, message: "That doesn't look like a valid http(s) URL.")
            return
        }
        guard let downloader = env.makeDownloader() else {
            submissionError = LocalMusicError(kind: .toolMissing, message: "yt-dlp is not installed. Run: brew install yt-dlp ffmpeg")
            return
        }
        isProbing = true
        defer { isProbing = false }
        do {
            switch try await downloader.probe(url: url) {
            case .single(let entry):
                enqueue([entry], playlist: nil)
            case .playlist(let info):
                if info.entries.isEmpty {
                    submissionError = LocalMusicError(kind: .videoUnavailable, message: "The playlist is empty or could not be read.")
                } else {
                    pendingPlaylist = info
                }
            }
        } catch {
            submissionError = LocalMusicError.wrap(error)
            Log.error("probe failed for \(url.absoluteString): \(error)", .download)
        }
    }

    func enqueue(_ entries: [MediaEntry], playlist: PlaylistInfo?) {
        for entry in entries {
            var job = DownloadJob(sourceURL: entry.url, title: entry.title, uploader: entry.uploader,
                                  thumbnailURL: entry.thumbnailURL, expectedDuration: entry.duration,
                                  playlistTitle: playlist?.title, playlistIndex: entry.playlistIndex,
                                  playlistCount: playlist?.entries.count)
            job.technicalLog = ""
            jobs.append(job)
        }
        Log.info("queued \(entries.count) item(s)\(playlist.map { " from playlist “\($0.title)”" } ?? "")", .download)
        if env.settings.autoStartDownloads { pump() }
    }

    // MARK: Scheduling

    /// Starts waiting jobs while the concurrency limit allows.
    func pump() {
        let limit = max(1, env.settings.maxConcurrentDownloads)
        var running = activeJobs.count
        for job in jobs where job.state == .waiting && running < limit {
            start(job.id)
            running += 1
        }
    }

    func startAll() { pump() }

    private func start(_ id: UUID) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            await self?.run(id)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.tasks[id] = nil
                if let job = self.jobs.first(where: { $0.id == id }) {
                    if job.state == .complete { self.finishedSinceIdle.complete += 1 }
                    if job.state == .failed { self.finishedSinceIdle.failed += 1 }
                }
                self.pump()
                if self.unfinishedCount == 0 { self.queueBecameIdle() }
            }
        }
    }

    /// Posts a system notification when a batch of three or more downloads has finished.
    private func queueBecameIdle() {
        let counts = finishedSinceIdle
        finishedSinceIdle = (0, 0)
        guard counts.complete + counts.failed >= 3, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Downloads finished"
            content.body = counts.failed == 0
                ? "\(counts.complete) tracks were added to your library."
                : "\(counts.complete) tracks added, \(counts.failed) failed."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "downloads-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }

    func cancel(_ id: UUID) {
        if let continuation = duplicateDecisions.removeValue(forKey: id) {
            update(id) { $0.pendingDuplicate = nil }
            continuation.resume(returning: .skip)
            tasks[id]?.cancel()
        } else if let task = tasks[id] {
            task.cancel()
        } else {
            update(id) { $0.state = .cancelled; $0.finishedAt = Date() }
        }
    }

    func cancelAll() {
        for job in jobs where !job.state.isTerminal { cancel(job.id) }
    }

    func retry(_ id: UUID) {
        update(id) { job in
            job.state = .waiting
            job.error = nil
            job.progress = nil
            job.technicalLog = ""
            job.finishedAt = nil
            job.note = nil
            job.pendingDuplicate = nil
            job.candidates = []
        }
        pump()
    }

    /// Called after the user picked a match for a completed job.
    func clearCandidates(_ id: UUID) {
        update(id) { $0.candidates = []; $0.note = nil; $0.metadataOrigin = .musicBrainz }
    }

    /// Resolves a job that is waiting on a duplicate decision.
    func resolveDuplicate(_ id: UUID, _ decision: DuplicateDecision) {
        guard let continuation = duplicateDecisions.removeValue(forKey: id) else { return }
        update(id) { $0.pendingDuplicate = nil }
        continuation.resume(returning: decision)
    }

    private func askDuplicate(_ id: UUID, match: DuplicateDetector.Match) async -> DuplicateDecision {
        switch env.settings.duplicatePolicy {
        case .skip: return .skip
        case .keepBoth: return .keepBoth
        case .replace: return .replace
        case .ask: break
        }
        update(id) { $0.pendingDuplicate = match }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                duplicateDecisions[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveDuplicate(id, .skip) }
        }
    }

    func remove(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isTerminal else { return }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    private func update(_ id: UUID, _ body: (inout DownloadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[i])
    }

    private func appendLog(_ id: UUID, _ line: String) {
        update(id) { job in
            if job.technicalLog.utf8.count < 200_000 { job.technicalLog += line + "\n" }
        }
    }

    // MARK: Pipeline

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let root = env.settings.musicDirectory
        let jobDir = AppPaths.incomingDirectory(musicRoot: root).appendingPathComponent(id.uuidString, isDirectory: true)

        do {
            try Task.checkCancellation()
            guard let downloader = env.makeDownloader() else {
                throw LocalMusicError(kind: .toolMissing, message: "yt-dlp is not installed. Run: brew install yt-dlp ffmpeg")
            }
            try AppPaths.ensureDirectories(musicRoot: root)
            if let free = AppPaths.availableCapacity(at: root), free < 300 * 1024 * 1024 {
                throw LocalMusicError(kind: .lowDiskSpace, message: "Less than 300 MB free on the music volume.", technicalDetails: "available: \(free) bytes")
            }

            // Same source already in the library? Ask before spending bandwidth.
            var replacing: TrackRecord?
            let urlCandidate = DuplicateDetector.Candidate(sourceURL: job.sourceURL.absoluteString, title: job.title)
            if let match = DuplicateDetector.matches(for: urlCandidate, in: env.library.tracks).first(where: { $0.reasons.contains(.sourceURL) }) {
                appendLog(id, "[LocalMusic] already downloaded from this URL: \(match.track.fileURL.lastPathComponent)")
                switch await askDuplicate(id, match: match) {
                case .skip:
                    update(id) { $0.state = .cancelled; $0.finishedAt = Date(); $0.note = "Skipped — already in library as “\(match.track.title)”"; $0.resultTrackID = match.track.id }
                    return
                case .keepBoth: break
                case .replace: replacing = match.track
                }
            }
            try Task.checkCancellation()

            // 1. Download
            update(id) { $0.state = .downloading; $0.progress = DownloadProgress(phase: "download") }
            let request = DownloadRequest(url: job.sourceURL, destinationDirectory: jobDir, format: env.settings.preferredFormat,
                                          ffmpegDirectory: env.ffmpegDirectory, archiveFile: AppPaths.downloadArchiveURL,
                                          embedMetadata: true, embedThumbnail: true)
            let result = try await downloader.download(request, onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.update(id) { job in
                        job.progress = progress
                        if let phase = progress.phase, phase != "download", phase != "downloading", phase != "finished" {
                            job.state = .processing
                        }
                    }
                }
            }, onLog: { [weak self] line in
                Task { @MainActor in self?.appendLog(id, line) }
            })
            if !result.log.isEmpty { appendLog(id, result.log) }

            // 2. Process (convert non-playable containers, validate)
            update(id) { $0.state = .processing; $0.progress = DownloadProgress(fraction: 1, phase: "processing") }
            var fileURL = result.fileURL
            let ffmpeg = env.ffmpegService
            if FFmpegService.needsConversion(fileExtension: fileURL.pathExtension) {
                if env.ffmpegReady {
                    let converted = fileURL.deletingPathExtension().appendingPathExtension("m4a")
                    appendLog(id, "[LocalMusic] converting \(fileURL.pathExtension) → m4a for native playback")
                    try await ffmpeg.convertToM4A(fileURL, output: converted) { [weak self] line in
                        Task { @MainActor in self?.appendLog(id, line) }
                    }
                    try? FileManager.default.removeItem(at: fileURL)
                    fileURL = converted
                } else {
                    appendLog(id, "[LocalMusic] ffmpeg unavailable; keeping .\(fileURL.pathExtension) (may not play in LocalMusic)")
                }
            }
            let tags = try await AudioMetadataReader.read(fileURL)
            guard tags.duration > 0 || tags.isPlayable else {
                throw LocalMusicError(kind: .invalidAudio, message: "The downloaded file is not a valid audio file.", technicalDetails: fileURL.path)
            }

            // 3. Identify: source metadata + embedded tags → cleaned tags (MusicBrainz joins in Phase 3).
            update(id) { $0.state = .identifying }
            let identified = env.metadata.identify(source: result.metadata, embedded: tags, fallbackTitle: job.title, uploader: job.uploader)
            var finalTags = identified.tags
            var origin = identified.origin
            update(id) { $0.title = finalTags.title }
            appendLog(id, "[LocalMusic] identified via \(identified.origin.rawValue) (confidence \(String(format: "%.2f", identified.confidence)))")

            // MusicBrainz: only high-confidence matches are applied; the rest are offered to the user.
            var coverArtData: Data?
            if env.settings.autoQueryMusicBrainz {
                let outcome = await env.identifier.identify(tags: finalTags, duration: tags.duration, file: fileURL, options: env.identifierOptions)
                try Task.checkCancellation()
                if let error = outcome.error { appendLog(id, "[LocalMusic] MusicBrainz: \(error.message)") }
                for c in outcome.candidates { appendLog(id, String(format: "[LocalMusic]   %.2f  %@", c.score, c.summary)) }
                if let best = outcome.accepted {
                    finalTags = best.tags(over: finalTags)
                    origin = .musicBrainz
                    update(id) { $0.title = finalTags.title; $0.candidates = [] }
                    appendLog(id, "[LocalMusic] accepted MusicBrainz match \(best.recording.id) (\(String(format: "%.2f", best.score)))\(outcome.usedFingerprint ? " via fingerprint" : "")")
                    if env.settings.replaceThumbnailsWithAlbumArt {
                        coverArtData = await env.coverArt.frontCover(releaseID: best.release?.id, releaseGroupID: best.release?.releaseGroupID)
                    }
                } else if !outcome.candidates.isEmpty {
                    update(id) { $0.candidates = outcome.candidates }
                    appendLog(id, "[LocalMusic] no match cleared \(String(format: "%.0f%%", env.settings.minimumAutoMatchConfidence * 100)); kept original metadata")
                }
            }
            update(id) { $0.metadataOrigin = origin }

            // Artwork: album art from the Cover Art Archive, then embedded art, then the source thumbnail.
            var artworkData = coverArtData ?? tags.artwork
            if coverArtData != nil { finalTags.artwork = .replace(coverArtData!) }
            if artworkData == nil, let thumb = result.metadata.thumbnailURL ?? job.thumbnailURL {
                do {
                    let raw = try await env.artworkService.fetch(thumb)
                    artworkData = env.artworkService.normalized(env.artworkService.squared(raw))
                    appendLog(id, "[LocalMusic] fetched thumbnail artwork (\(ByteFormatter.string(Int64(artworkData?.count ?? 0))))")
                } catch {
                    appendLog(id, "[LocalMusic] thumbnail unavailable: \(error.localizedDescription)")
                }
                if let data = artworkData { finalTags.artwork = .replace(data) }
            }

            // Same recording under another URL? Ask before anything reaches the library.
            let candidate = DuplicateDetector.Candidate(musicBrainzRecordingID: finalTags.musicBrainzRecordingID,
                                                        artist: finalTags.artist, title: finalTags.title, duration: tags.duration)
            if replacing == nil, let match = DuplicateDetector.matches(for: candidate, in: env.library.tracks).first {
                appendLog(id, "[LocalMusic] possible duplicate of \(match.track.fileURL.lastPathComponent): \(match.summary)")
                switch await askDuplicate(id, match: match) {
                case .skip:
                    try? FileManager.default.removeItem(at: jobDir)
                    update(id) { $0.state = .cancelled; $0.finishedAt = Date(); $0.note = "Skipped — duplicate of “\(match.track.title)”"; $0.resultTrackID = match.track.id }
                    Log.info("skipped duplicate: \(job.sourceURL.absoluteString)", .download)
                    return
                case .keepBoth:
                    appendLog(id, "[LocalMusic] keeping both")
                case .replace:
                    replacing = match.track
                }
            }
            try Task.checkCancellation()

            // Write tags + artwork into the file itself (native writers keep the audio untouched).
            if finalTags.comment == nil { finalTags.comment = job.sourceURL.absoluteString }
            if env.tagWriter.canWrite(fileExtension: fileURL.pathExtension) {
                do {
                    try await env.tagWriter.write(finalTags, to: fileURL)
                } catch {
                    appendLog(id, "[LocalMusic] could not write tags: \(error.localizedDescription)")
                }
            }

            // 4. Organize
            update(id) { $0.state = .organizing }
            if let old = replacing {
                await env.library.delete([old])
                appendLog(id, "[LocalMusic] replaced \(old.fileURL.lastPathComponent)")
            }
            let organizer = FileOrganizer(root: root, folderTemplate: env.settings.folderTemplate, filenameTemplate: env.settings.filenameTemplate)
            let organizeMeta = finalTags.organizeMetadata
            let placed: URL
            if env.settings.autoOrganize {
                placed = try await Task.detached { try organizer.place(fileURL, as: organizeMeta) }.value
            } else {
                let flat = root.appendingPathComponent(fileURL.lastPathComponent)
                placed = try await Task.detached { try organizer.move(fileURL, to: flat) }.value
            }

            // 5. Index
            var artworkName: String?
            if let data = artworkData { artworkName = try? env.artwork.store(data) }
            let size = (try? placed.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            var record = TrackRecord(fileURL: placed, sourceURL: job.sourceURL.absoluteString, extractor: result.metadata.extractor,
                                     title: finalTags.title, duration: tags.duration, fileFormat: placed.pathExtension.lowercased(),
                                     fileSize: size, artworkFileName: artworkName, downloadDate: Date())
            finalTags.apply(to: &record)
            await env.library.upsert(record)
            AppPaths.appendToDownloadArchive(extractor: result.metadata.extractor, id: result.metadata.id)
            try? FileManager.default.removeItem(at: jobDir)

            update(id) { job in
                job.state = .complete
                job.finishedAt = Date()
                job.resultFileURL = placed
                job.resultTrackID = record.id
                job.progress = DownloadProgress(fraction: 1, phase: "complete")
                if !job.candidates.isEmpty { job.note = "Complete — metadata uncertain, \(job.candidates.count) possible match\(job.candidates.count == 1 ? "" : "es")" }
            }
            Log.info("complete: \(placed.path)", .download)
        } catch {
            try? FileManager.default.removeItem(at: jobDir)
            let lmError = LocalMusicError.wrap(error)
            if lmError.kind == .cancelled || Task.isCancelled {
                update(id) { $0.state = .cancelled; $0.finishedAt = Date(); $0.error = nil }
                Log.info("cancelled: \(job.sourceURL.absoluteString)", .download)
            } else {
                update(id) { job in
                    job.state = .failed
                    job.finishedAt = Date()
                    job.error = lmError
                    if let details = lmError.technicalDetails, !job.technicalLog.contains(details) {
                        job.technicalLog += "\n" + details
                    }
                }
                Log.error("failed (\(lmError.kind.rawValue)): \(job.sourceURL.absoluteString) — \(lmError.message)", .download)
            }
        }
    }
}
