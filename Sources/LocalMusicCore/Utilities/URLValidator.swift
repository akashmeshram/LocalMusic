import Foundation

/// Normalizes user-entered text into a URL that is safe to hand to yt-dlp.
/// Only `http` and `https` schemes are accepted; everything else is rejected.
public enum URLValidator {
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        // Strip stray surrounding quotes or angle brackets pasted from chat clients.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))

        if !text.contains("://") {
            // Bare hostnames like "youtube.com/watch?v=..." get https.
            guard text.contains("."), !text.hasPrefix("."), !text.hasPrefix("-") else { return nil }
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, host.contains(".") || host == "localhost"
        else { return nil }
        return components.url
    }

    /// Cheap heuristic used before probing so the UI can label the input.
    public static func looksLikePlaylist(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if components.queryItems?.contains(where: { $0.name == "list" }) == true { return true }
        let path = components.path.lowercased()
        return path.contains("/playlist") || path.contains("/sets/") || path.contains("/album/")
    }
}
