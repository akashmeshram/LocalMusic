import Testing
import Foundation
@testable import LocalMusicCore

@Suite("MusicBrainz")
struct MusicBrainzTests {
    static let fixture = """
    {"count": 3, "recordings": [
      {"id": "rec-album", "score": 100, "title": "Get Lucky", "length": 369000,
       "artist-credit": [{"name": "Daft Punk", "joinphrase": " feat. ", "artist": {"id": "a1", "name": "Daft Punk"}}, {"name": "Pharrell Williams", "artist": {"id": "a2", "name": "Pharrell Williams"}}],
       "releases": [
         {"id": "rel-comp", "title": "Now That's What I Call Music! 85", "date": "2013-07-22", "status": "Official", "release-group": {"id": "rg-comp", "primary-type": "Album", "secondary-types": ["Compilation"]}, "media": [{"position": 1, "track-count": 44, "track-offset": 0, "track": [{"number": "1"}]}]},
         {"id": "rel-ram", "title": "Random Access Memories", "date": "2013-05-17", "status": "Official", "country": "XW", "release-group": {"id": "rg-ram", "primary-type": "Album", "secondary-types": []}, "media": [{"position": 1, "track-count": 13, "track-offset": 7, "track": [{"number": "8"}]}]},
         {"id": "rel-single", "title": "Get Lucky", "date": "2013-04-19", "status": "Official", "release-group": {"id": "rg-single", "primary-type": "Single"}, "media": [{"position": 1, "track-count": 2, "track": [{"number": "1"}]}]}
       ]},
      {"id": "rec-snippet", "score": 100, "title": "Get Lucky", "length": 40013, "artist-credit": [{"name": "Daft Punk"}],
       "releases": [{"id": "rel-school", "title": "Schule für E-Gitarre", "date": "2015", "release-group": {"primary-type": "Album", "secondary-types": ["Compilation"]}}]},
      {"id": "rec-live", "score": 90, "title": "Get Lucky (live)", "length": 372000, "artist-credit": [{"name": "Daft Punk"}],
       "releases": [{"id": "rel-live", "title": "Alive 2017", "date": "2017", "release-group": {"primary-type": "Album", "secondary-types": ["Live"]}}]}
    ]}
    """.data(using: .utf8)!

    @Test func parsesSearchResponse() {
        let recs = MusicBrainzService.parseRecordingSearch(Self.fixture)
        #expect(recs.count == 3)
        let album = recs[0]
        #expect(album.artistCredit == "Daft Punk feat. Pharrell Williams")
        #expect(album.artistIDs == ["a1", "a2"])
        #expect(album.duration == 369)
        #expect(album.releases.count == 3)
        let ram = album.releases.first { $0.id == "rel-ram" }!
        #expect(ram.year == 2013 && ram.trackNumber == 8 && ram.trackCount == 13 && ram.discNumber == 1)
        #expect(ram.primaryType == "Album" && !ram.isCompilation && ram.isOfficial)
        #expect(album.releases.first { $0.id == "rel-comp" }!.isCompilation)
        #expect(recs[2].releases[0].isLiveOrRemix)
    }

    @Test func ranksTheStudioVersionFirstAndPicksTheAlbum() {
        let recs = MusicBrainzService.parseRecordingSearch(Self.fixture)
        let scorer = CandidateScorer(preferEarliestRelease: true)
        let ranked = scorer.rank(recs, for: .init(title: "Get Lucky", artist: "Daft Punk", duration: 368))
        #expect(ranked.first?.recording.id == "rec-album")
        #expect(ranked.first!.score > 0.85)
        #expect(ranked.first?.release?.id == "rel-ram")
        let snippet = ranked.first { $0.recording.id == "rec-snippet" }!
        #expect(snippet.score < 0.7)
        let live = ranked.first { $0.recording.id == "rec-live" }!
        #expect(live.score < ranked.first!.score - 0.1)
    }

