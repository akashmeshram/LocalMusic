import Foundation

/// One classified line of yt-dlp output.
public enum YTDLPLine: Equatable, Sendable {
    case progress(DownloadProgress)
    case postprocess(String)
    case finalFile(String)
    case playlistItem(index: Int, count: Int)
    case destination(String)
    case alreadyInArchive
    case error(String)
    case warning(String)
    case other(String)
}

/// Parses yt-dlp's stdout. We ask yt-dlp for a machine-readable progress template
/// (`LMPROG|…`) but also understand its default human-readable progress line, so the
/// UI keeps working if a future yt-dlp changes template behavior.
public enum YTDLPProgressParser {
    public static let progressPrefix = "LMPROG|"
    public static let postprocessPrefix = "LMPOST|"
    public static let filePrefix = "LMFILE|"

    /// Passed to `--progress-template`.
    public static let downloadTemplate =
        "download:" + progressPrefix +
        "%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|" +
        "%(progress.speed)s|%(progress.eta)s|%(info.playlist_index)s|%(info.n_entries)s"
    public static let postprocessTemplate = "postprocess:" + postprocessPrefix + "%(progress.status)s|%(postprocessor)s"
    /// Passed to `--print`.
    public static let finalFilePrint = "after_move:" + filePrefix + "%(filepath)s"

    public static func parse(_ rawLine: String) -> YTDLPLine {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .other(line) }

        if line.hasPrefix(progressPrefix) {
            return .progress(parseTemplated(String(line.dropFirst(progressPrefix.count))))
        }
        if line.hasPrefix(postprocessPrefix) {
            let parts = line.dropFirst(postprocessPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
            return .postprocess(parts.count > 1 ? String(parts[1]) : "postprocess")
        }
        if line.hasPrefix(filePrefix) {
            return .finalFile(String(line.dropFirst(filePrefix.count)))
        }
        if line.hasPrefix("ERROR:") {
            return .error(line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("WARNING:") {
            return .warning(line.dropFirst("WARNING:".count).trimmingCharacters(in: .whitespaces))
        }
        if line.hasPrefix("[download]") {
            let body = line.dropFirst("[download]".count).trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("Destination:") {
                return .destination(body.dropFirst("Destination:".count).trimmingCharacters(in: .whitespaces))
            }
            if body.contains("has already been recorded in the archive") { return .alreadyInArchive }
            if let item = parsePlaylistItem(body) { return .playlistItem(index: item.0, count: item.1) }
            if let progress = parseLegacyProgress(body) { return .progress(progress) }
            return .other(line)
        }
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let tag = String(line[line.index(after: line.startIndex)..<close])
            if postprocessorTags.contains(tag) { return .postprocess(tag) }
        }
        return .other(line)
    }

    static let postprocessorTags: Set<String> = [
        "ExtractAudio", "EmbedThumbnail", "Metadata", "Merger", "FixupM4a", "FixupM3u8", "FixupStretched",
        "ThumbnailsConvertor", "MoveFiles", "VideoRemuxer", "VideoConvertor", "ModifyChapters", "EmbedSubtitle",
    ]

    /// `status|downloaded|total|total_estimate|speed|eta|playlist_index|n_entries`
    static func parseTemplated(_ body: String) -> DownloadProgress {
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
        func num(_ i: Int) -> Double? {
            guard i < parts.count else { return nil }
            let s = parts[i].trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s == "NA" || s == "None" { return nil }
            return Double(s)
        }
        let status = parts.first ?? ""
        let downloaded = num(1).map { Int64($0) }
        var total = num(2).map { Int64($0) }
        var estimated = false
        if total == nil, let est = num(3) { total = Int64(est); estimated = true }
        var fraction: Double?
        if let d = downloaded, let t = total, t > 0 { fraction = min(1, Double(d) / Double(t)) }
        if status == "finished" { fraction = 1 }
        return DownloadProgress(
            fraction: fraction,
            downloadedBytes: downloaded,
            totalBytes: total,
            isTotalEstimated: estimated,
            speedBytesPerSecond: num(4),
            etaSeconds: num(5).map { Int($0) },
            playlistIndex: num(6).map { Int($0) },
            playlistCount: num(7).map { Int($0) },
            phase: status.isEmpty ? "download" : status
        )
    }

    /// `Downloading item 3 of 12`
    static func parsePlaylistItem(_ body: String) -> (Int, Int)? {
        guard let match = body.wholeMatch(of: /Downloading item (\d+) of (\d+)/) else { return nil }
        return (Int(match.1) ?? 0, Int(match.2) ?? 0)
    }

    /// `  45.2% of 3.45MiB at 1.20MiB/s ETA 00:03` (also `~` estimated totals and `Unknown` values)
    static func parseLegacyProgress(_ body: String) -> DownloadProgress? {
        let regex = /^\s*(\d+(?:\.\d+)?)%\s+of\s+(~\s*)?([\d.]+)\s*([KMGT]?i?B)(?:\s+at\s+(?:([\d.]+)\s*([KMGT]?i?B)\/s|Unknown B\/s|Unknown speed))?(?:\s+ETA\s+(?:([\d:]+)|Unknown))?/
        guard let m = body.firstMatch(of: regex) else { return nil }
        let percent = Double(m.1) ?? 0
        let estimated = m.2 != nil
        let total = bytes(Double(m.3) ?? 0, unit: String(m.4))
        var speed: Double?
        if let s = m.5, let u = m.6 { speed = Double(bytes(Double(s) ?? 0, unit: String(u))) }
        let eta = m.7.flatMap { parseClock(String($0)) }
        let downloaded = Int64(Double(total) * percent / 100)
        return DownloadProgress(fraction: percent / 100, downloadedBytes: downloaded, totalBytes: total,
                                isTotalEstimated: estimated, speedBytesPerSecond: speed, etaSeconds: eta, phase: "download")
    }

    static func bytes(_ value: Double, unit: String) -> Int64 {
        let multiplier: Double
        switch unit.uppercased() {
        case "KIB", "KB": multiplier = 1024
        case "MIB", "MB": multiplier = 1024 * 1024
        case "GIB", "GB": multiplier = 1024 * 1024 * 1024
        case "TIB", "TB": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }

    static func parseClock(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == text.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
