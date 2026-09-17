import SwiftUI
import UniformTypeIdentifiers
import LocalMusicCore

struct PlaylistView: View {
    @Environment(AppEnvironment.self) private var env
    let playlistID: UUID
    @State private var selection = Set<Int>()
    @State private var editing: TrackRecord?
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isTargeted = false
    @State private var message: String?

    private var playlist: PlaylistRecord? { env.library.playlist(id: playlistID) }
    private var tracks: [TrackRecord] { env.library.tracks(inPlaylist: playlistID) }

    var body: some View {
        VStack(spacing: 0) {
            if let playlist {
                header(playlist)
                Divider()
                if tracks.isEmpty {
                    ContentUnavailableView("Empty Playlist", systemImage: "music.note.list",
                                           description: Text("Drag songs here, or use “Add to Playlist” from any song's context menu."))
                } else {
                    List(selection: $selection) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            row(index: index, track: track)
                                .tag(index)
                                .contextMenu {
                                    TrackContextMenu(tracks: [track], all: tracks, editing: $editing)
                                    Divider()
                                    Button("Remove from Playlist") { Task { await env.library.removeFromPlaylist(playlistID, offsets: IndexSet(integer: index)) } }
                                }
                        }
                        .onMove { from, to in Task { await env.library.movePlaylistItems(playlistID, from: from, to: to) } }
                        .onDelete { offsets in Task { await env.library.removeFromPlaylist(playlistID, offsets: offsets) } }
                    }
                    .listStyle(.inset)
                }
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "questionmark")
            }
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.utf8PlainText, .text], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationSubtitle("\(tracks.count) songs · \(DurationFormatter.string(tracks.reduce(0) { $0 + $1.duration }))")
        .toolbar {
            ToolbarItemGroup {
                Button { newName = playlist?.name ?? ""; isRenaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button { export() } label: { Label("Export M3U8", systemImage: "square.and.arrow.up") }.disabled(tracks.isEmpty)
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await env.library.renamePlaylist(playlistID, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Playlist", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
        .sheet(item: $editing) { MetadataEditorView(track: $0) }
    }

    private func header(_ playlist: PlaylistRecord) -> some View {
        HStack(spacing: 16) {
            ArtworkView(url: env.artworkURL(tracks.first { $0.artworkFileName != nil }?.artworkFileName), size: 72, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.title2.weight(.semibold))
                Text("Created \(playlist.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { env.playback.play(tracks) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(tracks.isEmpty)
            Button { env.playback.isShuffling = true; env.playback.play(tracks, startingAt: Int.random(in: 0..<max(tracks.count, 1))) } label: { Label("Shuffle", systemImage: "shuffle") }
                .disabled(tracks.isEmpty)
        }
        .padding(16)
    }

    private func row(index: Int, track: TrackRecord) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
            ArtworkView(url: env.artworkURL(track.artworkFileName), size: 28, cornerRadius: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if env.playback.currentTrack?.id == track.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor).font(.caption) }
                    Text(track.title).lineLimit(1)
                }
                Text("\(track.displayArtist) — \(track.displayAlbum)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(DurationFormatter.string(track.duration)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { env.playback.play(tracks, startingAt: index) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else { return false }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) ? UTType.utf8PlainText.identifier : UTType.text.identifier
        provider.loadItem(forTypeIdentifier: type) { @Sendable item, _ in
            let string = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? (item as? NSString).map(String.init)
            guard let string, let ids = TrackDrag.parse(string), !ids.isEmpty else { return }
            Task { @MainActor in await env.library.addTracks(ids, toPlaylist: playlistID) }
        }
        return true
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = (playlist?.name ?? "Playlist") + ".m3u8"
        if panel.runModal() == .OK, let url = panel.url {
            do { try env.library.exportPlaylist(playlistID, to: url) } catch { message = LocalMusicError.wrap(error).message }
        }
    }
}
