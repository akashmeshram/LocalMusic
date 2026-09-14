import SwiftUI
import LocalMusicCore

struct SongsView: View {
    @Environment(AppEnvironment.self) private var env
    let scope: SidebarItem
    @State private var selection = Set<TrackRecord.ID>()
    @State private var pendingDelete: [TrackRecord] = []
    @State private var editing: TrackRecord?

    private var tracks: [TrackRecord] { env.library.tracks(for: scope) }

    var body: some View {
        @Bindable var library = env.library
        Group {
            if env.library.tracks.isEmpty && !env.library.isScanning {
                ContentUnavailableView {
                    Label("No Music Yet", systemImage: "music.note.list")
                } description: {
                    Text("Paste a link in Downloads, or drop audio files into \(env.settings.musicDirectory.path) and rescan.")
                } actions: {
                    Button("Go to Downloads") { env.selectedSidebar = .downloads }
                }
            } else if tracks.isEmpty {
                ContentUnavailableView.search(text: library.searchText)
            } else {
                table
            }
        }
        .navigationTitle(scope.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search songs, artists, albums")
        .toolbar {
            ToolbarItemGroup {
                if env.library.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if let p = env.library.scanProgress { Text("\(p.done)/\(p.total)").font(.caption).monospacedDigit() }
                    }
                }
                Button { Task { await env.library.rescan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Rescan the music folder")
                    .disabled(env.library.isScanning)
            }
        }
        .sheet(item: $editing) { track in MetadataEditorView(track: track) }
        .confirmationDialog("Move \(pendingDelete.count) song(s) to the Trash?", isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Move to Trash", role: .destructive) {
                let items = pendingDelete
                pendingDelete = []
                Task { await env.library.delete(items) }
            }
        } message: {
            Text("The audio files are moved to the Trash and removed from the library index.")
        }
        .alert("Library", isPresented: Binding(get: { env.library.errorMessage != nil }, set: { if !$0 { env.library.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(env.library.errorMessage ?? "") }
    }

    private var subtitle: String {
        let list = tracks
        let total = list.reduce(0.0) { $0 + $1.duration }
        return "\(list.count) songs · \(DurationFormatter.string(total))"
    }

    private var table: some View {
        @Bindable var library = env.library
        return Table(tracks, selection: $selection, sortOrder: $library.sortOrder) {
            TableColumn("") { track in
                ArtworkView(fileName: track.artworkFileName, size: 28, cornerRadius: 3)
            }
            .width(34)

            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 6) {
                    if env.playback.currentTrack?.id == track.id {
                        Image(systemName: env.playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(Color.accentColor).font(.caption)
                    }
                    Text(track.title).lineLimit(1)
                    if track.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink) }
                }
            }
            .width(min: 160, ideal: 260)

            TableColumn("Artist", value: \.displayArtist) { Text($0.displayArtist).lineLimit(1) }
                .width(min: 110, ideal: 150)
            TableColumn("Album", value: \.displayAlbum) { Text($0.displayAlbum).lineLimit(1) }
                .width(min: 110, ideal: 170)
            TableColumn("Year", value: \.sortYear) { Text($0.yearString).monospacedDigit() }
                .width(48)
            TableColumn("Duration", value: \.duration) { Text(DurationFormatter.string($0.duration)).monospacedDigit() }
                .width(64)
            TableColumn("Format", value: \.fileFormat) { Text($0.formatLabel).font(.caption).foregroundStyle(.secondary) }
                .width(56)
            TableColumn("Date Added", value: \.dateAdded) { Text($0.dateAdded, format: .dateTime.day().month(.abbreviated).year()) }
                .width(100)
        }
        .contextMenu(forSelectionType: TrackRecord.ID.self) { ids in
            contextMenu(for: resolve(ids))
        } primaryAction: { ids in
            guard let first = ids.first, let index = tracks.firstIndex(where: { $0.id == first }) else { return }
            env.playback.play(tracks, startingAt: index)
        }
        .onDeleteCommand { pendingDelete = resolve(selection) }
        .onKeyPress("i", phases: .down) { press in
            guard press.modifiers.contains(.command), selection.count == 1, let t = resolve(selection).first else { return .ignored }
            editing = t
            return .handled
        }
    }

    private func resolve(_ ids: Set<TrackRecord.ID>) -> [TrackRecord] {
        tracks.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func contextMenu(for selected: [TrackRecord]) -> some View {
        if selected.isEmpty {
            Button("Rescan Music Folder") { Task { await env.library.rescan() } }
        } else {
            let first = selected[0]
            Button("Play") {
                if selected.count == 1, let index = tracks.firstIndex(of: first) { env.playback.play(tracks, startingAt: index) } else { env.playback.play(selected) }
            }
            Button("Play Next") { for t in selected.reversed() { env.playback.playNext(t) } }
            Button("Add to Queue") { for t in selected { env.playback.enqueue(t) } }
            Divider()
            Button(first.isFavorite && selected.count == 1 ? "Remove from Favorites" : "Add to Favorites") {
                Task { for t in selected { await env.library.toggleFavorite(t) } }
            }
            Divider()
            Button("Edit Metadata…") { editing = first }.disabled(selected.count != 1)
            Button("Reveal in Finder") { env.library.reveal(first) }.disabled(selected.count != 1)
            Button("Copy Source URL") { env.library.copySourceURL(first) }.disabled(selected.count != 1 || first.sourceURL == nil)
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = selected }
        }
    }
}
