import Foundation

/// Finds library tracks that are probably the same recording as a candidate.
public enum DuplicateDetector {
    public enum Reason: String, Sendable, Hashable {
        case sourceURL, musicBrainzRecording, artistAndTitle, fingerprint
        public var label: String {
            switch self {
            case .sourceURL: "same source URL"
            case .musicBrainzRecording: "same MusicBrainz recording"
            case .artistAndTitle: "same artist and title"
            case .fingerprint: "same audio fingerprint"
            }
        }
    }

    public struct Candidate: Sendable {
        public var sourceURL: String?
        public var musicBrainzRecordingID: String?
        public var artist: String?
        public var title: String
        public var duration: TimeInterval?
        public var fingerprint: String?

        public init(sourceURL: String? = nil, musicBrainzRecordingID: String? = nil, artist: String? = nil,
                    title: String, duration: TimeInterval? = nil, fingerprint: String? = nil) {
            self.sourceURL = sourceURL
            self.musicBrainzRecordingID = musicBrainzRecordingID
            self.artist = artist
            self.title = title
            self.duration = duration
            self.fingerprint = fingerprint
        }
    }

    public struct Match: Sendable, Hashable {
        public let track: TrackRecord
        public let reasons: [Reason]
        public var summary: String { reasons.map(\.label).joined(separator: ", ") }
    }

    /// Duration tolerance in seconds for the artist+title signal.
    public static let durationTolerance: TimeInterval = 3

    public static func matches(for candidate: Candidate, in library: [TrackRecord]) -> [Match] {
        let candidateTitle = normalizedTitle(candidate.title)
        let candidateArtist = candidate.artist.map(TitleCleaner.normalized)
        var results: [Match] = []
        for track in library {
            var reasons: [Reason] = []
            if let s = candidate.sourceURL, let t = track.sourceURL, canonicalURL(s) == canonicalURL(t) {
                reasons.append(.sourceURL)
            }
            if let m = candidate.musicBrainzRecordingID, let t = track.musicBrainzRecordingID, m == t {
                reasons.append(.musicBrainzRecording)
            }
            if !candidateTitle.isEmpty, normalizedTitle(track.title) == candidateTitle {
                let artistMatch: Bool = {
                    guard let ca = candidateArtist, !ca.isEmpty else { return true }
                    let ta = TitleCleaner.normalized(track.artist ?? track.albumArtist ?? "")
                    return ta.isEmpty || ta == ca || ta.contains(ca) || ca.contains(ta)
                }()
                let durationMatch: Bool = {
                    guard let d = candidate.duration, d > 0, track.duration > 0 else { return true }
                    return abs(d - track.duration) <= durationTolerance
                }()
                if artistMatch && durationMatch { reasons.append(.artistAndTitle) }
            }
            if let f = candidate.fingerprint, !f.isEmpty, f == track.fingerprintHint { reasons.append(.fingerprint) }
            if !reasons.isEmpty { results.append(Match(track: track, reasons: reasons)) }
        }
        return results.sorted { $0.reasons.count > $1.reasons.count }
    }

    /// Lowercased, bracket-free, punctuation-free, with "feat." clauses removed.
    public static func normalizedTitle(_ title: String) -> String {
        var s = TitleCleaner.clean(title).lowercased()
        s = s.replacingOccurrences(of: #"[\(\[].*?[\)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        return TitleCleaner.normalized(s)
    }

    /// Ignores scheme, "www.", tracking parameters and trailing slashes so equivalent URLs compare equal.
    public static func canonicalURL(_ s: String) -> String {
        guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespaces)) else { return s.lowercased() }
        c.scheme = nil
        c.host = c.host?.lowercased().replacingOccurrences(of: #"^(www|m|music)\."#, with: "", options: .regularExpression)
        // A video URL with a "list" parameter is still that video; only playlist pages keep "list".
        let keep: Set<String> = c.path.lowercased().contains("playlist") ? ["list"] : ["v", "id", "p"]
        c.queryItems = c.queryItems?.filter { keep.contains($0.name) }.sorted { $0.name < $1.name }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        // youtu.be/ID → youtube.com/watch?v=ID
        if c.host == "youtu.be", c.path.count > 1 {
            let id = String(c.path.dropFirst())
            c.host = "youtube.com"; c.path = "/watch"; c.queryItems = [URLQueryItem(name: "v", value: id)]
        }
        var out = (c.host ?? "") + c.path
        if out.hasSuffix("/") { out.removeLast() }
        if let q = c.query, !q.isEmpty { out += "?" + q }
        return out
    }
}

extension TrackRecord {
    /// Placeholder until fingerprints are stored (AcoustID phase); kept so the detector API is stable.
    var fingerprintHint: String? { nil }
}
