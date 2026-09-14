import Foundation

/// Ranks MusicBrainz recordings against the downloaded track. Pure and unit-tested.
public struct CandidateScorer: Sendable {
    public struct Query: Sendable {
        public var title: String
        public var artist: String?
        public var album: String?
        public var duration: TimeInterval?
        public var year: Int?

        public init(title: String, artist: String? = nil, album: String? = nil, duration: TimeInterval? = nil, year: Int? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.year = year
        }
    }

    public var preferEarliestRelease: Bool

    public init(preferEarliestRelease: Bool = true) {
        self.preferEarliestRelease = preferEarliestRelease
    }

    public func rank(_ recordings: [MBRecording], for query: Query) -> [ScoredCandidate] {
        recordings.map { score($0, for: query) }
            .sorted { a, b in
                if abs(a.score - b.score) > 0.015 { return a.score > b.score }
                // Near-ties: the original (earliest) release wins, undated releases last.
                let da = a.release?.date ?? "9999", db = b.release?.date ?? "9999"
                if da != db { return preferEarliestRelease ? da < db : da > db }
                return a.score > b.score
            }
    }

    public func score(_ recording: MBRecording, for query: Query) -> ScoredCandidate {
        var breakdown: [String: Double] = [:]
        let titleScore = StringSimilarity.score(query.title, recording.title)
        breakdown["title"] = titleScore

        let artistScore: Double
        if let a = query.artist, !a.isEmpty {
            artistScore = StringSimilarity.score(a, recording.artistCredit)
        } else {
            artistScore = 0.5 // unknown artist: neither reward nor punish
        }
        breakdown["artist"] = artistScore

        let durationScore: Double
        let lengthUnknown = recording.duration == nil
        if let d = query.duration, d > 0, let r = recording.duration {
            let delta = abs(d - r)
            durationScore = delta <= 2 ? 1 : max(0, 1 - (delta - 2) / 13) // 0 at ≥15 s off
        } else {
            durationScore = lengthUnknown ? 0.4 : 0.5
        }
        breakdown["duration"] = durationScore

        let release = bestRelease(of: recording, for: query)
        var releaseScore = 0.3
        if let r = release {
            releaseScore = 0.6
            if r.year != nil { releaseScore += 0.15 }
            if r.isOfficial { releaseScore += 0.1 }
            if !r.isCompilation { releaseScore += 0.15 }
            if let album = query.album, !album.isEmpty {
                releaseScore = max(releaseScore, StringSimilarity.score(album, r.title))
            }
            if let qy = query.year, let ry = r.year {
                releaseScore = min(1, releaseScore + (abs(qy - ry) <= 1 ? 0.1 : -0.1))
            }
        }
        breakdown["release"] = min(1, releaseScore)

        // Penalize live/remix versions unless the query asked for one.
        var penalty = 0.0
        let q = query.title.lowercased()
        let wantsLive = q.contains("live"), wantsRemix = q.contains("remix")
        let rt = recording.title.lowercased()
        if rt.contains("live") && !wantsLive { penalty += 0.15 }
        if rt.contains("remix") && !wantsRemix { penalty += 0.15 }
        if let r = release, r.isLiveOrRemix, !wantsLive, !wantsRemix { penalty += 0.1 }
        // A recording that is a different length by more than half a minute is a different thing
        // (radio edit, snippet, extended mix), whatever the title says.
        if let d = query.duration, d > 0, let r = recording.duration, abs(d - r) > 30 { penalty += 0.15 }
        breakdown["penalty"] = penalty

        var total = max(0, titleScore * 0.35 + artistScore * 0.30 + durationScore * 0.25 + min(1, releaseScore) * 0.10 - penalty)
        // Without a known length there is no way to tell a radio edit from the album cut, so such
        // recordings can be offered to the user but never applied automatically.
        if lengthUnknown, query.duration != nil { total = min(total, 0.8) }
        return ScoredCandidate(recording: recording, release: release, score: total, breakdown: breakdown)
    }

    /// Picks the release that best represents the recording: official, non-compilation, an album
    /// if possible, then earliest (or latest) date, then matching the album name we were given.
    public func bestRelease(of recording: MBRecording, for query: Query) -> MBRelease? {
        guard !recording.releases.isEmpty else { return nil }
        func typeRank(_ r: MBRelease) -> Int {
            switch (r.primaryType ?? "").lowercased() {
            case "album": 0
            case "ep": 1
            case "single": 2
            default: 3
            }
        }
        return recording.releases.min { a, b in
            if let album = query.album, !album.isEmpty {
                let sa = StringSimilarity.score(album, a.title), sb = StringSimilarity.score(album, b.title)
                if abs(sa - sb) > 0.2 { return sa > sb }
            }
            if a.isOfficial != b.isOfficial { return a.isOfficial }
            if a.isCompilation != b.isCompilation { return !a.isCompilation }
            if a.isLiveOrRemix != b.isLiveOrRemix { return !a.isLiveOrRemix }
            let ta = typeRank(a), tb = typeRank(b)
            if ta != tb { return ta < tb }
            let da = a.date ?? "9999", db = b.date ?? "9999"
            if da != db { return preferEarliestRelease ? da < db : da > db }
            return (a.trackNumber != nil) && (b.trackNumber == nil)
        }
    }
}
