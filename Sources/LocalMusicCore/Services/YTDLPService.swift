import Foundation

/// Drives the `yt-dlp` executable. All arguments are literal; the URL is passed as a single
/// argument after `--` so nothing in it can be read as an option.
public struct YTDLPService: MediaDownloading {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    // MARK: Probe

    public func probe(url: URL) async throws -> MediaProbe {
        let args = ["--dump-single-json", "--flat-playlist", "--no-warnings", "--no-color",
                    "--ignore-errors", "--no-download", "--", url.absoluteString]
        Log.info("probe \(url.absoluteString)", .ytdlp)
        let output = try await ProcessRunner.run(executable, arguments: args, environment: await CertificateBundle.environment())
        guard let data = output.stdout.data(using: .utf8), !output.stdout.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw YTDLPErrorClassifier.classify(output: output.stderr, exitCode: output.exitCode, url: url)
        }
        return Self.parseProbe(json, requestedURL: url)
    }

    static func parseProbe(_ json: [String: Any], requestedURL: URL) -> MediaProbe {
        if (json["_type"] as? String) == "playlist", let rawEntries = json["entries"] as? [[String: Any]] {
            let entries = rawEntries.enumerated().compactMap { index, e -> MediaEntry? in
                guard let entryURL = Self.entryURL(e, fallbackID: e["id"] as? String, extractor: json["extractor"] as? String) else { return nil }
                let id = (e["id"] as? String) ?? entryURL.absoluteString
                return MediaEntry(
                    id: id,
                    url: entryURL,
                    title: (e["title"] as? String).flatMap { $0 == "[Private video]" || $0 == "[Deleted video]" ? nil : $0 } ?? "Untitled \(index + 1)",
                    uploader: (e["uploader"] as? String) ?? (e["channel"] as? String),
                    duration: Self.double(e["duration"]),
                    thumbnailURL: Self.thumbnail(e),
                    playlistIndex: (e["playlist_index"] as? Int) ?? (index + 1)
                )
            }
            let playlistURL = (json["webpage_url"] as? String).flatMap(URL.init) ?? requestedURL
            return .playlist(PlaylistInfo(
                title: (json["title"] as? String) ?? "Playlist",
                url: playlistURL,
                uploader: (json["uploader"] as? String) ?? (json["channel"] as? String),
                entries: entries))
        }
        let url = (json["webpage_url"] as? String).flatMap(URL.init) ?? requestedURL
        return .single(MediaEntry(
            id: (json["id"] as? String) ?? url.absoluteString,
            url: url,
            title: (json["title"] as? String) ?? url.lastPathComponent,
            uploader: (json["uploader"] as? String) ?? (json["channel"] as? String),
            duration: Self.double(json["duration"]),
            thumbnailURL: Self.thumbnail(json),
            playlistIndex: nil))
    }

    static func entryURL(_ entry: [String: Any], fallbackID: String?, extractor: String?) -> URL? {
        if let s = entry["webpage_url"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true { return u }
        if let s = entry["url"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true { return u }
        // Flat YouTube entries sometimes only carry an id.
        if let id = fallbackID, extractor?.lowercased().contains("youtube") == true {
            return URL(string: "https://www.youtube.com/watch?v=\(id)")
        }
        return nil
    }

    static func thumbnail(_ dict: [String: Any]) -> URL? {
        if let s = dict["thumbnail"] as? String, let u = URL(string: s) { return u }
        if let thumbs = dict["thumbnails"] as? [[String: Any]] {
            let best = thumbs.max { (Self.double($0["width"]) ?? 0) < (Self.double($1["width"]) ?? 0) }
            if let s = best?["url"] as? String, let u = URL(string: s) { return u }
        }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: Download

    public func download(
        _ request: DownloadRequest,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadResult {
        try FileManager.default.createDirectory(at: request.destinationDirectory, withIntermediateDirectories: true)
        let args = Self.arguments(for: request)
        Log.info("yt-dlp \(args.dropLast().joined(separator: " ")) <url>", .ytdlp)

        var log: [String] = []
        var finalPath: String?
        var lastPhase = "download"
        var sawArchiveSkip = false
        var exitCode: Int32 = -1

        let environment = await CertificateBundle.environment()
        let stream = ProcessRunner.stream(executable, arguments: args, environment: environment, currentDirectory: request.destinationDirectory)
        for try await event in stream {
            switch event {
            case .stdout(let line), .stderr(let line):
                let parsed = YTDLPProgressParser.parse(line)
                switch parsed {
                case .progress(var p):
                    p.phase = p.phase ?? lastPhase
                    onProgress(p)
                case .postprocess(let phase):
                    lastPhase = phase
                    onProgress(DownloadProgress(fraction: 1, phase: phase))
                    log.append(line); onLog(line)
                case .finalFile(let path):
                    finalPath = path
                    log.append(line); onLog(line)
                case .alreadyInArchive:
                    sawArchiveSkip = true
                    log.append(line); onLog(line)
                default:
                    log.append(line); onLog(line)
                }
            case .exit(let code):
                exitCode = code
            }
        }
        try Task.checkCancellation()
        let joinedLog = log.joined(separator: "\n")

        if let finalPath, FileManager.default.fileExists(atPath: finalPath) {
            let fileURL = URL(fileURLWithPath: finalPath)
            let infoURL = Self.findInfoJSON(in: request.destinationDirectory)
            let metadata = infoURL.flatMap { try? Self.readInfoJSON($0) } ?? SourceMetadata()
            return DownloadResult(fileURL: fileURL, infoJSONURL: infoURL, metadata: metadata, log: joinedLog)
        }
        if sawArchiveSkip {
            throw LocalMusicError(kind: .alreadyDownloaded, message: "This item was already downloaded.", technicalDetails: joinedLog)
        }
        // Fall back to whatever audio file yt-dlp left behind (older versions may not honor --print after_move).
        if exitCode == 0, let leftover = Self.findAudioFile(in: request.destinationDirectory) {
            let infoURL = Self.findInfoJSON(in: request.destinationDirectory)
            let metadata = infoURL.flatMap { try? Self.readInfoJSON($0) } ?? SourceMetadata()
            return DownloadResult(fileURL: leftover, infoJSONURL: infoURL, metadata: metadata, log: joinedLog)
        }
        throw YTDLPErrorClassifier.classify(output: joinedLog, exitCode: exitCode, url: request.url)
    }

    /// Builds the argument list. Pure so it can be unit-tested.
    public static func arguments(for request: DownloadRequest) -> [String] {
        var args: [String] = [
            "--no-playlist",
            "--newline", "--no-color", "--progress",
            "--progress-template", YTDLPProgressParser.downloadTemplate,
            "--progress-template", YTDLPProgressParser.postprocessTemplate,
            "--print", YTDLPProgressParser.finalFilePrint,
            "--no-simulate",
            "--encoding", "utf-8",
            "--no-mtime",
            "--write-info-json",
            "--no-write-playlist-metafiles",
            "--paths", "home:" + request.destinationDirectory.path,
            "--paths", "temp:" + request.destinationDirectory.path,
            "--output", "%(title).150B [%(id)s].%(ext)s",
            "--format", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio/best",
        ]
        let ffmpegAvailable = request.ffmpegDirectory != nil
        if let dir = request.ffmpegDirectory {
            args += ["--ffmpeg-location", dir.path]
        }
        if ffmpegAvailable {
            switch request.format {
            case .original:
                // Extract the audio track without re-encoding; container becomes m4a/opus/mp3/flac as appropriate.
                args += ["--extract-audio", "--audio-format", "best"]
            case .m4a:
                args += ["--extract-audio", "--audio-format", "m4a", "--audio-quality", "0"]
            case .mp3:
                args += ["--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"]
            }
            if request.embedMetadata { args.append("--embed-metadata") }
            if request.embedThumbnail { args.append("--embed-thumbnail") }
        }
        // The library index is the archive of truth (see DownloadManager); yt-dlp's own archive would
        // block deliberate re-downloads after a "Replace" decision or a deletion.
        args += ["--", request.url.absoluteString]
        return args
    }

    static func findInfoJSON(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.lastPathComponent.hasSuffix(".info.json") }
    }

    static func findAudioFile(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items
            .filter { LibraryScanner.audioExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.contains(".part") }
            .max { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 < (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 }
    }

    /// Reads the subset of yt-dlp's `.info.json` that matters for tagging.
    public static func readInfoJSON(_ url: URL) throws -> SourceMetadata {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return SourceMetadata() }
        return parseInfo(json)
    }

    public static func parseInfo(_ json: [String: Any]) -> SourceMetadata {
        var m = SourceMetadata()
        func str(_ key: String) -> String? {
            guard let s = json[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        m.id = str("id")
        m.title = str("title")
        m.track = str("track")
        m.artist = str("artist") ?? (json["artists"] as? [String])?.joined(separator: ", ") ?? str("creator")
        m.album = str("album")
        m.albumArtist = str("album_artist")
        m.uploader = str("uploader")
        m.channel = str("channel")
        m.genre = str("genre")
        m.trackNumber = json["track_number"] as? Int
        m.discNumber = json["disc_number"] as? Int
        m.releaseYear = json["release_year"] as? Int
        if m.releaseYear == nil, let rd = str("release_date"), rd.count >= 4 { m.releaseYear = Int(rd.prefix(4)) }
        if let ud = str("upload_date"), ud.count == 8 {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = TimeZone(identifier: "UTC")
            m.uploadDate = f.date(from: ud)
        }
        m.duration = double(json["duration"])
        m.thumbnailURL = thumbnail(json)
        m.webpageURL = str("webpage_url").flatMap(URL.init)
        m.extractor = str("extractor_key") ?? str("extractor")
        return m
    }
}
