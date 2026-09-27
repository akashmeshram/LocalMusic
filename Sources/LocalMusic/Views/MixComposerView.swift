import SwiftUI
import LocalMusicCore

/// Sheet for building a mix: a name, several links (one per line) and the crossfade length.
struct MixComposerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var links = ""
    @State private var crossfade: Double = 3
    @State private var error: String?

    private var linkCount: Int {
        links.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Mix").font(.title2.weight(.semibold))
            Text("Every link is downloaded, identified and joined into one MP3 with chapter markers. Songs from different albums get a combined cover.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("Mix name", text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)

            VStack(alignment: .leading, spacing: 4) {
                Text("Links (one per line, in play order)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $links)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Text(linkCount == 1 ? "1 link" : "\(linkCount) links").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Paste Links") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            links = links.isEmpty ? text : links + "\n" + text
                        }
                    }.controlSize(.small)
                }
            }

            HStack {
                Text("Crossfade")
                Slider(value: $crossfade, in: 0...12, step: 0.5)
                Text(crossfade == 0 ? "hard cut" : String(format: "%.1f s", crossfade))
                    .monospacedDigit().frame(width: 64, alignment: .trailing)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if !env.ffmpegReady, env.toolsChecked {
                Label("ffmpeg is required to build mixes (brew install ffmpeg).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }

            HStack {
                Text("Saved as MP3 (\(env.settings.mixBitrate) kbps) under \(DownloadManager.mixAlbum).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Mix") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || linkCount < 2 || !env.ffmpegReady || !env.ytdlpReady)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { crossfade = env.settings.mixCrossfade }
    }

    private func create() {
        error = nil
        if env.downloads.submitMix(name: name, links: links, crossfade: crossfade) {
            env.settings.mixCrossfade = crossfade
            dismiss()
        } else {
            error = env.downloads.submissionError?.message
            env.downloads.submissionError = nil
        }
    }
}

// MARK: - Queue row

struct MixRow: View {
    @Environment(AppEnvironment.self) private var env
    let mix: MixJob
    @State private var showDetails = false
    @State private var showSongs = true

    private var isRunning: Bool { mix.state.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mix.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("MIX").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                    Text("\(mix.items.count) songs · \(mix.crossfade == 0 ? "hard cuts" : String(format: "%.1f s crossfade", mix.crossfade))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(mix.statusText).font(.caption)
                        .foregroundStyle(mix.state == .failed ? .red : (mix.pendingDuplicate != nil ? .orange : .secondary)).lineLimit(2)
                    if let dup = mix.pendingDuplicate {
                        HStack(spacing: 8) {
                            Button("Skip") { env.downloads.resolveDuplicate(mix.id, .skip) }
                            Button("Keep Both") { env.downloads.resolveDuplicate(mix.id, .keepBoth) }
                            Button("Replace Existing") { env.downloads.resolveDuplicate(mix.id, .replace) }
                            Button("Show Existing") { env.library.reveal(dup.track) }
                        }
                        .controlSize(.small).padding(.top, 2)
                    }
                    if isRunning {
                        ProgressView(value: mix.fraction).progressViewStyle(.linear).controlSize(.small)
                    }
                }
                Spacer()
                StateBadge(state: mix.state)
                actions
            }
            DisclosureGroup("Songs", isExpanded: $showSongs) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(mix.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                            Text((item.artist.map { "\($0) – " } ?? "") + item.title).lineLimit(1)
                            Spacer()
                            if let message = item.errorMessage { Text(message).foregroundStyle(.red).lineLimit(1) }
                            if item.state == .downloading, let f = item.fraction {
                                ProgressView(value: f).progressViewStyle(.linear).controlSize(.mini).frame(width: 80)
                            }
                            Text(item.state.label).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
            .font(.caption)
            if mix.state == .failed || (!mix.technicalLog.isEmpty && mix.state.isTerminal) {
                DisclosureGroup("Technical Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(mix.technicalLog.isEmpty ? (mix.error?.technicalDetails ?? "No output captured.") : mix.technicalLog)
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
            if mix.state.isTerminal {
                if mix.state != .complete { Button("Retry") { env.downloads.retry(mix.id) } }
                Button("Remove") { env.downloads.remove(mix.id) }
            } else {
                Button("Cancel") { env.downloads.cancel(mix.id) }
            }
            Divider()
            if let file = mix.resultFileURL { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            if let id = mix.resultTrackID, let track = env.library.trackByID[id] {
                Button("Play") { env.playback.play(track) }
            }
            Button("Copy Links") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(mix.items.map(\.sourceURL.absoluteString).joined(separator: "\n"), forType: .string)
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let id = mix.resultTrackID, let track = env.library.trackByID[id], track.artworkFileName != nil {
            ArtworkView(url: env.artworkURL(track.artworkFileName), size: 44)
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 44, height: 44)
                .overlay(Image(systemName: "square.stack.3d.down.right").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch mix.state {
        case .waiting, .downloading, .processing, .identifying, .organizing:
            Button { env.downloads.cancel(mix.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        case .failed, .cancelled:
            Button { env.downloads.retry(mix.id) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Retry")
            Button { env.downloads.remove(mix.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
        case .complete:
            if let id = mix.resultTrackID, let track = env.library.trackByID[id] {
                Button { env.playback.play(track) } label: { Image(systemName: "play.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("Play")
            }
            if let file = mix.resultFileURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            }
        }
    }
}
