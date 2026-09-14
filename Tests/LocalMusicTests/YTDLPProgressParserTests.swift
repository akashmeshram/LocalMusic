import Testing
import Foundation
@testable import LocalMusicCore

@Suite("YTDLPProgressParser")
struct YTDLPProgressParserTests {
    @Test func parsesTemplatedProgress() throws {
        let line = "LMPROG|downloading|1048576|4194304|NA|524288.0|6|3|12"
        guard case .progress(let p) = YTDLPProgressParser.parse(line) else { Issue.record("not progress"); return }
        #expect(p.downloadedBytes == 1_048_576)
        #expect(p.totalBytes == 4_194_304)
        #expect(p.isTotalEstimated == false)
        #expect(p.fraction == 0.25)
        #expect(p.speedBytesPerSecond == 524_288)
        #expect(p.etaSeconds == 6)
        #expect(p.playlistIndex == 3)
        #expect(p.playlistCount == 12)
        #expect(p.percentText == "25.0%")
    }

    @Test func usesEstimateWhenTotalUnknown() throws {
        let line = "LMPROG|downloading|500|NA|1000.0|NA|NA|NA|NA"
        guard case .progress(let p) = YTDLPProgressParser.parse(line) else { Issue.record("not progress"); return }
        #expect(p.totalBytes == 1000)
        #expect(p.isTotalEstimated)
        #expect(p.fraction == 0.5)
        #expect(p.speedBytesPerSecond == nil)
        #expect(p.etaSeconds == nil)
    }

    @Test func finishedIsFull() throws {
        guard case .progress(let p) = YTDLPProgressParser.parse("LMPROG|finished|4194304|4194304|NA|NA|0|NA|NA") else { Issue.record("x"); return }
        #expect(p.fraction == 1)
        #expect(p.phase == "finished")
    }

    @Test func parsesLegacyProgressLine() throws {
        let line = "[download]  45.2% of    3.45MiB at    1.20MiB/s ETA 00:03"
        guard case .progress(let p) = YTDLPProgressParser.parse(line) else { Issue.record("not progress"); return }
        #expect(abs((p.fraction ?? 0) - 0.452) < 0.0001)
        #expect(p.totalBytes == Int64(3.45 * 1024 * 1024))
        #expect(p.speedBytesPerSecond == Double(Int64(1.20 * 1024 * 1024)))
        #expect(p.etaSeconds == 3)
    }

    @Test func parsesLegacyEstimatedAndUnknown() throws {
        guard case .progress(let p) = YTDLPProgressParser.parse("[download]   0.1% of ~ 120.00KiB at  Unknown B/s ETA Unknown") else { Issue.record("x"); return }
        #expect(p.isTotalEstimated)
        #expect(p.speedBytesPerSecond == nil)
        #expect(p.etaSeconds == nil)
    }

    @Test func parsesPlaylistItemDestinationAndArchive() {
        #expect(YTDLPProgressParser.parse("[download] Downloading item 3 of 12") == .playlistItem(index: 3, count: 12))
        #expect(YTDLPProgressParser.parse("[download] Destination: /tmp/x.m4a") == .destination("/tmp/x.m4a"))
        #expect(YTDLPProgressParser.parse("[download] abc: has already been recorded in the archive") == .alreadyInArchive)
        #expect(YTDLPProgressParser.parse("[ArchiveOrg] testmp3testfile: has already been recorded in the archive") == .alreadyInArchive)
    }

    @Test func parsesPostprocessorsErrorsWarningsAndFile() {
        #expect(YTDLPProgressParser.parse("LMPOST|started|ExtractAudio") == .postprocess("ExtractAudio"))
        #expect(YTDLPProgressParser.parse("[EmbedThumbnail] ffmpeg: Adding thumbnail") == .postprocess("EmbedThumbnail"))
        #expect(YTDLPProgressParser.parse("ERROR: [youtube] abc: Private video") == .error("[youtube] abc: Private video"))
        #expect(YTDLPProgressParser.parse("WARNING: something") == .warning("something"))
        #expect(YTDLPProgressParser.parse("LMFILE|/Users/x/Music/LocalMusic/.incoming/a/b [id].m4a") == .finalFile("/Users/x/Music/LocalMusic/.incoming/a/b [id].m4a"))
        #expect(YTDLPProgressParser.parse("[youtube] Extracting URL") == .other("[youtube] Extracting URL"))
    }

    @Test func clockParsing() {
        #expect(YTDLPProgressParser.parseClock("00:03") == 3)
        #expect(YTDLPProgressParser.parseClock("1:02:03") == 3723)
        #expect(YTDLPProgressParser.parseClock("Unknown") == nil)
    }
}
