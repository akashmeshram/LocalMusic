import Foundation

public struct MBRelease: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var date: String?
    public var status: String?
    public var country: String?
    public var primaryType: String?
    public var secondaryTypes: [String]
    public var releaseGroupID: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var trackCount: Int?
    public var artistCredit: String?

    public init(id: String, title: String, date: String? = nil, status: String? = nil, country: String? = nil,
                primaryType: String? = nil, secondaryTypes: [String] = [], releaseGroupID: String? = nil,
                trackNumber: Int? = nil, discNumber: Int? = nil, trackCount: Int? = nil, artistCredit: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.status = status
        self.country = country
        self.primaryType = primaryType
        self.secondaryTypes = secondaryTypes
        self.releaseGroupID = releaseGroupID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.trackCount = trackCount
        self.artistCredit = artistCredit
    }

    public var year: Int? { date.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil } }
    public var isCompilation: Bool { secondaryTypes.contains { $0.lowercased() == "compilation" } }
    public var isLiveOrRemix: Bool { secondaryTypes.contains { ["live", "remix", "dj-mix", "mixtape/street"].contains($0.lowercased()) } }
    public var isOfficial: Bool { (status ?? "Official").lowercased() == "official" }
}

public struct MBRecording: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artistCredit: String
    public var artistIDs: [String]
    public var lengthMs: Int?
    public var searchScore: Int
    public var releases: [MBRelease]
    public var isrcs: [String]

    public init(id: String, title: String, artistCredit: String, artistIDs: [String] = [], lengthMs: Int? = nil,
                searchScore: Int = 0, releases: [MBRelease] = [], isrcs: [String] = []) {
        self.id = id
        self.title = title
        self.artistCredit = artistCredit
        self.artistIDs = artistIDs
        self.lengthMs = lengthMs
        self.searchScore = searchScore
        self.releases = releases
        self.isrcs = isrcs
    }

    public var duration: TimeInterval? { lengthMs.map { Double($0) / 1000 } }
}

/// A recording ranked against what we know about the downloaded track.
public struct ScoredCandidate: Sendable, Hashable, Identifiable {
    public var recording: MBRecording
    public var release: MBRelease?
    public var score: Double
    public var breakdown: [String: Double]

    public var id: String { recording.id + (release?.id ?? "") }

    public init(recording: MBRecording, release: MBRelease?, score: Double, breakdown: [String: Double]) {
        self.recording = recording
        self.release = release
        self.score = score
        self.breakdown = breakdown
    }

    /// Tags this candidate would produce, layered over the current ones.
    public func tags(over current: TrackTags) -> TrackTags {
        var t = current
        t.title = recording.title
        t.artist = recording.artistCredit
        t.albumArtist = release?.artistCredit ?? recording.artistCredit
        t.album = release?.title ?? current.album
        t.year = release?.year ?? current.year
        t.trackNumber = release?.trackNumber ?? current.trackNumber
        t.trackTotal = release?.trackCount ?? current.trackTotal
        t.discNumber = release?.discNumber ?? current.discNumber
        t.musicBrainzRecordingID = recording.id
        t.musicBrainzReleaseID = release?.id
        return t
    }

    public var summary: String {
        var parts = [recording.artistCredit + " — " + recording.title]
        if let r = release {
            var album = r.title
            if let y = r.year { album += " (\(y))" }
            if let n = r.trackNumber { album += " · track \(n)" }
            parts.append(album)
        }
        if let d = recording.duration { parts.append(DurationFormatter.string(d)) }
        return parts.joined(separator: " · ")
    }
}
