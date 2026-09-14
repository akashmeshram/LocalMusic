import Testing
import Foundation
@testable import LocalMusicCore

@Suite("DuplicateDetector")
struct DuplicateDetectorTests {
    let library: [TrackRecord] = [
        TrackRecord(fileURL: URL(fileURLWithPath: "/m/a.m4a"), sourceURL: "https://www.youtube.com/watch?v=abc&list=PL1", title: "Get Lucky (feat. Pharrell Williams)", artist: "Daft Punk", duration: 248, fileFormat: "m4a", musicBrainzRecordingID: "mb-1"),
        TrackRecord(fileURL: URL(fileURLWithPath: "/m/b.m4a"), title: "Instant Crush", artist: "Daft Punk", duration: 337, fileFormat: "m4a"),
    ]

    @Test func matchesBySourceURLVariants() {
        let c = DuplicateDetector.Candidate(sourceURL: "https://youtu.be/abc", title: "whatever")
        let m = DuplicateDetector.matches(for: c, in: library)
        #expect(m.count == 1 && m.first?.reasons == [.sourceURL])
        #expect(DuplicateDetector.canonicalURL("https://m.youtube.com/watch?v=abc&t=10s") == "youtube.com/watch?v=abc")
    }

    @Test func matchesByRecordingID() {
        let c = DuplicateDetector.Candidate(musicBrainzRecordingID: "mb-1", title: "Different")
        #expect(DuplicateDetector.matches(for: c, in: library).first?.reasons == [.musicBrainzRecording])
    }

    @Test func matchesByArtistTitleAndDuration() {
        let c = DuplicateDetector.Candidate(artist: "daft punk", title: "Get Lucky (Official Video)", duration: 249)
        let m = DuplicateDetector.matches(for: c, in: library)
        #expect(m.count == 1 && m.first?.track.title.hasPrefix("Get Lucky") == true && m.first?.reasons == [.artistAndTitle])
        let tooLong = DuplicateDetector.Candidate(artist: "Daft Punk", title: "Get Lucky", duration: 600)
        #expect(DuplicateDetector.matches(for: tooLong, in: library).isEmpty)
        let otherArtist = DuplicateDetector.Candidate(artist: "Someone Else", title: "Get Lucky", duration: 248)
        #expect(DuplicateDetector.matches(for: otherArtist, in: library).isEmpty)
    }

    @Test func combinesReasons() {
        let c = DuplicateDetector.Candidate(sourceURL: "https://youtube.com/watch?v=abc", musicBrainzRecordingID: "mb-1", artist: "Daft Punk", title: "Get Lucky", duration: 248)
        let m = DuplicateDetector.matches(for: c, in: library)
        #expect(m.first?.reasons.count == 3)
    }
}
