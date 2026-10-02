import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalMusicCore

/// Sheet for exporting one track as a still-image MP4 for YouTube: pick a photo, choose where
/// to save, and the render runs in the Downloads queue.
struct VideoExportView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let track: TrackRecord
    @State private var imageURL: URL?
    @State private var preview: NSImage?
    @State private var chapterCount = 0
    @State private var error: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Video").font(.title2.weight(.semibold))
            Text("Makes a \(VideoBuilder.width)×\(VideoBuilder.height) MP4 of “\(track.title)” with your photo fitted over a blurred copy of itself, plus a text file with timestamps for the YouTube description.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            dropZone

            HStack {
                Button("Choose Photo…") { choosePhoto() }
                Spacer()
                Text(chapterCount > 0 ? "\(chapterCount) chapters will be listed" : "No chapters; the description lists title and artist")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            if !env.ffmpegReady, env.toolsChecked {
                Label("ffmpeg is required to export videos (brew install ffmpeg).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }

            HStack {
                Text("H.264 video, AAC \(VideoBuilder.audioBitrateKbps) kbps audio, \(DurationFormatter.string(track.duration)).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageURL == nil || !env.ffmpegReady)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { chapterCount = await Self.chapterCount(of: track.fileURL) }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: preview == nil ? [6] : [])))
            if let preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).padding(8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Drop a photo here").foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 220)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in use(url) }
            }
            return true
        }
        .accessibilityLabel("Photo")
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the photo shown for the whole video."
        if panel.runModal() == .OK, let url = panel.url { use(url) }
    }

    private func use(_ url: URL) {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
            error = "“\(url.lastPathComponent)” is not a readable image."
            return
        }
        error = nil
        imageURL = url
        preview = image
    }

    private func export() {
        guard let imageURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = FilenameSanitizer.sanitize(track.title, fallback: "Video") + ".mp4"
        panel.message = "The description text file is saved next to the video."
        guard panel.runModal() == .OK, var output = panel.url else { return }
        if output.pathExtension.lowercased() != "mp4" { output = output.appendingPathExtension("mp4") }
        if env.downloads.submitVideoExport(track: track, image: imageURL, output: output) {
            env.selectedSidebar = .downloads
            dismiss()
        } else {
            error = env.downloads.submissionError?.message
            env.downloads.submissionError = nil
        }
    }

    static func chapterCount(of file: URL) async -> Int {
        guard file.pathExtension.lowercased() == "mp3" else { return 0 }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: file) else { return 0 }
            return ID3TagWriter.chapters(in: ID3TagWriter.parse(data).frames).count
        }.value
    }
}

// MARK: - Queue row

struct VideoRow: View {
    @Environment(AppEnvironment.self) private var env
    let job: VideoExportJob
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(job.title).font(.body.weight(.medium)).lineLimit(1)
                        Text("VIDEO").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                    Text(job.outputURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(job.statusText).font(.caption)
                        .foregroundStyle(job.state == .failed ? .red : .secondary).lineLimit(2)
                    if job.state.isActive {
                        ProgressView(value: job.fraction ?? 0).progressViewStyle(.linear).controlSize(.small)
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
            if job.state == .complete {
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.outputURL]) }
                Button("Copy Description") {
                    if let text = try? String(contentsOf: job.descriptionURL, encoding: .utf8) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }
    }

    private var thumbnail: some View {
        Group {
            if let image = NSImage(contentsOf: job.imageURL) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .frame(width: 78, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
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
            Button { NSWorkspace.shared.open(job.outputURL) } label: { Image(systemName: "play.rectangle.fill") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("Open in QuickTime")
            Button { NSWorkspace.shared.activateFileViewerSelecting([job.outputURL]) } label: { Image(systemName: "folder") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
        }
    }
}