    @Test func albumHintOverridesReleaseChoice() {
        let recs = MusicBrainzService.parseRecordingSearch(Self.fixture)
        let scorer = CandidateScorer()
        let chosen = scorer.bestRelease(of: recs[0], for: .init(title: "Get Lucky", artist: "Daft Punk", album: "Get Lucky"))
        #expect(chosen?.id == "rel-single")
    }

    @Test func liveQueryPrefersLiveRecording() {
        let recs = MusicBrainzService.parseRecordingSearch(Self.fixture)
        let ranked = CandidateScorer().rank(recs, for: .init(title: "Get Lucky (Live)", artist: "Daft Punk", duration: 372))
        #expect(ranked.first?.recording.id == "rec-live")
    }

    @Test func candidateTagsLayerOverCurrent() {
        let recs = MusicBrainzService.parseRecordingSearch(Self.fixture)
        let c = CandidateScorer().score(recs[0], for: .init(title: "Get Lucky", artist: "Daft Punk", duration: 369))
        let tags = c.tags(over: TrackTags(title: "Daft Punk - Get Lucky (Official Video)", genre: "Disco"))
        #expect(tags.title == "Get Lucky" && tags.album == "Random Access Memories" && tags.year == 2013 && tags.trackNumber == 8)
        #expect(tags.genre == "Disco")
        #expect(tags.musicBrainzRecordingID == "rec-album" && tags.musicBrainzReleaseID == "rel-ram")
    }

    @Test func luceneEscaping() {
        #expect(MusicBrainzService.luceneQuery(title: "Say \"Hi\"", artist: "AC\\DC") == #"recording:"Say \"Hi\"" AND artist:"AC\\DC""#)
        #expect(MusicBrainzService.luceneQuery(title: "Solo", artist: " ") == #"recording:"Solo""#)
        #expect(MusicBrainzService.luceneQuery(title: "Solo", artist: nil, duration: 100) == #"recording:"Solo" AND dur:[85000 TO 115000]"#)
    }

    @Test func unknownLengthNeverAutoAccepts() {
        let rec = MBRecording(id: "r", title: "Get Lucky", artistCredit: "Daft Punk", lengthMs: nil,
                              releases: [MBRelease(id: "x", title: "Soundtrack", date: "2024", status: "Official", primaryType: "Album")])
        let c = CandidateScorer().score(rec, for: .init(title: "Get Lucky", artist: "Daft Punk", duration: 369))
        #expect(c.score <= 0.8)
    }

    @Test func similarity() {
        #expect(StringSimilarity.score("Daft Punk", "Daft Punk") == 1)
        #expect(StringSimilarity.score("Björk", "Bjork") == 1)
        #expect(StringSimilarity.score("Daft Punk", "Punk, Daft") == 1)
        #expect(StringSimilarity.score("Get Lucky", "Get Lucky (feat. Pharrell Williams)") >= 0.85)
        #expect(StringSimilarity.score("Get Lucky", "Instant Crush") < 0.4)
    }

    @Test func cacheRoundTripAndExpiry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MetadataCache(directory: dir, ttl: 60)
        #expect(cache.get("k") == nil)
        cache.set("k", Data("v".utf8))
        #expect(cache.get("k") == Data("v".utf8))
        #expect(cache.entryCount == 1)
        let expired = MetadataCache(directory: dir, ttl: -1)
        #expect(expired.get("k") == nil)
        try cache.clear()
        #expect(cache.entryCount == 0)
    }

    @Test func acoustIDParsing() {
        let json = """
        {"status": "ok", "results": [{"id": "x", "score": 0.97, "recordings": [{"id": "rec-1"}, {"id": "rec-2"}]}, {"id": "y", "score": 0.4, "recordings": []}]}
        """.data(using: .utf8)!
        let matches = AcoustIDService.parse(json)
        #expect(matches.count == 1 && matches[0].recordingIDs == ["rec-1", "rec-2"] && matches[0].score == 0.97)
    }
}
