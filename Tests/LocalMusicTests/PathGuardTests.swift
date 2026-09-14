import Testing
import Foundation
@testable import LocalMusicCore

@Suite("PathGuard")
struct PathGuardTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LMGuard-\(UUID().uuidString)")

    @Test func acceptsPathsInsideRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guardian = PathGuard(root: root)
        #expect(guardian.contains(root.appendingPathComponent("Artist/Album/01 - Song.m4a")))
        _ = try guardian.validated(root.appendingPathComponent("x.m4a"))
    }

    @Test func rejectsTraversalAndSiblings() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guardian = PathGuard(root: root)
        #expect(!guardian.contains(root.appendingPathComponent("../escape.m4a")))
        #expect(!guardian.contains(root.appendingPathComponent("a/../../escape.m4a")))
        #expect(!guardian.contains(URL(fileURLWithPath: root.path + "-sibling/x.m4a")))
        #expect(throws: LocalMusicError.self) { try guardian.validated(URL(fileURLWithPath: "/tmp/other.m4a")) }
    }

    @Test func rejectsSymlinkEscapes() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = fm.temporaryDirectory.appendingPathComponent("LMOutside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let guardian = PathGuard(root: root)
        #expect(!guardian.contains(link.appendingPathComponent("new/file.m4a")))
        try? fm.removeItem(at: root); try? fm.removeItem(at: outside)
    }
}
