import SwiftUI
import LocalMusicCore

/// "Up Next" popover from the now-playing bar.
struct QueueView: View {
    @Environment(AppEnvironment.self) private var env

    private var playback: PlaybackService { env.playback }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Text("\(playback.queue.count) songs").font(.caption).foregroundStyle(.secondary)
                Button("Clear") { playback.clearQueue() }.controlSize(.small).disabled(playback.queue.isEmpty)
            }
            .padding(12)
            Divider()
            if playback.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.bullet", description: Text("Use Play Next or Add to Queue."))
                    .frame(height: 200)
            } else {
                List {
                    ForEach(Array(playback.queue.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: 10) {
                            ArtworkView(fileName: track.artworkFileName, size: 28, cornerRadius: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title).lineLimit(1).fontWeight(index == playback.queueIndex ? .semibold : .regular)
                                Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if index == playback.queueIndex {
                                Image(systemName: playback.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(Color.accentColor).font(.caption)
                            } else {
                                Button { playback.removeFromQueue(at: index) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { playback.play(playback.queue, startingAt: index) }
                    }
                }
                .listStyle(.inset)
                .frame(height: 320)
            }
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
