import Foundation

/// A queue entry that renders one library track plus one still image into an MP4 for upload.
/// Lives beside `DownloadJob` and `MixJob` in the Downloads list; never touches the library.
public struct VideoExportJob: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let trackID: UUID
    public var title: String
    public var artist: String?
    public let imageURL: URL
    public let outputURL: URL
    public var state: DownloadState
    public var fraction: Double?
    public var error: LocalMusicError?
    public var technicalLog: String = ""
    public let createdAt: Date
    public var finishedAt: Date?
    public var note: String?

    public init(id: UUID = UUID(), trackID: UUID, title: String, artist: String?, imageURL: URL, outputURL: URL, createdAt: Date = Date()) {
        self.id = id
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.imageURL = imageURL
        self.outputURL = outputURL
        self.state = .waiting
        self.createdAt = createdAt
    }

    /// The YouTube description text file written beside the video.
    public var descriptionURL: URL { outputURL.deletingPathExtension().appendingPathExtension("txt") }

    public var statusText: String {
        if let note, state.isTerminal { return note }
        switch state {
        case .failed: return error?.message ?? "Failed"
        case .processing: return "Rendering \(Int((fraction ?? 0) * 100))%"
        case .organizing: return "Writing description"
        case .complete: return "Saved to \(outputURL.deletingLastPathComponent().path(percentEncoded: false))"
        default: return state.label
        }
    }
}
