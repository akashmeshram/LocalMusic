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
                    Text(job.statusText).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary).lineLimit(1)
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
        .contextMenu {
            if job.state.isTerminal {
                if job.state != .complete { Button("Retry") { env.downloads.retry(job.id) } }
                Button("Remove") { env.downloads.remove(job.id) }
            } else {
                Button("Cancel") { env.downloads.cancel(job.id) }
            }
            Divider()
            if let file = job.resultFileURL { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            if let id = job.resultTrackID, let track = env.library.trackByID[id] { Button("Play") { env.playback.play(track) } }
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
            HStack {
                Text("Install or repair with:").font(.caption)
                Text("brew install yt-dlp ffmpeg").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Re-check") { Task { await env.refreshTools() } }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.primary)
        .background(Color.orange.opacity(0.18))
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
    }
}
