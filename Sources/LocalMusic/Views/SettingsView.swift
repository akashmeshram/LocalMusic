import SwiftUI
import LocalMusicCore

struct SettingsView: View {
    var body: some View {
        TabView {
            DownloadSettingsView().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            MetadataSettingsView().tabItem { Label("Metadata", systemImage: "tag") }
            OrganizationSettingsView().tabItem { Label("Organization", systemImage: "folder") }
            PlaybackSettingsView().tabItem { Label("Playback", systemImage: "play.circle") }
            AdvancedSettingsView().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560)
    }
}

struct DownloadSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            LabeledContent("Music folder") {
                HStack {
                    Text(settings.musicDirectoryPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Choose…") { chooseFolder() }
                    Button("Reset") { settings.musicDirectoryPath = AppPaths.defaultMusicDirectory.path }
                }
            }
            Picker("Preferred format", selection: $settings.preferredFormat) {
                ForEach(PreferredFormat.allCases) { Text($0.label).tag($0) }
            }
            Text("“Original” keeps the source stream (M4A/AAC when available). Only Opus/WebM sources are converted, because macOS cannot play them natively.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Simultaneous downloads: \(settings.maxConcurrentDownloads)", value: $settings.maxConcurrentDownloads, in: 1...5)
            Toggle("Start queued downloads automatically", isOn: $settings.autoStartDownloads)
            Picker("When a download looks like a duplicate", selection: $settings.duplicatePolicy) {
                ForEach(DuplicatePolicy.allCases) { Text($0.label).tag($0) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = env.settings.musicDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            env.settings.musicDirectoryPath = url.path
            try? AppPaths.ensureDirectories(musicRoot: url)
            Task { await env.library.rebuild() }
        }
    }
}

