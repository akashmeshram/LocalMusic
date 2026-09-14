import Foundation

/// Stages 4–8 of the identification pipeline: query MusicBrainz, rank, gate on confidence,
/// optionally fall back to AcoustID fingerprinting when text matching is weak.
public struct RecordingIdentifier: Sendable {
    public struct Options: Sendable {
        public var minimumAutoConfidence: Double
        public var preferEarliestRelease: Bool
        public var acoustIDKey: String?
        public var fpcalc: URL?

        public init(minimumAutoConfidence: Double = 0.85, preferEarliestRelease: Bool = true, acoustIDKey: String? = nil, fpcalc: URL? = nil) {
            self.minimumAutoConfidence = minimumAutoConfidence
            self.preferEarliestRelease = preferEarliestRelease
            self.acoustIDKey = acoustIDKey
            self.fpcalc = fpcalc
        }
    }

    public struct Outcome: Sendable {
        /// Set when a candidate cleared the confidence bar and was applied.
        public var accepted: ScoredCandidate?
        /// Best few candidates for manual selection (empty when nothing plausible was found).
        public var candidates: [ScoredCandidate]
        public var usedFingerprint: Bool
        public var error: LocalMusicError?
    }

    let musicBrainz: MusicBrainzService
    let acoustID: AcoustIDService

    public init(musicBrainz: MusicBrainzService, acoustID: AcoustIDService = AcoustIDService()) {
        self.musicBrainz = musicBrainz
        self.acoustID = acoustID
    }

    public func identify(tags: TrackTags, duration: TimeInterval, file: URL?, options: Options) async -> Outcome {
        let scorer = CandidateScorer(preferEarliestRelease: options.preferEarliestRelease)
        let query = CandidateScorer.Query(title: tags.title, artist: tags.artist, album: tags.album, duration: duration, year: tags.year)
        var ranked: [ScoredCandidate] = []
        var outcomeError: LocalMusicError?

        do {
            // Pass 1: title + artist within a duration window (precise when the length is known).
            var recordings = try await musicBrainz.searchRecordings(title: tags.title, artist: tags.artist, duration: duration > 0 ? duration : nil)
            ranked = scorer.rank(recordings, for: query)
            // Pass 2: drop the duration constraint (and the artist, if it was only a channel guess)
            // when nothing convincing came back.
            if (ranked.first?.score ?? 0) < options.minimumAutoConfidence {
                let more = try await musicBrainz.searchRecordings(title: tags.title, artist: ranked.isEmpty ? nil : tags.artist, duration: nil)
                recordings += more.filter { m in !recordings.contains { $0.id == m.id } }
                ranked = scorer.rank(recordings, for: query)
            }
        } catch {
            outcomeError = LocalMusicError.wrap(error)
            Log.warning("MusicBrainz lookup failed: \(outcomeError!.message)", .metadata)
        }

        // The search response carries only a sample of each recording's releases, often without
        // dates. Refresh the leading candidates with a full lookup so the release choice
        // (original album vs. reissue vs. compilation) is made on complete data.
        if let best = ranked.first, best.score >= 0.6 {
            let leaders = ranked.prefix(3).filter { $0.score >= best.score - 0.05 }
            var refreshed: [ScoredCandidate] = []
            for c in leaders {
                if let full = try? await musicBrainz.recording(id: c.recording.id), !full.releases.isEmpty {
                    var rescored = scorer.score(full, for: query)
                    rescored.breakdown["refreshed"] = 1
                    refreshed.append(rescored)
                } else {
                    refreshed.append(c)
                }
            }
            let leaderIDs = Set(leaders.map(\.recording.id))
            let rest = ranked.filter { !leaderIDs.contains($0.recording.id) }
            ranked = scorer.rank((refreshed + rest).map(\.recording), for: query)
        }

        var usedFingerprint = false
        let weak = (ranked.first?.score ?? 0) < options.minimumAutoConfidence
        if weak, let key = options.acoustIDKey, !key.isEmpty, let fpcalc = options.fpcalc, let file {
            usedFingerprint = true
            do {
                let fp = try await FingerprintService(fpcalc: fpcalc).fingerprint(file)
                let matches = try await acoustID.lookup(fp, apiKey: key)
                for match in matches.prefix(2) where match.score >= 0.5 {
                    for id in match.recordingIDs.prefix(3) {
                        if let rec = try await musicBrainz.recording(id: id) {
                            var scored = scorer.score(rec, for: query)
                            // Fingerprint agreement is strong evidence: lift the score toward the AcoustID confidence.
                            scored.score = max(scored.score, 0.6 + 0.4 * match.score * max(scored.breakdown["duration"] ?? 0.5, 0.5))
                            scored.breakdown["fingerprint"] = match.score
                            ranked.append(scored)
                        }
                    }
                }
                ranked.sort { $0.score > $1.score }
            } catch {
                Log.warning("fingerprint stage failed: \(error.localizedDescription)", .metadata)
            }
        }

        // De-duplicate by recording id, keep the top five.
        var seen = Set<String>()
        let top = ranked.filter { seen.insert($0.recording.id).inserted }.prefix(5).map { $0 }
        let accepted = top.first.flatMap { $0.score >= options.minimumAutoConfidence ? $0 : nil }
        // Only offer manual choices that are at least plausible.
        let plausible = top.filter { $0.score >= 0.35 }
        return Outcome(accepted: accepted, candidates: plausible, usedFingerprint: usedFingerprint, error: outcomeError)
    }
}
