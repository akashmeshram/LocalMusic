import Foundation
import Observation
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
                self?.tasks[id] = nil
                self?.pump()
            }
        }
    }

    func cancel(_ id: UUID) {
        if let task = tasks[id] {
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
        }
        pump()
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
            let existing = try await env.store.tracks(sourceURL: job.sourceURL.absoluteString)
            if let hit = existing.first {
                throw LocalMusicError(kind: .alreadyDownloaded, message: "Already in your library as “\(hit.title)”.", technicalDetails: hit.fileURL.path)
            }

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

            // 3. Identify (Phase 1: source metadata + embedded tags; MusicBrainz arrives in Phase 3)
            update(id) { $0.state = .identifying }
            let meta = Self.organizeMetadata(source: result.metadata, tags: tags, fallbackTitle: job.title, uploader: job.uploader)
            update(id) { $0.title = meta.title }

            // 4. Organize
            update(id) { $0.state = .organizing }
            let organizer = FileOrganizer(root: root, folderTemplate: env.settings.folderTemplate, filenameTemplate: env.settings.filenameTemplate)
            let placed: URL
            if env.settings.autoOrganize {
                placed = try await Task.detached { try organizer.place(fileURL, as: meta) }.value
            } else {
                let flat = root.appendingPathComponent(fileURL.lastPathComponent)
                placed = try await Task.detached { try organizer.move(fileURL, to: flat) }.value
            }

            // 5. Index
            var artworkName: String?
            if let data = tags.artwork { artworkName = try? env.artwork.store(data) }
            let size = (try? placed.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let record = TrackRecord(
                fileURL: placed,
                sourceURL: job.sourceURL.absoluteString,
                extractor: result.metadata.extractor,
                title: meta.title, artist: meta.artist, albumArtist: meta.albumArtist, album: meta.album,
                trackNumber: meta.trackNumber, discNumber: meta.discNumber, genre: meta.genre, year: meta.year,
                composer: tags.composer, duration: tags.duration, fileFormat: placed.pathExtension.lowercased(),
                fileSize: size, artworkFileName: artworkName, downloadDate: Date())
            await env.library.upsert(record)
            try? FileManager.default.removeItem(at: jobDir)

            update(id) { job in
                job.state = .complete
                job.finishedAt = Date()
                job.resultFileURL = placed
                job.resultTrackID = record.id
                job.progress = DownloadProgress(fraction: 1, phase: "complete")
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

    /// Merges what the source knew with what is embedded in the file. Never invents values:
    /// missing album/year stay nil so the organizer routes the track to Singles / Unknown.
    static func organizeMetadata(source: SourceMetadata, tags: AudioFileMetadata, fallbackTitle: String, uploader: String?) -> OrganizeMetadata {
        let title = source.track ?? tags.title ?? source.title ?? fallbackTitle
        let cleanedUploader = (source.artist == nil && tags.artist == nil) ? Self.cleanUploader(source.uploader ?? source.channel ?? uploader) : nil
        return OrganizeMetadata(
            title: title,
            artist: source.artist ?? tags.artist ?? cleanedUploader,
            albumArtist: source.albumArtist ?? tags.albumArtist,
            album: source.album ?? tags.album,
            year: source.releaseYear ?? tags.year,
            trackNumber: source.trackNumber ?? tags.trackNumber,
            discNumber: source.discNumber ?? tags.discNumber,
            genre: source.genre ?? tags.genre)
    }

    static func cleanUploader(_ name: String?) -> String? {
        guard var s = name?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        for suffix in [" - Topic", "VEVO", " Official", "Official"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? nil : s
    }
}
