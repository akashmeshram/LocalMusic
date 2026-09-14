import Foundation

/// Turns raw yt-dlp/ffmpeg failure output into a user-facing `LocalMusicError`.
public enum YTDLPErrorClassifier {
    public static func classify(output: String, exitCode: Int32, url: URL? = nil) -> LocalMusicError {
        let text = output.lowercased()
        let details = trimmedDetails(output, exitCode: exitCode)

        func make(_ kind: LocalMusicError.Kind, _ message: String) -> LocalMusicError {
            LocalMusicError(kind: kind, message: message, technicalDetails: details)
        }

        if text.contains("private video") || text.contains("this video is private") {
            return make(.privateVideo, "This video is private and cannot be downloaded.")
        }
        if text.contains("available in your country") || text.contains("in your country") || text.contains("geo restriction") || text.contains("geo-restricted")
            || text.contains("blocked it in your country") || text.contains("not available from your location") {
            return make(.geoRestricted, "This media is not available in your region.")
        }
        if text.contains("sign in to confirm your age") || text.contains("age-restricted") || text.contains("age restricted") {
            return make(.loginRequired, "This media is age-restricted and requires signing in, which LocalMusic does not support.")
        }
        if text.contains("sign in to confirm you're not a bot") || text.contains("sign in to confirm you’re not a bot") || text.contains("login required") || text.contains("cookies") && text.contains("sign in") {
            return make(.loginRequired, "The site is asking for a sign-in before it will serve this media.")
        }
        if text.contains("video unavailable") || text.contains("has been removed") || text.contains("no longer available")
            || text.contains("this video is not available") || text.contains("content isn't available") || text.contains("does not exist")
            || text.contains("http error 404") || text.contains("http error 410") {
            return make(.videoUnavailable, "This media is unavailable. It may have been removed or made private.")
        }
        if text.contains("unsupported url") || text.contains("is not a valid url") || text.contains("no video formats found")
            || text.contains("unable to extract") && text.contains("url") {
            return make(.unsupportedURL, "This URL is not supported by yt-dlp.")
        }
        if text.contains("no space left on device") || text.contains("[errno 28]") {
            return make(.lowDiskSpace, "The disk is full. Free some space and try again.")
        }
        if text.contains("permission denied") || text.contains("[errno 13]") || text.contains("operation not permitted") {
            return make(.permissionDenied, "LocalMusic does not have permission to write to the music folder.")
        }
        if text.contains("ffprobe and ffmpeg not found") || text.contains("ffmpeg not found") || text.contains("postprocessing: ffmpeg") && text.contains("not found") {
            return make(.toolMissing, "ffmpeg is required for this step but was not found. Install it with: brew install ffmpeg")
        }
        if text.contains("http error 403") {
            return make(.network, "The site refused to serve the media (HTTP 403). This almost always means yt-dlp is out of date — update it (Settings → Advanced → Check for Tool Updates) and try again.")
        }
        if text.contains("unable to download webpage") || text.contains("network is unreachable") || text.contains("name resolution")
            || text.contains("timed out") || text.contains("connection reset") || text.contains("connection refused")
            || text.contains("http error 5") || text.contains("http error 429") || text.contains("urlopen error")
            || text.contains("ssl") && text.contains("error") || text.contains("incompleteread") {
            return make(.network, "A network error interrupted the download. Check your connection and try again.")
        }
        if text.contains("has already been recorded in the archive") {
            return make(.alreadyDownloaded, "This item was already downloaded.")
        }
        if exitCode == 15 || exitCode == -15 || text.contains("keyboardinterrupt") || text.contains("terminated") {
            return make(.cancelled, "Cancelled.")
        }
        if text.contains("invalid data found when processing input") || text.contains("moov atom not found") || text.contains("could not find codec parameters") {
            return make(.invalidAudio, "The downloaded file is not a valid audio file.")
        }
        if let firstError = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("ERROR:") }) {
            let msg = firstError.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
            return make(.unknown, "yt-dlp reported: \(String(msg.prefix(200)))")
        }
        return make(.unknown, "The download failed (exit code \(exitCode)).")
    }

    static func trimmedDetails(_ output: String, exitCode: Int32) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let interesting = lines.filter { !$0.hasPrefix(YTDLPProgressParser.progressPrefix) }
        let tail = interesting.suffix(60).joined(separator: "\n")
        return "exit code: \(exitCode)\n\(tail)"
    }
}
