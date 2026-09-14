import Testing
import Foundation
@testable import LocalMusicCore

@Suite("FileOrganizer")
struct FileOrganizerTests {
    let root = URL(fileURLWithPath: "/Users/test/Music/LocalMusic")

    @Test func albumTrackPath() {
        let org = FileOrganizer(root: root)
        let meta = OrganizeMetadata(title: "Give Life Back to Music", artist: "Daft Punk", album: "Random Access Memories", year: 2013, trackNumber: 1)
        #expect(org.relativePath(for: meta, fileExtension: "m4a") == "Daft Punk/2013 - Random Access Memories/01 - Give Life Back to Music.m4a")
    }

    @Test func albumArtistWinsOverArtist() {
        let org = FileOrganizer(root: root)
        let meta = OrganizeMetadata(title: "Song", artist: "Feat. Someone", albumArtist: "Main Artist", album: "Album", year: 2020, trackNumber: 12)
        #expect(org.relativePath(for: meta, fileExtension: "mp3") == "Main Artist/2020 - Album/12 - Song.mp3")
    }

    @Test func missingYearAndTrackCollapseSeparators() {
        let org = FileOrganizer(root: root)
        let meta = OrganizeMetadata(title: "Song", artist: "Artist", album: "Album")
        #expect(org.relativePath(for: meta, fileExtension: "m4a") == "Artist/Album/Song.m4a")
    }

    @Test func singlesFolderWhenNoAlbum() {
        let org = FileOrganizer(root: root)
        let meta = OrganizeMetadata(title: "Lonely Single", artist: "Artist")
        #expect(org.relativePath(for: meta, fileExtension: "m4a") == "Artist/Singles/Lonely Single.m4a")
    }

    @Test func unknownWhenNothingKnown() {
        let org = FileOrganizer(root: root)
        let meta = OrganizeMetadata(title: "Mystery")
        #expect(org.relativePath(for: meta, fileExtension: "opus") == "Unknown Artist/Unknown Album/Mystery.opus")
    }

    @Test func sanitizesEverySegment() {
        let org = FileOrganizer(root: root)
        let meta = OrganizeMetadata(title: "../../etc/passwd", artist: "AC/DC", album: "Live: 1979", year: 1979, trackNumber: 3)
        let path = org.relativePath(for: meta, fileExtension: "m4a")
        #expect(path == "AC - DC/1979 - Live - 1979/03 - etc - passwd.m4a")
        #expect(!path.contains(".."+"/"))
        #expect(PathGuard(root: root).contains(root.appendingPathComponent(path)))
    }

    @Test func customTemplates() {
        let org = FileOrganizer(root: root, folderTemplate: "{Genre}/{AlbumArtist}/{Album} ({Year})", filenameTemplate: "{Disc}-{Track} {Title}")
        let meta = OrganizeMetadata(title: "T", artist: "A", album: "B", year: 1999, trackNumber: 7, discNumber: 2, genre: "Jazz")
        #expect(org.relativePath(for: meta, fileExtension: "flac") == "Jazz/A/B (1999)/2-07 T.flac")
        let noGenre = OrganizeMetadata(title: "T", artist: "A", album: "B")
        #expect(org.relativePath(for: noGenre, fileExtension: "flac") == "A/B/T.flac")
    }

    @Test func expandDropsUnknownPlaceholders() {
        #expect(FileOrganizer.expand("{Nope}/{Album}", values: ["Album": "X"]) == ["X"])
    }

    @Test func placeMovesAndAvoidsCollisionsCaseInsensitively() throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("LMOrg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }
        let org = FileOrganizer(root: tmpRoot)
        let incoming = tmpRoot.appendingPathComponent(".incoming")
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)

        let meta = OrganizeMetadata(title: "Song", artist: "Artist", album: "Album", year: 2001, trackNumber: 1)
        let first = incoming.appendingPathComponent("a.m4a")
        try Data("1".utf8).write(to: first)
        let placed1 = try org.place(first, as: meta)
        #expect(placed1.path == tmpRoot.appendingPathComponent("Artist/2001 - Album/01 - Song.m4a").path)

        let second = incoming.appendingPathComponent("b.m4a")
        try Data("2".utf8).write(to: second)
        let lowercased = OrganizeMetadata(title: "song", artist: "artist", album: "album", year: 2001, trackNumber: 1)
        let placed2 = try org.place(second, as: lowercased)
        #expect(placed2.lastPathComponent == "01 - song (2).m4a")
        #expect(fm.fileExists(atPath: placed1.path) && fm.fileExists(atPath: placed2.path))

        let third = incoming.appendingPathComponent("c.m4a")
        try Data("3".utf8).write(to: third)
        #expect(throws: LocalMusicError.self) { try org.place(third, as: meta, collision: .fail) }
        let replaced = try org.place(third, as: meta, collision: .replace)
        #expect(try String(contentsOf: replaced, encoding: .utf8) == "3")
    }

    @Test func placeRefusesEscapingRoot() throws {
        let fm = FileManager.default
        let tmpRoot = fm.temporaryDirectory.appendingPathComponent("LMOrg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpRoot) }
        let org = FileOrganizer(root: tmpRoot)
        let src = tmpRoot.appendingPathComponent("x.m4a")
        try Data().write(to: src)
        #expect(throws: LocalMusicError.self) { try org.move(src, to: fm.temporaryDirectory.appendingPathComponent("escaped.m4a")) }
        #expect(fm.fileExists(atPath: src.path))
    }
}
