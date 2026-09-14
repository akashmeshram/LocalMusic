import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`. Observable so SwiftUI can bind directly.
/// Secrets (AcoustID key) are *not* stored here; see `KeychainStore`.
@MainActor
@Observable
public final class AppSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        musicDirectoryPath = defaults.string(forKey: Key.musicDirectory) ?? AppPaths.defaultMusicDirectory.path
        preferredFormat = PreferredFormat(rawValue: defaults.string(forKey: Key.preferredFormat) ?? "") ?? .original
        maxConcurrentDownloads = max(1, min(defaults.object(forKey: Key.maxConcurrent) as? Int ?? 1, 5))
        autoStartDownloads = defaults.object(forKey: Key.autoStart) as? Bool ?? true
        autoQueryMusicBrainz = defaults.object(forKey: Key.autoQueryMB) as? Bool ?? true
        minimumAutoMatchConfidence = defaults.object(forKey: Key.minConfidence) as? Double ?? 0.85
        preferEarliestRelease = defaults.object(forKey: Key.preferEarliest) as? Bool ?? true
        replaceThumbnailsWithAlbumArt = defaults.object(forKey: Key.replaceThumbs) as? Bool ?? true
        folderTemplate = defaults.string(forKey: Key.folderTemplate) ?? Self.defaultFolderTemplate
        filenameTemplate = defaults.string(forKey: Key.filenameTemplate) ?? Self.defaultFilenameTemplate
        autoOrganize = defaults.object(forKey: Key.autoOrganize) as? Bool ?? true
        rememberPlaybackPosition = defaults.object(forKey: Key.rememberPosition) as? Bool ?? true
        defaultVolume = defaults.object(forKey: Key.defaultVolume) as? Double ?? 0.8
        ytdlpPath = defaults.string(forKey: Key.ytdlpPath) ?? ""
        ffmpegPath = defaults.string(forKey: Key.ffmpegPath) ?? ""
        ffprobePath = defaults.string(forKey: Key.ffprobePath) ?? ""
        fpcalcPath = defaults.string(forKey: Key.fpcalcPath) ?? ""
    }

    public nonisolated static let defaultFolderTemplate = "{AlbumArtist}/{Year} - {Album}"
    public nonisolated static let defaultFilenameTemplate = "{Track} - {Title}"

    // MARK: Downloads
    public var musicDirectoryPath: String { didSet { defaults.set(musicDirectoryPath, forKey: Key.musicDirectory) } }
    public var preferredFormat: PreferredFormat { didSet { defaults.set(preferredFormat.rawValue, forKey: Key.preferredFormat) } }
    public var maxConcurrentDownloads: Int { didSet { defaults.set(maxConcurrentDownloads, forKey: Key.maxConcurrent) } }
    public var autoStartDownloads: Bool { didSet { defaults.set(autoStartDownloads, forKey: Key.autoStart) } }

    // MARK: Metadata
    public var autoQueryMusicBrainz: Bool { didSet { defaults.set(autoQueryMusicBrainz, forKey: Key.autoQueryMB) } }
    public var minimumAutoMatchConfidence: Double { didSet { defaults.set(minimumAutoMatchConfidence, forKey: Key.minConfidence) } }
    public var preferEarliestRelease: Bool { didSet { defaults.set(preferEarliestRelease, forKey: Key.preferEarliest) } }
    public var replaceThumbnailsWithAlbumArt: Bool { didSet { defaults.set(replaceThumbnailsWithAlbumArt, forKey: Key.replaceThumbs) } }

    // MARK: Organization
    public var folderTemplate: String { didSet { defaults.set(folderTemplate, forKey: Key.folderTemplate) } }
    public var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: Key.filenameTemplate) } }
    public var autoOrganize: Bool { didSet { defaults.set(autoOrganize, forKey: Key.autoOrganize) } }

    // MARK: Playback
    public var rememberPlaybackPosition: Bool { didSet { defaults.set(rememberPlaybackPosition, forKey: Key.rememberPosition) } }
    public var defaultVolume: Double { didSet { defaults.set(defaultVolume, forKey: Key.defaultVolume) } }

    // MARK: Advanced (empty string = auto-detect)
    public var ytdlpPath: String { didSet { defaults.set(ytdlpPath, forKey: Key.ytdlpPath) } }
    public var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: Key.ffmpegPath) } }
    public var ffprobePath: String { didSet { defaults.set(ffprobePath, forKey: Key.ffprobePath) } }
    public var fpcalcPath: String { didSet { defaults.set(fpcalcPath, forKey: Key.fpcalcPath) } }

    public var musicDirectory: URL {
        URL(fileURLWithPath: (musicDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var toolOverrides: [Tool: String] {
        var map: [Tool: String] = [:]
        if !ytdlpPath.isEmpty { map[.ytDLP] = ytdlpPath }
        if !ffmpegPath.isEmpty { map[.ffmpeg] = ffmpegPath }
        if !ffprobePath.isEmpty { map[.ffprobe] = ffprobePath }
        if !fpcalcPath.isEmpty { map[.fpcalc] = fpcalcPath }
        return map
    }

    private enum Key {
        static let musicDirectory = "downloads.musicDirectory"
        static let preferredFormat = "downloads.preferredFormat"
        static let maxConcurrent = "downloads.maxConcurrent"
        static let autoStart = "downloads.autoStart"
        static let autoQueryMB = "metadata.autoQueryMusicBrainz"
        static let minConfidence = "metadata.minimumAutoMatchConfidence"
        static let preferEarliest = "metadata.preferEarliestRelease"
        static let replaceThumbs = "metadata.replaceThumbnailsWithAlbumArt"
        static let folderTemplate = "organization.folderTemplate"
        static let filenameTemplate = "organization.filenameTemplate"
        static let autoOrganize = "organization.autoOrganize"
        static let rememberPosition = "playback.rememberPosition"
        static let defaultVolume = "playback.defaultVolume"
        static let ytdlpPath = "advanced.ytdlpPath"
        static let ffmpegPath = "advanced.ffmpegPath"
        static let ffprobePath = "advanced.ffprobePath"
        static let fpcalcPath = "advanced.fpcalcPath"
    }
}
