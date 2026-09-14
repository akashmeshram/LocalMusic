import Foundation
import Observation
import LocalMusicCore

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case songs, recentlyAdded, favorites, downloads

    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: "Songs"
        case .recentlyAdded: "Recently Added"
        case .favorites: "Favorites"
        case .downloads: "Downloads"
        }
    }
    var systemImage: String {
        switch self {
        case .songs: "music.note"
        case .recentlyAdded: "clock"
        case .favorites: "heart"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// Composition root. Owns long-lived services and hands them to views via `.environment`.
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let store: LibraryStore
    let artwork: ArtworkCache
    let playback: PlaybackService
    let useMockDownloader: Bool

    private(set) var tools: [Tool: ToolInfo] = [:]
    private(set) var isCheckingTools = false
    private(set) var toolsChecked = false
    var updateReport: ToolUpdateReport?
    var isCheckingUpdates = false
    var startupError: LocalMusicError?
    var selectedSidebar: SidebarItem? = .songs
    var focusURLFieldToken = 0

    private(set) var library: LibraryViewModel!
    private(set) var downloads: DownloadManager!

    init(settings: AppSettings, store: LibraryStore, artwork: ArtworkCache, useMockDownloader: Bool) {
        self.settings = settings
        self.store = store
        self.artwork = artwork
        self.useMockDownloader = useMockDownloader
        self.playback = PlaybackService(initialVolume: Float(settings.defaultVolume))
        self.library = LibraryViewModel(env: self)
        self.downloads = DownloadManager(env: self)
        wirePlayback()
    }

    static func live() -> AppEnvironment {
        let settings = AppSettings()
        var startupError: LocalMusicError?
        do {
            try AppPaths.ensureDirectories(musicRoot: settings.musicDirectory)
            AppPaths.cleanIncoming(musicRoot: settings.musicDirectory)
        } catch {
            startupError = LocalMusicError.wrap(error, message: "Could not create the music folder.")
        }
        let store: LibraryStore
        do {
            store = try LibraryStore(storeURL: AppPaths.databaseURL)
        } catch {
            startupError = LocalMusicError.wrap(error)
            store = (try? LibraryStore(storeURL: nil))!
        }
        let mock = ProcessInfo.processInfo.arguments.contains("--mock") || ProcessInfo.processInfo.environment["LOCALMUSIC_MOCK"] == "1"
        let env = AppEnvironment(settings: settings, store: store, artwork: ArtworkCache(), useMockDownloader: mock)
        env.startupError = startupError
        Log.info("LocalMusic started (mock=\(mock)) library=\(settings.musicDirectory.path)")
        return env
    }

    /// Preview/test container: in-memory store, mock downloader, temp music folder.
    static func preview() -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "preview-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.musicDirectoryPath = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMusicPreview").path
        try? AppPaths.ensureDirectories(musicRoot: settings.musicDirectory)
        let store = try! LibraryStore(storeURL: nil)
        return AppEnvironment(settings: settings, store: store, artwork: ArtworkCache(directory: settings.musicDirectory.appendingPathComponent(".artwork")), useMockDownloader: true)
    }

    // MARK: Tools

    var missingRequiredTools: [ToolInfo] {
        Tool.allCases.filter(\.isRequired).compactMap { tools[$0] }.filter { !$0.isUsable }
    }

    var ytdlpReady: Bool { tools[.ytDLP]?.isUsable == true || useMockDownloader }
    var ffmpegReady: Bool { tools[.ffmpeg]?.isUsable == true }
    var ffmpegDirectory: URL? { ffmpegReady ? tools[.ffmpeg]?.path?.deletingLastPathComponent() : nil }

    var ffmpegService: FFmpegService {
        FFmpegService(ffmpeg: ffmpegReady ? tools[.ffmpeg]?.path : nil,
                      ffprobe: tools[.ffprobe]?.isUsable == true ? tools[.ffprobe]?.path : nil)
    }

    var artworkService: ArtworkService { ArtworkService(cache: artwork) }
    var tagWriter: TagWriterService { TagWriterService(ffmpeg: ffmpegService) }
    let metadata = MetadataService()
    let metadataCache = MetadataCache()
    let musicBrainz = MusicBrainzService()
    var coverArt: CoverArtService { CoverArtService(cache: metadataCache, artwork: artworkService) }
    var identifier: RecordingIdentifier { RecordingIdentifier(musicBrainz: musicBrainz, acoustID: AcoustIDService(cache: metadataCache)) }
    var identifierOptions: RecordingIdentifier.Options {
        RecordingIdentifier.Options(minimumAutoConfidence: settings.minimumAutoMatchConfidence,
                                    preferEarliestRelease: settings.preferEarliestRelease,
                                    acoustIDKey: KeychainStore.get(KeychainStore.acoustIDAccount),
                                    fpcalc: tools[.fpcalc]?.isUsable == true ? tools[.fpcalc]?.path : nil)
    }

    func makeDownloader() -> (any MediaDownloading)? {
        if useMockDownloader { return MockDownloader() }
        guard let path = tools[.ytDLP]?.path, tools[.ytDLP]?.isUsable == true else { return nil }
        return YTDLPService(executable: path)
    }

    func refreshTools() async {
        isCheckingTools = true
        defer { isCheckingTools = false; toolsChecked = true }
        tools = await ToolLocator.detectAll(overrides: settings.toolOverrides)
        for info in tools.values.sorted(by: { $0.tool.rawValue < $1.tool.rawValue }) {
            switch info.status {
            case .ok: Log.info("\(info.tool.rawValue) \(info.version ?? "?") at \(info.path?.path ?? "?")", .tools)
            case .missing: Log.warning("\(info.tool.rawValue) not found", .tools)
            case .broken(let why): Log.error("\(info.tool.rawValue) at \(info.path?.path ?? "?") is broken: \(why)", .tools)
            }
        }
    }

    func checkForToolUpdates() async {
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        updateReport = await ToolLocator.checkForUpdates(tools: tools)
    }

    // MARK: Playback wiring

    private func wirePlayback() {
        playback.onTrackFinished = { [weak self] track in
            guard let self else { return }
            Task { await self.library.recordPlay(track) }
        }
        playback.onPositionChanged = { [weak self] track, position in
            guard let self, self.settings.rememberPlaybackPosition else { return }
            Task { try? await self.store.savePlaybackPosition(id: track.id, position: position) }
        }
        playback.artworkProvider = { [weak self] track in
            guard let self, let name = track.artworkFileName, let url = self.artwork.url(for: name) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: Log.logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Log.logsDirectory)
    }

    func revealLibraryFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([settings.musicDirectory])
    }
}

import AppKit
