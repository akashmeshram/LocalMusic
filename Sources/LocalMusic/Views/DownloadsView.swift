import SwiftUI
import LocalMusicCore

struct DownloadsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var urlText = ""
    @FocusState private var urlFieldFocused: Bool

    private var downloads: DownloadManager { env.downloads }

    var body: some View {
        @Bindable var downloads = env.downloads
        VStack(spacing: 0) {
            urlBar
            Divider()
            if !env.missingRequiredTools.isEmpty, env.toolsChecked { DependencyBanner() }
            if downloads.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Paste a video or playlist link above. Finished tracks are filed under \(env.settings.musicDirectory.path).")
                }
            } else {
                List {
                    ForEach(downloads.jobs) { job in
                        DownloadRow(job: job)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Downloads")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                if downloads.waitingJobs.count > 0 && !env.settings.autoStartDownloads {
                    Button { downloads.startAll() } label: { Label("Start", systemImage: "play.fill") }
                }
                Button { downloads.clearFinished() } label: { Label("Clear Finished", systemImage: "xmark.circle") }
                    .disabled(!downloads.jobs.contains { $0.state.isTerminal })
            }
        }
        .sheet(item: $downloads.pendingPlaylist) { playlist in
            PlaylistPreviewSheet(playlist: playlist)
        }
        .alert("Can't download", isPresented: Binding(get: { downloads.submissionError != nil }, set: { if !$0 { downloads.submissionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(downloads.submissionError?.message ?? "")
        }
        .onChange(of: env.focusURLFieldToken) { urlFieldFocused = true }
        .onAppear { urlFieldFocused = true }
    }

    private var subtitle: String {
        let active = downloads.activeJobs.count, waiting = downloads.waitingJobs.count
        if active == 0 && waiting == 0 { return "\(downloads.jobs.count) items" }
        return "\(active) active · \(waiting) waiting"
    }

    private var urlBar: some View {
        HStack(spacing: 10) {
            TextField("Paste a video or playlist URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($urlFieldFocused)
                .onSubmit(submit)
                .disabled(downloads.isProbing)
            if downloads.isProbing {
                ProgressView().controlSize(.small)
            }
            Button("Download", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || downloads.isProbing || !env.ytdlpReady)
            Button("Paste & Download") {
                if let text = NSPasteboard.general.string(forType: .string) {
                    urlText = text
                    submit()
                }
            }
            .disabled(downloads.isProbing || !env.ytdlpReady)
        }
        .padding(12)
        .background(.bar)
    }

    private func submit() {
        let text = urlText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await downloads.submit(text)
            if downloads.submissionError == nil { urlText = "" }
        }
    }
}

// MARK: - Row

struct DownloadRow: View {
    @Environment(AppEnvironment.self) private var env
    let job: DownloadJob
    @State private var showDetails = false
    @State private var editingTrack: TrackRecord?
    @State private var pickingTrack: TrackRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                RemoteThumbnail(url: job.thumbnailURL, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(job.title).font(.body.weight(.medium)).lineLimit(1)
                        if let index = job.playlistIndex, let count = job.playlistCount {
                            Text("\(index)/\(count)").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if let uploader = job.uploader { Text(uploader).lineLimit(1) }
                        if let pt = job.playlistTitle { Text("· \(pt)").lineLimit(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(job.statusText).font(.caption).foregroundStyle(job.state == .failed ? .red : (job.pendingDuplicate != nil ? .orange : .secondary)).lineLimit(2)
                    if !job.candidates.isEmpty, job.state == .complete, let id = job.resultTrackID, let track = env.library.trackByID[id] {
                        Button("Choose Match…") { pickingTrack = track }.controlSize(.small).padding(.top, 2)
                    }
                    if let dup = job.pendingDuplicate {
                        HStack(spacing: 8) {
                            Button("Skip") { env.downloads.resolveDuplicate(job.id, .skip) }
                            Button("Keep Both") { env.downloads.resolveDuplicate(job.id, .keepBoth) }
                            Button("Replace Existing") { env.downloads.resolveDuplicate(job.id, .replace) }
                            Button("Show Existing") { env.library.reveal(dup.track) }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    if job.state == .downloading || job.state == .processing || job.state == .identifying || job.state == .organizing {
                        ProgressView(value: job.state == .downloading ? job.progress?.fraction : nil)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }
                Spacer()
                StateBadge(state: job.state)
                actions
            }
            if job.state == .failed || (!job.technicalLog.isEmpty && job.state.isTerminal) {
                DisclosureGroup("Technical Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(job.technicalLog.isEmpty ? (job.error?.technicalDetails ?? "No output captured.") : job.technicalLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .sheet(item: $editingTrack) { MetadataEditorView(track: $0) }
        .sheet(item: $pickingTrack) { track in
            MatchPickerView(track: track, initialCandidates: job.candidates) { env.downloads.clearCandidates(job.id) }
        }
        .contextMenu {
            if job.state.isTerminal {
                if job.state != .complete { Button("Retry") { env.downloads.retry(job.id) } }
                Button("Remove") { env.downloads.remove(job.id) }
            } else {
                Button("Cancel") { env.downloads.cancel(job.id) }
            }
            Divider()
            if let file = job.resultFileURL { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            if let id = job.resultTrackID, let track = env.library.trackByID[id] {
                Button("Play") { env.playback.play(track) }
                Button("Edit Metadata…") { editingTrack = track }
                Button("Re-identify Metadata…") { pickingTrack = track }
            }
            Button("Copy Source URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.sourceURL.absoluteString, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .waiting, .downloading, .processing, .identifying, .organizing:
            Button { env.downloads.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        case .failed, .cancelled:
            Button { env.downloads.retry(job.id) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Retry")
            Button { env.downloads.remove(job.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
        case .complete:
            if let id = job.resultTrackID, let track = env.library.trackByID[id] {
                Button { env.playback.play(track) } label: { Image(systemName: "play.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("Play")
            }
            if let file = job.resultFileURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            }
        }
    }
}

struct StateBadge: View {
    let state: DownloadState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .waiting: .secondary
        case .downloading: .blue
        case .processing, .identifying, .organizing: .purple
        case .complete: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

// MARK: - Dependency banner

struct DependencyBanner: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Required tools are missing or broken", systemImage: "exclamationmark.triangle.fill").font(.callout.weight(.semibold))
            ForEach(env.missingRequiredTools) { info in
                HStack(spacing: 6) {
                    Text(info.tool.rawValue).font(.system(.caption, design: .monospaced)).frame(width: 60, alignment: .leading)
                    switch info.status {
                    case .missing:
                        Text("not found").font(.caption)
                    case .broken(let why):
                        Text("installed at \(info.path?.path ?? "?") but fails to run — \(Self.firstLine(why))")
                            .font(.caption).lineLimit(1).truncationMode(.tail).help(why)
                    case .ok: EmptyView()
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Install or repair with:").font(.caption)
                Text("brew install yt-dlp ffmpeg").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install yt-dlp ffmpeg", forType: .string) }.controlSize(.small)
                Spacer()
                if env.tools[.ytDLP]?.isUsable != true {
                    YTDLPInstallButton(confirm: $confirmInstall)
                }
                Button("Re-check") { Task { await env.refreshTools() } }.controlSize(.small)
            }
            if let error = env.ytdlpInstallError { Text(error.message).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.primary)
        .background(Color.orange.opacity(0.18).background(Color(nsColor: .windowBackgroundColor)))
        .overlay(alignment: .bottom) { Divider() }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        // dyld errors: keep only the "Library not loaded: …" part.
        if let range = line.range(of: "Library not loaded:") {
            return String(line[range.lowerBound...].prefix(120))
        }
        return String(line.prefix(120))
    }
}

// MARK: - Playlist preview

extension PlaylistInfo: @retroactive Identifiable {
    public var id: String { url.absoluteString }
}

struct PlaylistPreviewSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let playlist: PlaylistInfo
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    if let up = playlist.uploader { Text(up) }
                    Text("\(playlist.entries.count) tracks")
                    Text("· \(selected.count) selected")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            List {
                ForEach(playlist.entries) { entry in
                    Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { on in if on { selected.insert(entry.id) } else { selected.remove(entry.id) } })) {
                        HStack {
                            Text("\(entry.playlistIndex ?? 0).").foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                            VStack(alignment: .leading) {
                                Text(entry.title).lineLimit(1)
                                if let up = entry.uploader { Text(up).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let d = entry.duration { Text(DurationFormatter.string(d)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Divider()
            HStack {
                Button("Select All") { selected = Set(playlist.entries.map(\.id)) }
                Button("Select None") { selected = [] }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(selected.count) to Queue") {
                    let entries = playlist.entries.filter { selected.contains($0.id) }
                    env.downloads.enqueue(entries, playlist: playlist)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
        .onAppear { selected = Set(playlist.entries.map(\.id)) }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}


/// "Download yt-dlp" with an explicit confirmation; shows progress while installing.
struct YTDLPInstallButton: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var confirm: Bool
    var title: String = "Download yt-dlp…"

    var body: some View {
        Group {
            if let stage = env.ytdlpInstallStage {
                HStack(spacing: 6) {
                    ProgressView(value: progressValue(stage)).progressViewStyle(.linear).frame(width: 90).controlSize(.small)
                    Text(label(stage)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(title) { confirm = true }.controlSize(.small)
            }
        }
        .confirmationDialog("Download the official yt-dlp build?", isPresented: $confirm) {
            Button("Download (\(ToolInstaller.approximateSize))") { Task { await env.installYTDLP() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LocalMusic will fetch yt-dlp_macos from github.com/yt-dlp, verify its published SHA-256 checksum, and keep it in ~/Library/Application Support/LocalMusic/bin. Nothing else on your system is touched. ffmpeg still needs Homebrew.")
        }
    }

    private func progressValue(_ stage: ToolInstaller.Stage) -> Double? {
        switch stage {
        case .fetchingChecksum: 0
        case .downloading(let f): f
        case .verifying: 0.95
        case .done: 1
        }
    }

    private func label(_ stage: ToolInstaller.Stage) -> String {
        switch stage {
        case .fetchingChecksum: "Checking release…"
        case .downloading(let f): f.map { String(format: "Downloading %.0f%%", $0 * 100) } ?? "Downloading…"
        case .verifying: "Verifying…"
        case .done: "Installed"
        }
    }
}
