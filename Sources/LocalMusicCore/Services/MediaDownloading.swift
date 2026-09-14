import Foundation

/// Abstraction over the download engine so the UI can be developed with `MockDownloader`.
public protocol MediaDownloading: Sendable {
    /// Inspects a URL without downloading: single item or playlist with entries.
    func probe(url: URL) async throws -> MediaProbe

    /// Downloads one item into `request.destinationDirectory`. Progress and raw log lines are
    /// delivered as they happen. Cancelling the calling task aborts the download.
    func download(
        _ request: DownloadRequest,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadResult
}