struct MetadataSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var acoustIDKey: String = KeychainStore.get(KeychainStore.acoustIDAccount) ?? ""
    @State private var keySaved = false

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("MusicBrainz") {
                Toggle("Identify downloads with MusicBrainz automatically", isOn: $settings.autoQueryMusicBrainz)
                LabeledContent("Minimum confidence to apply a match automatically") {
                    HStack {
                        Slider(value: $settings.minimumAutoMatchConfidence, in: 0.5...0.99, step: 0.01).frame(width: 180)
                        Text(String(format: "%.0f%%", settings.minimumAutoMatchConfidence * 100)).monospacedDigit().frame(width: 40)
                    }
                }
                Toggle("Prefer the original (earliest) release", isOn: $settings.preferEarliestRelease)
                Toggle("Replace video thumbnails with album artwork when a release is matched", isOn: $settings.replaceThumbnailsWithAlbumArt)
                Text("Requests are limited to one per second, cached locally for 30 days, and sent with the app's own User-Agent. Matches below the threshold are offered for manual selection; nothing is invented.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AcoustID fingerprinting (optional)") {
                LabeledContent("fpcalc") {
                    if env.tools[.fpcalc]?.isUsable == true { Text("installed \(env.tools[.fpcalc]?.version ?? "")").font(.caption) }
                    else { Text("not installed — brew install chromaprint").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    SecureField("AcoustID API key", text: $acoustIDKey)
                    Button(keySaved ? "Saved" : "Save to Keychain") {
                        keySaved = KeychainStore.set(acoustIDKey, account: KeychainStore.acoustIDAccount)
                    }
                }
                Text("Used only when title/artist matching is inconclusive. The key is stored in the macOS Keychain and never written to logs. Get one at acoustid.org/new-application.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct OrganizationSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Toggle("Automatically organize completed tracks", isOn: $settings.autoOrganize)
            TextField("Folder template", text: $settings.folderTemplate)
            TextField("Filename template", text: $settings.filenameTemplate)
            Text("Placeholders: {AlbumArtist} {Artist} {Album} {Year} {Track} {Disc} {Title} {Genre}. Singles go to Artist/Singles; unidentified tracks to Unknown Artist/Unknown Album.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Example") {
                Text(FileOrganizer(root: env.settings.musicDirectory, folderTemplate: settings.folderTemplate, filenameTemplate: settings.filenameTemplate)
                    .relativePath(for: OrganizeMetadata(title: "Give Life Back to Music", artist: "Daft Punk", album: "Random Access Memories", year: 2013, trackNumber: 1), fileExtension: "m4a"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Button("Reset Templates") {
                    settings.folderTemplate = AppSettings.defaultFolderTemplate
                    settings.filenameTemplate = AppSettings.defaultFilenameTemplate
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PlaybackSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Toggle("Remember playback position", isOn: $settings.rememberPlaybackPosition)
            Slider(value: $settings.defaultVolume, in: 0...1) { Text("Default volume") }
            Text("Media keys and the system Now Playing controls work while LocalMusic is the active audio app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmRebuild = false
    @State private var cacheCleared = false
    @State private var confirmInstall = false
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("Command-line tools") {
                ForEach(Tool.allCases) { tool in
                    ToolRow(tool: tool, info: env.tools[tool])
                }
                TextField("yt-dlp path (blank = auto-detect)", text: $settings.ytdlpPath)
                TextField("ffmpeg path (blank = auto-detect)", text: $settings.ffmpegPath)
                TextField("ffprobe path (blank = auto-detect)", text: $settings.ffprobePath)
                HStack {
                    Button("Re-detect Tools") { Task { await env.refreshTools() } }.disabled(env.isCheckingTools)
                    Button("Check for Tool Updates") { Task { await env.checkForToolUpdates() } }.disabled(env.isCheckingUpdates)
                    if env.isCheckingUpdates { ProgressView().controlSize(.small) }
                }
                HStack {
                    YTDLPInstallButton(confirm: $confirmInstall, title: env.ytdlpIsAppManaged ? "Update yt-dlp…" : (ToolInstaller.isInstalled ? "Re-download yt-dlp…" : "Download yt-dlp (no Homebrew needed)…"))
                    if ToolInstaller.isInstalled {
                        Button("Remove app-managed yt-dlp") { confirmRemove = true }.controlSize(.small)
                    }
                }
                if let error = env.ytdlpInstallError { Text(error.message).font(.caption).foregroundStyle(.red) }
                Text("The app can fetch the official standalone yt-dlp build into its own Application Support folder (checksum-verified). ffmpeg and ffprobe must come from Homebrew: brew install ffmpeg")
                    .font(.caption).foregroundStyle(.secondary)
                if let report = env.updateReport {
                    if report.outdated.isEmpty, report.message == nil {
                        Label("yt-dlp and ffmpeg are up to date.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(report.outdated) { item in
                        Label("\(item.formula) \(item.installed) → \(item.latest). Update with: \(item.remedy)", systemImage: "arrow.up.circle")
                            .font(.caption).textSelection(.enabled)
                    }
                    if let message = report.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Maintenance") {
                HStack {
                    Button("Rebuild Library…") { confirmRebuild = true }
                    Button("Clear Metadata Cache") { try? env.metadataCache.clear(); cacheCleared = true }
                    Button("Open Logs Folder") { env.openLogsFolder() }
                    Button("Reveal Music Folder") { env.revealLibraryFolder() }
                }
                if cacheCleared { Text("Metadata cache cleared.").font(.caption).foregroundStyle(.secondary) }
                Text("Rebuilding drops the index and rescans every file under the music folder. Play counts and favorites for files that still exist are preserved by path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Rebuild the library index?", isPresented: $confirmRebuild) {
            Button("Rebuild") { Task { await env.library.rebuild() } }
        }
        .confirmationDialog("Remove the yt-dlp that LocalMusic downloaded?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                try? ToolInstaller().removeYTDLP()
                if settings.ytdlpPath == ToolInstaller.ytdlpURL.path { settings.ytdlpPath = "" }
                Task { await env.refreshTools() }
            }
        }
    }
}

struct ToolRow: View {
    let tool: Tool
    let info: ToolInfo?

    var body: some View {
        LabeledContent(tool.rawValue) {
            HStack(spacing: 6) {
                switch info?.status {
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(info?.version ?? "").monospacedDigit()
                    Text(info?.path?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .missing:
                    Image(systemName: tool.isRequired ? "xmark.circle.fill" : "minus.circle").foregroundStyle(tool.isRequired ? .red : .secondary)
                    Text(tool.isRequired ? "not found — brew install \(tool.homebrewFormula)" : "optional, not installed").font(.caption).foregroundStyle(.secondary)
                case .broken(let why):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("fails to run: \(why)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case nil:
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }
}
