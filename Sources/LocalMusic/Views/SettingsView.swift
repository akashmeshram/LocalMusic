import SwiftUI
import LocalMusicCore

struct SettingsView: View {
    var body: some View {
        TabView {
            DownloadSettingsView().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
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
                if let report = env.updateReport {
                    if report.outdated.isEmpty, report.message == nil {
                        Label("yt-dlp and ffmpeg are up to date (Homebrew).", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(report.outdated) { item in
                        Label("\(item.formula): \(item.installed) → \(item.latest). Run: brew upgrade \(item.formula)", systemImage: "arrow.up.circle")
                            .font(.caption).textSelection(.enabled)
                    }
                    if let message = report.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Maintenance") {
                HStack {
                    Button("Rebuild Library…") { confirmRebuild = true }
                    Button("Open Logs Folder") { env.openLogsFolder() }
                    Button("Reveal Music Folder") { env.revealLibraryFolder() }
                }
                Text("Rebuilding drops the index and rescans every file under the music folder. Play counts and favorites for files that still exist are preserved by path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Rebuild the library index?", isPresented: $confirmRebuild) {
            Button("Rebuild") { Task { await env.library.rebuild() } }
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
