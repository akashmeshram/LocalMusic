import Foundation

/// One song inside a mix while it is being fetched.
public struct MixItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public var title: String
    public var artist: String?
    public var state: DownloadState
    public var fraction: Double?
    public var errorMessage: String?

    public init(id: UUID = UUID(), sourceURL: URL, title: String, state: DownloadState = .waiting) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.state = state
    }
}

/// A queue entry that downloads several songs and joins them into a single MP3 with chapters
/// and a composite cover. Lives beside `DownloadJob` in the Downloads list.
public struct MixJob: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var crossfade: TimeInterval
    public var items: [MixItem]
    public var state: DownloadState
    /// Human-readable step shown under the title while the job runs.
    public var phase: String?
    public var error: LocalMusicError?
    public var technicalLog: String = ""
    public let createdAt: Date
    public var finishedAt: Date?
    public var resultFileURL: URL?
    public var resultTrackID: UUID?
    public var pendingDuplicate: DuplicateDetector.Match?
    public var note: String?

    public init(id: UUID = UUID(), name: String, urls: [URL], crossfade: TimeInterval, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.crossfade = crossfade
        self.items = urls.map { MixItem(sourceURL: $0, title: $0.host ?? $0.absoluteString) }
        self.state = .waiting
        self.createdAt = createdAt
    }

    public var completedItems: Int { items.filter { $0.state == .complete }.count }

    /// Overall progress: downloads share the first 80 %, building the rest.
    public var fraction: Double? {
        switch state {
        case .waiting: return nil
        case .downloading, .identifying:
            let perItem = items.map { $0.state == .complete ? 1 : ($0.fraction ?? 0) }
            let done = perItem.reduce(0, +) / Double(max(items.count, 1))
            return done * 0.8
        case .processing: return 0.85
        case .organizing: return 0.95
        case .complete: return 1
        case .failed, .cancelled: return nil
        }
    }

    public var statusText: String {
        if let pendingDuplicate {
            return "Looks like a duplicate of “\(pendingDuplicate.track.title)” (\(pendingDuplicate.summary))"
        }
        if let note, state.isTerminal { return note }
        switch state {
        case .failed: return error?.message ?? "Failed"
        case .downloading: return "Downloading \(completedItems + 1) of \(items.count)"
        case .processing: return phase ?? "Building mix"
        default: return phase ?? state.label
        }
    }
}
