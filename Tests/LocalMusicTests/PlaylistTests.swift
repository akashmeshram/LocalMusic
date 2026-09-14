import Testing
import Foundation
@testable import LocalMusicCore

@Suite("Playlists")
struct PlaylistTests {
    @Test func storeRoundTrip() async throws {
        let store = try LibraryStore(storeURL: nil)
        let a = UUID(), b = UUID()
        var p = PlaylistRecord(name: "Mix", trackIDs: [a, b, a])
        try await store.savePlaylist(p)
        #expect(try await store.playlists().first?.trackIDs == [a, b, a])
        p.name = "Mix 2"; p.trackIDs = [b]
        try await store.savePlaylist(p)
        let all = try await store.playlists()
        #expect(all.count == 1 && all[0].name == "Mix 2" && all[0].trackIDs == [b])
        try await store.deletePlaylist(id: p.id)
        #expect(try await store.playlists().isEmpty)
    }

    @Test func m3u8ExportAndImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMPl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Artist/Album"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t1 = TrackRecord(fileURL: dir.appendingPathComponent("Artist/Album/01 - Song.m4a"), title: "Song", artist: "Artist", duration: 61.4, fileFormat: "m4a")
        let t2 = TrackRecord(fileURL: URL(fileURLWithPath: "/Volumes/Other/x.mp3"), title: "X", fileFormat: "mp3")
        let file = dir.appendingPathComponent("Playlists/mix.m3u8")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PlaylistFile.export([t1, t2], name: "My Mix", to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("#EXTM3U\n#PLAYLIST:My Mix\n#EXTINF:61,Artist - Song\n../Artist/Album/01 - Song.m4a\n"))
        #expect(text.contains("/Volumes/Other/x.mp3"))

        let result = try PlaylistFile.importPlaylist(from: file, library: [t1])
        #expect(result.name == "My Mix")
        #expect(result.matched.map(\.id) == [t1.id])
        #expect(result.unmatchedPaths == ["/Volumes/Other/x.mp3"])
    }
}
