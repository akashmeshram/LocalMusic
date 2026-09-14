import Testing
import Foundation
@testable import LocalMusicCore

@Suite("FilenameSanitizer")
struct FilenameSanitizerTests {
    @Test func replacesPathSeparators() {
        #expect(FilenameSanitizer.sanitize("AC/DC: Back in Black") == "AC - DC - Back in Black")
        #expect(FilenameSanitizer.sanitize("a\\b") == "a - b")
    }

    @Test func stripsControlCharactersAndCollapsesWhitespace() {
        #expect(FilenameSanitizer.sanitize("  Hello\u{0}\tWorld \n ") == "Hello World")
    }

    @Test func preventsHiddenFilesAndTrailingDots() {
        #expect(FilenameSanitizer.sanitize("...secret") == "secret")
        #expect(FilenameSanitizer.sanitize("Name...") == "Name")
    }

    @Test func keepsUnicodeAndEmoji() {
        #expect(FilenameSanitizer.sanitize("Björk – Jóga 🎵") == "Björk – Jóga 🎵")
        #expect(FilenameSanitizer.sanitize("坂本龍一 - Merry Christmas Mr. Lawrence") == "坂本龍一 - Merry Christmas Mr. Lawrence")
    }

    @Test func fallsBackWhenEmpty() {
        #expect(FilenameSanitizer.sanitize("") == "Untitled")
        #expect(FilenameSanitizer.sanitize(" / : ", fallback: "X") == "X")
    }

    @Test func truncatesOnGraphemeBoundaries() {
        let long = String(repeating: "🎵", count: 100) // 400 bytes
        let out = FilenameSanitizer.sanitize(long)
        #expect(out.utf8.count <= FilenameSanitizer.maxComponentBytes)
        #expect(out.allSatisfy { $0 == "🎵" })
        let ascii = String(repeating: "a", count: 300)
        #expect(FilenameSanitizer.sanitize(ascii).utf8.count == FilenameSanitizer.maxComponentBytes)
    }

    @Test func sanitizesExtensions() {
        #expect(FilenameSanitizer.sanitizeExtension(".M4A") == "m4a")
        #expect(FilenameSanitizer.sanitizeExtension("../etc") == "etc")
        #expect(FilenameSanitizer.sanitizeExtension("") == "bin")
    }
}
