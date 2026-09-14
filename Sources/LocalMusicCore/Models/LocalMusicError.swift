import Foundation

/// A user-presentable error with an optional technical payload (raw tool output, paths, exit codes).
public struct LocalMusicError: Error, Hashable, Sendable, LocalizedError {
    public enum Kind: String, Hashable, Sendable, Codable {
        case malformedURL
        case unsupportedURL
        case videoUnavailable
        case privateVideo
        case geoRestricted
        case loginRequired
        case network
        case toolMissing
        case toolFailed
        case invalidAudio
        case permissionDenied
        case lowDiskSpace
        case cancelled
        case alreadyDownloaded
        case pathEscapesLibrary
        case fileExists
        case database
        case unknown
    }

    public let kind: Kind
    public let message: String
    public let technicalDetails: String?

    public init(kind: Kind, message: String, technicalDetails: String? = nil) {
        self.kind = kind
        self.message = message
        self.technicalDetails = technicalDetails
    }

    public var errorDescription: String? { message }

    public static let cancelled = LocalMusicError(kind: .cancelled, message: "Cancelled.")

    /// Wraps an arbitrary error, keeping the original description as technical details.
    public static func wrap(_ error: Error, message: String? = nil) -> LocalMusicError {
        if let e = error as? LocalMusicError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        let kind: Kind
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError): kind = .lowDiskSpace
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSCocoaErrorDomain, NSFileReadNoPermissionError): kind = .permissionDenied
        case (NSCocoaErrorDomain, NSFileWriteFileExistsError): kind = .fileExists
        case (NSURLErrorDomain, _): kind = .network
        default: kind = .unknown
        }
        return LocalMusicError(kind: kind, message: message ?? ns.localizedDescription, technicalDetails: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}
