import SwiftUI
import LocalMusicCore

struct NowPlayingBar: View {
    @Environment(AppEnvironment.self) private var env
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var showQueue = false

    private var playback: PlaybackService { env.playback }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ArtworkView(url: env.artworkURL(playback.currentTrack?.artworkFileName), size: 44, cornerRadius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.currentTrack?.title ?? "Not Playing").font(.callout.weight(.medium)).lineLimit(1)
                    Text(playback.currentTrack.map { "\($0.displayArtist) — \($0.displayAlbum)" } ?? "Select a song to play")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 280, alignment: .leading)

            HStack(spacing: 14) {
                Button { playback.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(playback.isShuffling ? Color.accentColor : Color.secondary)
                Button { playback.previous() } label: { Image(systemName: "backward.fill") }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                }
                .disabled(playback.currentTrack == nil && playback.queue.isEmpty)
                Button { playback.next() } label: { Image(systemName: "forward.fill") }
                Button { playback.cycleRepeat() } label: { Image(systemName: playback.repeatMode == .one ? "repeat.1" : "repeat") }
                    .foregroundStyle(playback.repeatMode == .off ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .font(.title3)

            HStack(spacing: 8) {
                Text(DurationFormatter.string(isScrubbing ? scrubValue : playback.currentTime))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                Slider(value: Binding(get: { isScrubbing ? scrubValue : playback.currentTime },
                                      set: { scrubValue = $0 }),
                       in: 0...max(playback.duration, 1)) { editing in
                    isScrubbing = editing
                    if !editing { playback.seek(to: scrubValue) }
                }
                .disabled(playback.currentTrack == nil)
                Text(DurationFormatter.string(playback.duration))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: Binding(get: { Double(playback.volume) }, set: { playback.volume = Float($0) }), in: 0...1)
                    .frame(width: 90)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
                Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.plain).foregroundStyle(playback.queue.isEmpty ? .secondary : Color.accentColor)
                    .help("Up Next")
                    .popover(isPresented: $showQueue, arrowEdge: .bottom) { QueueView().environment(env) }
                    .padding(.leading, 6)
            }
            .frame(width: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
