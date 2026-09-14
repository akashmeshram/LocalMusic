import SwiftUI
import LocalMusicCore

struct SongsView: View {
    @Environment(AppEnvironment.self) private var env
    let scope: SidebarItem
    @State private var selection = Set<TrackRecord.ID>()
    @State private var pendingDelete: [TrackRecord] = []
    @State private var editing: TrackRecord?
    @State private var identifying: TrackRecord?

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
        .sheet(item: $identifying) { track in MatchPickerView(track: track, initialCandidates: []) }
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
        return Table(of: TrackRecord.self, selection: $selection, sortOrder: $library.sortOrder) {
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
        } rows: {
            ForEach(tracks) { track in
                TableRow(track).itemProvider {
                    let ids = selection.contains(track.id) ? tracks.filter { selection.contains($0.id) }.map(\.id) : [track.id]
                    return NSItemProvider(object: TrackDrag.payload(ids) as NSString)
                }
            }
        }
        .contextMenu(forSelectionType: TrackRecord.ID.self) { ids in
            let selected = resolve(ids)
            if selected.isEmpty {
                Button("Rescan Music Folder") { Task { await env.library.rescan() } }
            } else {
                TrackContextMenu(tracks: selected, all: tracks, editing: $editing, identifying: $identifying) { pendingDelete = $0 }
            }
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
}
