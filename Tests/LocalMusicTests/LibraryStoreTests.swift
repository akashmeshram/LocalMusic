import Testing
import Foundation
@testable import LocalMusicCore

@Suite("LibraryStore")
struct LibraryStoreTests {
    @Test func upsertFetchAndDelete() async throws {
        let store = try LibraryStore(storeURL: nil)
        let a = TrackRecord(fileURL: URL(fileURLWithPath: "/m/a.m4a"), sourceURL: "https://e.com/a", title: "A", artist: "X", duration: 10, fileFormat: "m4a")
        let b = TrackRecord(fileURL: URL(fileURLWithPath: "/m/b.mp3"), title: "B", fileFormat: "mp3")
        try await store.upsert([a, b])
        #expect(try await store.allTracks().count == 2)
        #expect(try await store.track(id: a.id)?.title == "A")
        #expect(try await store.track(filePath: "/m/b.mp3")?.title == "B")
        #expect(try await store.tracks(sourceURL: "https://e.com/a").count == 1)

        var a2 = a; a2.title = "A2"
        try await store.upsert([a2])
        #expect(try await store.allTracks().count == 2)
        #expect(try await store.track(id: a.id)?.title == "A2")

        // Same path with a fresh id updates the existing row instead of duplicating.
        let a3 = TrackRecord(fileURL: a.fileURL, title: "A3", fileFormat: "m4a")
        try await store.upsert([a3])
        #expect(try await store.allTracks().count == 2)
        #expect(try await store.track(filePath: a.fileURL.path)?.title == "A3")

        // The caller's id wins on a path match, so the row now carries a3.id.
        #expect(try await store.track(id: a.id) == nil)
        try await store.recordPlay(id: a3.id)
        try await store.setFavorite(id: a3.id, true)
        let played = try await store.track(id: a3.id)
        #expect(played?.playCount == 1 && played?.isFavorite == true && played?.lastPlayedAt != nil)

        let removed = try await store.deleteTracks(notIn: [a.fileURL.path])
        #expect(removed == 1)
        try await store.delete(ids: [a3.id])
        #expect(try await store.allTracks().isEmpty)
    }
}
