import Foundation
import CryptoKit

/// Content-addressed artwork store under Application Support. Files are named by SHA-256 so
/// identical images are stored once.
public struct ArtworkCache: Sendable {
    public let directory: URL

    public init(directory: URL = AppPaths.artworkCacheDirectory) {
        self.directory = directory
    }

    /// Stores image bytes and returns the cache file name.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = hash + "." + Self.fileExtension(for: data)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    public func url(for fileName: String) -> URL? {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("..") else { return nil }
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "jpg"
    }
}
