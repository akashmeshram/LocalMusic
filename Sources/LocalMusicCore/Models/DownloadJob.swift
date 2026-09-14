import Foundation

public enum DownloadState: String, Hashable, Sendable, Codable, CaseIterable {
    case waiting, downloading, processing, identifying, organizing, complete, failed, cancelled

    public var label: String {
        switch self {
        case .waiting: "Waiting"
        case .downloading: "Downloading"
        case .processing: "Processing"
        case .identifying: "Identifying"
        case .organizing: "Organizing"
        case .complete: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    public var isTerminal: Bool { self == .complete || self == .failed || self == .cancelled }
    public var isActive: Bool { !isTerminal && self != .waiting }
}

/// Real-time progress parsed from yt-dlp output.
public struct DownloadProgress: Hashable, Sendable {
    public var fraction: Double?
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var isTotalEstimated: Bool
    public var speedBytesPerSecond: Double?
    public var etaSeconds: Int?
    public var playlistIndex: Int?
    public var playlistCount: Int?
    /// Free-form phase from yt-dlp, e.g. "download", "ExtractAudio", "EmbedThumbnail".
    public var phase: String?

    public init(fraction: Double? = nil, downloadedBytes: Int64? = nil, totalBytes: Int64? = nil,
                isTotalEstimated: Bool = false, speedBytesPerSecond: Double? = nil, etaSeconds: Int? = nil,
                playlistIndex: Int? = nil, playlistCount: Int? = nil, phase: String? = nil) {
        self.fraction = fraction
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isTotalEstimated = isTotalEstimated
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.playlistIndex = playlistIndex
        self.playlistCount = playlistCount
        self.phase = phase
    }

    public var percentText: String {
        guard let fraction else { return "" }
        return String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
    }

    public var sizeText: String {
        switch (downloadedBytes, totalBytes) {
        case let (d?, t?): return "\(ByteFormatter.string(d)) of \(isTotalEstimated ? "~" : "")\(ByteFormatter.string(t))"
        case let (d?, nil): return ByteFormatter.string(d)
        default: return ""
        }
    }

    public var speedText: String { speedBytesPerSecond.map(ByteFormatter.speed) ?? "" }
    public var etaText: String { etaSeconds.map { DurationFormatter.eta($0) } ?? "" }
}

/// One unit of work in the download queue: a single media item (a playlist expands into many jobs).
public struct DownloadJob: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public var title: String
    public var uploader: String?
    public var thumbnailURL: URL?
    public var expectedDuration: TimeInterval?
    public var playlistTitle: String?
    public var playlistIndex: Int?
    public var playlistCount: Int?
    public var state: DownloadState
    public var progress: DownloadProgress?
    public var error: LocalMusicError?
    /// Raw yt-dlp/ffmpeg output, shown under "Technical Details".
    public var technicalLog: String
    public let createdAt: Date
    public var finishedAt: Date?
    public var resultFileURL: URL?
    public var resultTrackID: UUID?
    /// Set while the job waits for the user to resolve a duplicate.
    public var pendingDuplicate: DuplicateDetector.Match?
    /// Short outcome note shown instead of the plain state label (e.g. "Skipped — duplicate").
    public var note: String?

    public init(id: UUID = UUID(), sourceURL: URL, title: String, uploader: String? = nil,
                thumbnailURL: URL? = nil, expectedDuration: TimeInterval? = nil,
                playlistTitle: String? = nil, playlistIndex: Int? = nil, playlistCount: Int? = nil,
                state: DownloadState = .waiting, createdAt: Date = Date()) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
        self.expectedDuration = expectedDuration
        self.playlistTitle = playlistTitle
        self.playlistIndex = playlistIndex
        self.playlistCount = playlistCount
        self.state = state
        self.progress = nil
        self.error = nil
        self.technicalLog = ""
        self.createdAt = createdAt
    }

    public var statusText: String {
        if let pendingDuplicate {
            return "Looks like a duplicate of “\(pendingDuplicate.track.title)” (\(pendingDuplicate.summary))"
        }
        if let note, state.isTerminal { return note }
        switch state {
        case .failed: return error?.message ?? "Failed"
        case .downloading:
            guard let p = progress else { return "Starting…" }
            var parts: [String] = []
            if !p.percentText.isEmpty { parts.append(p.percentText) }
            if !p.sizeText.isEmpty { parts.append(p.sizeText) }
            if !p.speedText.isEmpty { parts.append(p.speedText) }
            if !p.etaText.isEmpty { parts.append("ETA \(p.etaText)") }
            return parts.isEmpty ? "Downloading" : parts.joined(separator: " · ")
        case .processing:
            if let phase = progress?.phase, phase != "download" { return "Processing (\(phase))" }
            return "Processing"
        default: return state.label
        }
    }
}
