import SwiftUI
import UniformTypeIdentifiers
import LocalMusicCore

/// Sheet for editing a track's tags and artwork. Changes are written into the audio file.
struct MetadataEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let track: TrackRecord

    @State private var tags: TrackTags
    @State private var artworkPreview: NSImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isDropTargeted = false

    init(track: TrackRecord) {
        self.track = track
        _tags = State(initialValue: TrackTags(record: track))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                artworkWell
                Form {
                    TextField("Title", text: $tags.title)
                    TextField("Artist", text: optional($tags.artist))
                    TextField("Album Artist", text: optional($tags.albumArtist))
                    TextField("Album", text: optional($tags.album))
                    HStack {
                        TextField("Track #", value: $tags.trackNumber, format: .number).frame(width: 90)
                        TextField("of", value: $tags.trackTotal, format: .number).frame(width: 90)
                        TextField("Disc #", value: $tags.discNumber, format: .number).frame(width: 90)
                        TextField("Year", value: $tags.year, format: .number.grouping(.never)).frame(width: 90)
                    }
                    TextField("Genre", text: optional($tags.genre))
                    TextField("Composer", text: optional($tags.composer))
                    TextField("Comment", text: optional($tags.comment))
                }
                .formStyle(.columns)
                .textFieldStyle(.roundedBorder)
            }
            .padding(20)

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.fileURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if env.settings.autoOrganize {
                        Text("Will be filed as: \(previewPath)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || tags.title.trimmingCharacters(in: .whitespaces).isEmpty || !env.tagWriter.canWrite(fileExtension: track.fileURL.pathExtension))
            }
            .padding(14)
        }
        .frame(width: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadCurrentArtwork() }
    }

    private var previewPath: String {
        FileOrganizer(root: env.settings.musicDirectory, folderTemplate: env.settings.folderTemplate, filenameTemplate: env.settings.filenameTemplate)
            .relativePath(for: tags.normalized.organizeMetadata, fileExtension: track.fileURL.pathExtension)
    }

    private var artworkWell: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let artworkPreview {
                    Image(nsImage: artworkPreview).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Drop an image").font(.caption).foregroundStyle(.secondary)
                    }
                }
                RoundedRectangle(cornerRadius: 8).strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            }
            .frame(width: 180, height: 180)
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in handleDrop(providers) }
            HStack {
                Button("Replace…") { chooseImage() }
                Button("Remove") { tags.artwork = .remove; artworkPreview = nil }
                    .disabled(artworkPreview == nil)
            }
            .controlSize(.small)
            if !env.tagWriter.canWrite(fileExtension: track.fileURL.pathExtension) {
                Text("Tags can't be written to .\(track.fileURL.pathExtension) files without ffmpeg.").font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func loadCurrentArtwork() {
        if let name = track.artworkFileName, let url = env.artwork.url(for: name) {
            artworkPreview = NSImage(contentsOf: url)
        }
    }

    private func setArtwork(_ data: Data) {
        let normalized = env.artworkService.normalized(data)
        guard let image = NSImage(data: normalized) else { errorMessage = "That file is not an image."; return }
        tags.artwork = .replace(normalized)
        artworkPreview = image
        errorMessage = nil
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) { setArtwork(data) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { @Sendable item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      let bytes = try? Data(contentsOf: url) else { return }
                Task { @MainActor in setArtwork(bytes) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { @Sendable data, _ in
                guard let data else { return }
                Task { @MainActor in setArtwork(data) }
            }
            return true
        }
        return false
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await env.library.save(tags: tags, for: track)
                dismiss()
            } catch {
                errorMessage = LocalMusicError.wrap(error).message
            }
            isSaving = false
        }
    }
}
