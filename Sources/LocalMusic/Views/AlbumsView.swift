import SwiftUI
import LocalMusicCore

struct AlbumsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selected: LibraryViewModel.AlbumGroup?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 18)]

    var body: some View {
        @Bindable var library = env.library
        Group {
            if let album = selected {
                AlbumDetailView(album: album) { selected = nil }
            } else if env.library.albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "square.stack", description: Text("Albums appear once tracks carry album metadata."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(env.library.albums) { album in
                            AlbumCard(album: album)
                                .onTapGesture { selected = album }
                                .contextMenu { albumMenu(album) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(selected?.title ?? "Albums")
        .navigationSubtitle(selected.map { "\($0.artist) · \($0.tracks.count) songs" } ?? "\(env.library.albums.count) albums")
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search albums")
        .onChange(of: env.library.tracks) { if let s = selected { selected = env.library.albums.first { $0.id == s.id } } }
        .onAppear {
            // `--select=album` opens the first (largest) album's detail; used for screenshots.
            if LaunchOptions.initialSelection == "album", selected == nil {
                selected = env.library.albums.max { $0.tracks.count < $1.tracks.count }
            }
        }
    }

    @ViewBuilder
    func albumMenu(_ album: LibraryViewModel.AlbumGroup) -> some View {
        Button("Play") { env.playback.play(album.tracks) }
        Button("Play Next") { for t in album.tracks.reversed() { env.playback.playNext(t) } }
        Button("Add to Queue") { for t in album.tracks { env.playback.enqueue(t) } }
        AddToPlaylistMenu(trackIDs: album.tracks.map(\.id))
        Divider()
        Button("Reveal in Finder") { env.library.reveal(album.tracks[0]) }
    }
}

struct AlbumCard: View {
    let album: LibraryViewModel.AlbumGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(fileName: album.artworkFileName, size: 170, cornerRadius: 8)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text(album.title).font(.callout.weight(.medium)).lineLimit(1)
            HStack(spacing: 4) {
                Text(album.artist).lineLimit(1)
                if let y = album.year { Text("· \(String(y))") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 170)
        .contentShape(Rectangle())
    }
}

struct AlbumDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let album: LibraryViewModel.AlbumGroup
    let onBack: () -> Void
    @State private var editing: TrackRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                ArtworkView(fileName: album.artworkFileName, size: 160, cornerRadius: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title).font(.title.weight(.semibold))
                    Text(album.artist).font(.title3).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let y = album.year { Text(String(y)) }
                        Text("· \(album.tracks.count) songs · \(DurationFormatter.string(album.duration))")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { env.playback.play(album.tracks) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                        Button { env.playback.isShuffling = true; env.playback.play(album.tracks, startingAt: Int.random(in: 0..<album.tracks.count)) } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                    .padding(.top, 6)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            List {
                ForEach(album.tracks) { track in
                    HStack(spacing: 10) {
                        Text(track.trackNumber.map { String($0) } ?? "–").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                        if env.playback.currentTrack?.id == track.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor).font(.caption)
                        }
                        Text(track.title).lineLimit(1)
                        if track.artist != nil, track.artist != album.artist { Text("· \(track.artist!)").foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if track.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink) }
                        Text(DurationFormatter.string(track.duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { env.playback.play(album.tracks, startingAt: album.tracks.firstIndex(of: track) ?? 0) }
                    .contextMenu { TrackContextMenu(tracks: [track], all: album.tracks, editing: $editing) }
                }
            }
            .listStyle(.inset)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { onBack() } label: { Label("Albums", systemImage: "chevron.left") }
            }
        }
        .sheet(item: $editing) { MetadataEditorView(track: $0) }
    }
}

/// Shared context-menu body for a set of tracks.
struct TrackContextMenu: View {
    @Environment(AppEnvironment.self) private var env
    let tracks: [TrackRecord]
    let all: [TrackRecord]
    @Binding var editing: TrackRecord?
    var identifying: Binding<TrackRecord?>? = nil
    var onDelete: (([TrackRecord]) -> Void)? = nil

    var body: some View {
        if let first = tracks.first {
            Button("Play") {
                if tracks.count == 1, let i = all.firstIndex(of: first) { env.playback.play(all, startingAt: i) } else { env.playback.play(tracks) }
            }
            Button("Play Next") { for t in tracks.reversed() { env.playback.playNext(t) } }
            Button("Add to Queue") { for t in tracks { env.playback.enqueue(t) } }
            AddToPlaylistMenu(trackIDs: tracks.map(\.id))
            Divider()
            Button(first.isFavorite && tracks.count == 1 ? "Remove from Favorites" : "Add to Favorites") {
                Task { for t in tracks { await env.library.toggleFavorite(t) } }
            }
            Divider()
            Button("Edit Metadata…") { editing = first }.disabled(tracks.count != 1)
            if let identifying { Button("Re-identify Metadata…") { identifying.wrappedValue = first }.disabled(tracks.count != 1) }
            Button("Reveal in Finder") { env.library.reveal(first) }.disabled(tracks.count != 1)
            Button("Copy Source URL") { env.library.copySourceURL(first) }.disabled(tracks.count != 1 || first.sourceURL == nil)
            if let onDelete {
                Divider()
                Button("Delete…", role: .destructive) { onDelete(tracks) }
            }
        }
    }
}

struct AddToPlaylistMenu: View {
    @Environment(AppEnvironment.self) private var env
    let trackIDs: [UUID]

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(env.library.playlists) { p in
                Button(p.name) { Task { await env.library.addTracks(trackIDs, toPlaylist: p.id) } }
            }
            if !env.library.playlists.isEmpty { Divider() }
            Button("New Playlist…") {
                Task {
                    let p = await env.library.createPlaylist(trackIDs: trackIDs)
                    env.selectedSidebar = .playlist(p.id)
                }
            }
        }
    }
}
