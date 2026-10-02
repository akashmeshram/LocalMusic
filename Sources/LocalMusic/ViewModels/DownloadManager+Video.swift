import Foundation
import LocalMusicCore

/// Video export: one library track + one photo → MP4 (H.264/AAC, 1080p) plus a description
/// text file with chapter timestamps and source links, ready for a manual YouTube upload.
extension DownloadManager {
    /// Validates the request and queues it. Returns `false` and sets `submissionError` when
    /// the image is unreadable, the output would land inside the music library, or ffmpeg is missing.
    @discardableResult
    func submitVideoExport(track: TrackRecord, image: URL, output: URL) -> Bool {
        submissionError = nil
        guard env.ffmpegReady else {
            submissionError = LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to export videos. Run: brew install ffmpeg")
            return false
        }
        guard FileManager.default.isReadableFile(atPath: image.path) else {
            submissionError = LocalMusicError(kind: .invalidAudio, message: "Choose an image file first.", technicalDetails: image.path)
            return false
        }
        guard output.pathExtension.lowercased() == "mp4" else {
            submissionError = LocalMusicError(kind: .malformedURL, message: "The video must be saved as .mp4.")
            return false
        }
        if PathGuard(root: env.settings.musicDirectory).contains(output) {
            submissionError = LocalMusicError(kind: .pathEscapesLibrary, message: "Save the video outside the music library (Movies, for example).")
            return false
        }
        guard FileManager.default.isWritableFile(atPath: output.deletingLastPathComponent().path) else {
            submissionError = LocalMusicError(kind: .permissionDenied, message: "That folder is not writable.", technicalDetails: output.path)
            return false
        }
        let job = VideoExportJob(trackID: track.id, title: track.title, artist: track.artist, imageURL: image, outputURL: output)
        appendVideo(job)
        Log.info("queued video export of “\(track.title)” → \(output.lastPathComponent)", .download)
        pump()
        return true
    }

    func startVideo(_ id: UUID) {
        guard videoTasks[id] == nil else { return }
        videoTasks[id] = Task { [weak self] in
            await self?.runVideo(id)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.taskFinished(id, state: self.videos.first { $0.id == id }?.state ?? .failed)
            }
        }
    }

    private func log(_ id: UUID, _ line: String) {
        updateVideo(id) { if $0.technicalLog.utf8.count < 200_000 { $0.technicalLog += line + "\n" } }
    }

    static func tempDirectory(forVideo id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalMusic-video-\(id.uuidString)", isDirectory: true)
    }

    /// Links for the description: the track's own source plus any http(s) lines in its comment
    /// (mixes list one per song there), in order and without repeats.
    static func sourceLinks(sourceURL: String?, comment: String?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let candidates = [sourceURL ?? ""] + (comment ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for c in candidates where c.hasPrefix("http://") || c.hasPrefix("https://") {
            if seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    private func runVideo(_ id: UUID) async {
        guard let job = videos.first(where: { $0.id == id }) else { return }
        let tmp = Self.tempDirectory(forVideo: id)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try Task.checkCancellation()
            guard let track = env.library.trackByID[job.trackID] else {
                throw LocalMusicError(kind: .unknown, message: "The track is no longer in the library.")
            }
            guard env.ffmpegReady else {
                throw LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to export videos. Run: brew install ffmpeg")
            }
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            updateVideo(id) { $0.state = .processing; $0.fraction = 0 }

            // 1. Normalize the photo so ffmpeg always gets a PNG it can decode.
            let frame = tmp.appendingPathComponent("frame.png")
            try VideoBuilder.normalizeImage(job.imageURL, to: frame)
            log(id, "[LocalMusic] image: \(job.imageURL.lastPathComponent)")

            // 2. Render into the temp folder; only a finished file is moved into place.
            let rendered = tmp.appendingPathComponent("video.mp4")
            let duration = track.duration > 0 ? track.duration : (try await AudioMetadataReader.read(track.fileURL)).duration
            try await VideoBuilder(ffmpeg: env.ffmpegService.ffmpeg).build(
                image: frame, audio: track.fileURL, duration: duration, output: rendered,
                onProgress: { [weak self] f in Task { @MainActor in self?.updateVideo(id) { $0.fraction = f } } },
                onLog: { [weak self] l in Task { @MainActor in self?.log(id, l) } })
            try Task.checkCancellation()

            // 3. Description with chapters (ID3 CHAP frames, MP3 only) and source links.
            updateVideo(id) { $0.state = .organizing }
            var chapters: [TrackChapter] = []
            var comment: String?
            if track.fileURL.pathExtension.lowercased() == "mp3", let data = try? Data(contentsOf: track.fileURL) {
                let frames = ID3TagWriter.parse(data).frames
                chapters = ID3TagWriter.chapters(in: frames)
                comment = ID3TagWriter.comment(in: frames)
            }
            if comment == nil { comment = (try? await AudioMetadataReader.read(track.fileURL))?.comment }
            let links = Self.sourceLinks(sourceURL: track.sourceURL, comment: comment)
            let text = VideoBuilder.description(title: track.title, artist: track.artist, chapters: chapters, sources: links)
            log(id, "[LocalMusic] chapters: \(chapters.count), sources: \(links.count)")

            // 4. Move into place. The save panel already confirmed any overwrite.
            let fm = FileManager.default
            if fm.fileExists(atPath: job.outputURL.path) { try fm.removeItem(at: job.outputURL) }
            try fm.moveItem(at: rendered, to: job.outputURL)
            try text.write(to: job.descriptionURL, atomically: true, encoding: .utf8)
            updateVideo(id) { $0.state = .complete; $0.fraction = 1; $0.finishedAt = Date() }
            Log.info("video export finished: \(job.outputURL.lastPathComponent)", .download)
        } catch is CancellationError {
            updateVideo(id) { $0.state = .cancelled; $0.finishedAt = Date() }
        } catch {
            let wrapped = LocalMusicError.wrap(error)
            updateVideo(id) { $0.state = .failed; $0.error = wrapped; $0.finishedAt = Date() }
            Log.error("video export failed: \(wrapped.message)", .download)
        }
    }
}
