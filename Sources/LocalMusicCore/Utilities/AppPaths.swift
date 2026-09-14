import Foundation

/// Well-known locations used by the app. All are per-user and local.
public enum AppPaths {
    public static let defaultMusicDirectory: URL = {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMusic", isDirectory: true)
    }()

    public static let applicationSupport: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalMusic", isDirectory: true)
    }()

    public static var databaseURL: URL { applicationSupport.appendingPathComponent("Library.sqlite") }
    public static var downloadArchiveURL: URL { applicationSupport.appendingPathComponent("download-archive.txt") }
    public static var artworkCacheDirectory: URL { applicationSupport.appendingPathComponent("Artwork", isDirectory: true) }
    public static var metadataCacheDirectory: URL { applicationSupport.appendingPathComponent("MetadataCache", isDirectory: true) }

    public static func incomingDirectory(musicRoot: URL) -> URL {
        musicRoot.appendingPathComponent(".incoming", isDirectory: true)
    }

    /// Creates the directory tree the app needs. Safe to call repeatedly.
    public static func ensureDirectories(musicRoot: URL) throws {
        let fm = FileManager.default
        for dir in [musicRoot, incomingDirectory(musicRoot: musicRoot), applicationSupport, artworkCacheDirectory, metadataCacheDirectory, Log.logsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Free space on the volume containing `url`, in bytes, or nil when it cannot be determined.
    public static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
