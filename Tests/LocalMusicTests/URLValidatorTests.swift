import Testing
import Foundation
@testable import LocalMusicCore

@Suite("URLValidator")
struct URLValidatorTests {
    @Test func acceptsHTTPAndAddsScheme() {
        #expect(URLValidator.normalize("https://www.youtube.com/watch?v=abc")?.absoluteString == "https://www.youtube.com/watch?v=abc")
        #expect(URLValidator.normalize("  youtube.com/watch?v=abc ")?.absoluteString == "https://youtube.com/watch?v=abc")
        #expect(URLValidator.normalize("<https://example.com/x>")?.host == "example.com")
    }

    @Test func rejectsGarbage() {
        #expect(URLValidator.normalize("") == nil)
        #expect(URLValidator.normalize("not a url") == nil)
        #expect(URLValidator.normalize("file:///etc/passwd") == nil)
        #expect(URLValidator.normalize("javascript:alert(1)") == nil)
        #expect(URLValidator.normalize("ftp://example.com/x") == nil)
        #expect(URLValidator.normalize("--version") == nil)
    }

    @Test func playlistHeuristic() {
        #expect(URLValidator.looksLikePlaylist(URL(string: "https://www.youtube.com/playlist?list=PL123")!))
        #expect(URLValidator.looksLikePlaylist(URL(string: "https://soundcloud.com/a/sets/b")!))
        #expect(!URLValidator.looksLikePlaylist(URL(string: "https://www.youtube.com/watch?v=abc")!))
    }
}
