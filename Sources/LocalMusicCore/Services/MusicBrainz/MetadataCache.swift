import Foundation
import CryptoKit

/// Disk cache for web lookups (MusicBrainz, Cover Art Archive, AcoustID). Entries expire after `ttl`.
public struct MetadataCache: Sendable {
    public let directory: URL
    public let ttl: TimeInterval

    public init(directory: URL = AppPaths.metadataCacheDirectory, ttl: TimeInterval = 30 * 24 * 3600) {
        self.directory = directory
        self.ttl = ttl
    }

    func url(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("cache")
    }

    public func get(_ key: String) -> Data? {
        let file = url(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl else { return nil }
        return try? Data(contentsOf: file)
    }

    public func set(_ key: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var entryCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".cache") }.count ?? 0
    }
}
