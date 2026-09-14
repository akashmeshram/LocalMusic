import Testing
import Foundation
@testable import LocalMusicCore

@Suite("PlaybackService")
@MainActor
struct PlaybackServiceTests {
    @Test func playsALocalFileAndAdvances() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMPlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tone.wav")
        try MockDownloader.sineWave(seconds: 3, frequency: 440).write(to: file)
        let track = TrackRecord(fileURL: file, title: "Tone", duration: 3, fileFormat: "wav")

        let playback = PlaybackService(initialVolume: 0)
        playback.play([track])
        #expect(playback.isPlaying)
        #expect(playback.currentTrack?.id == track.id)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(playback.currentTime > 0.3)
        #expect(abs(playback.duration - 3) < 0.2)

        playback.pause()
        #expect(!playback.isPlaying)
        playback.seek(to: 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(playback.currentTime - 1) < 0.3)
        playback.stop()
        #expect(playback.currentTrack == nil)
    }

    @Test func queueNavigation() {
        let a = TrackRecord(fileURL: URL(fileURLWithPath: "/nonexistent/a.wav"), title: "A", fileFormat: "wav")
        let b = TrackRecord(fileURL: URL(fileURLWithPath: "/nonexistent/b.wav"), title: "B", fileFormat: "wav")
        let c = TrackRecord(fileURL: URL(fileURLWithPath: "/nonexistent/c.wav"), title: "C", fileFormat: "wav")
        let playback = PlaybackService(initialVolume: 0)
        playback.play([a, b], startingAt: 0)
        playback.playNext(c)
        #expect(playback.queue.map(\.title) == ["A", "C", "B"])
        playback.next()
        #expect(playback.currentTrack?.title == "C")
        playback.next()
        #expect(playback.currentTrack?.title == "B")
        playback.next() // end of queue, repeat off
        #expect(playback.currentTrack == nil)
        playback.repeatMode = .all
        playback.play([a, b], startingAt: 1)
        playback.next()
        #expect(playback.currentTrack?.title == "A")
    }
}
