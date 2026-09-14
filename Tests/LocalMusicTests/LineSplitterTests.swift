import Testing
import Foundation
@testable import LocalMusicCore

@Suite("LineSplitter")
struct LineSplitterTests {
    @Test func splitsOnNewlineAndCarriageReturnAcrossChunks() {
        let s = LineSplitter()
        #expect(s.append(Data("abc\ndef\rgh".utf8)) == ["abc", "def"])
        #expect(s.append(Data("i\r\n".utf8)) == ["ghi"])
        #expect(s.flush() == nil)
        #expect(s.append(Data("tail".utf8)) == [])
        #expect(s.flush() == "tail")
    }
}
