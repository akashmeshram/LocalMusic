import SwiftUI
import LocalMusicCore

struct ArtistsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selectedArtistID: String?
    @State private var editing: TrackRecord?

    var body: some View {
        @Bindable var library = env.library
        HSplitView {
            List(env.library.artists, selection: $selectedArtistID) { artist in
                HStack(spacing: 10) {
                    ArtworkView(url: env.artworkURL(artist.artworkFileName), size: 32, cornerRadius: 16)
                    VStack(alignment: .leading) {
                        Text(artist.name).lineLimit(1)
                        Text("\(artist.tracks.count) songs · \(artist.albums.count) albums").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(artist.id)
                .contextMenu {
                    Button("Play All") { env.playback.play(artist.tracks) }
                    Button("Add to Queue") { for t in artist.tracks { env.playback.enqueue(t) } }
                    AddToPlaylistMenu(trackIDs: artist.tracks.map(\.id))
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .listStyle(.inset)

            Group {
                if let artist = env.library.artists.first(where: { $0.id == selectedArtistID }) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(artist.name).font(.title.weight(.semibold))
                                Spacer()
                                Button { env.playback.play(artist.tracks) } label: { Label("Play All", systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent)
                                Button { env.playback.isShuffling = true; env.playback.play(artist.tracks, startingAt: Int.random(in: 0..<artist.tracks.count)) } label: { Label("Shuffle", systemImage: "shuffle") }
                            }
                            ForEach(artist.albums) { album in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        ArtworkView(url: env.artworkURL(album.artworkFileName), size: 56, cornerRadius: 6)
                                        VStack(alignment: .leading) {
                                            Text(album.title).font(.headline)
                                            Text([album.year.map(String.init), "\(album.tracks.count) songs"].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button { env.playback.play(album.tracks) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).font(.title2)
                                    }
                                    ForEach(album.tracks) { track in
                                        HStack(spacing: 10) {
                                            Text(track.trackNumber.map { String($0) } ?? "–").monospacedDigit().foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                                            if env.playback.currentTrack?.id == track.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor).font(.caption) }
                                            Text(track.title).lineLimit(1)
                                            Spacer()
                                            Text(DurationFormatter.string(track.duration)).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 3).padding(.horizontal, 6)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { env.playback.play(album.tracks, startingAt: album.tracks.firstIndex(of: track) ?? 0) }
                                        .contextMenu { TrackContextMenu(tracks: [track], all: album.tracks, editing: $editing) }
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    ContentUnavailableView("Select an Artist", systemImage: "music.mic", description: Text(env.library.artists.isEmpty ? "Artists appear once you have music." : "\(env.library.artists.count) artists"))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Artists")
        .navigationSubtitle("\(env.library.artists.count) artists")
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search artists")
        .sheet(item: $editing) { MetadataEditorView(track: $0) }
    }
}
