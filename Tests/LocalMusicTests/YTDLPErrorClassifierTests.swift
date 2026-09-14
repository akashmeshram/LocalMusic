import Testing
import Foundation
@testable import LocalMusicCore

@Suite("YTDLPErrorClassifier")
struct YTDLPErrorClassifierTests {
    private func kind(_ output: String, code: Int32 = 1) -> LocalMusicError.Kind {
        YTDLPErrorClassifier.classify(output: output, exitCode: code).kind
    }

    @Test func classifiesCommonFailures() {
        #expect(kind("ERROR: [youtube] abc: Private video. Sign in if you've been granted access") == .privateVideo)
        #expect(kind("ERROR: [youtube] abc: Video unavailable") == .videoUnavailable)
        #expect(kind("ERROR: [youtube] abc: The uploader has not made this video available in your country") == .geoRestricted)
        #expect(kind("ERROR: Unsupported URL: https://example.com/x") == .unsupportedURL)
        #expect(kind("ERROR: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>") == .network)
        #expect(kind("ERROR: unable to write data: [Errno 28] No space left on device") == .lowDiskSpace)
        #expect(kind("ERROR: unable to open for writing: [Errno 13] Permission denied") == .permissionDenied)
        #expect(kind("ERROR: Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path") == .toolMissing)
        #expect(kind("ERROR: [youtube] abc: Sign in to confirm your age") == .loginRequired)
        #expect(kind("ERROR: [youtube] abc: Sign in to confirm you’re not a bot") == .loginRequired)
    }

    @Test func keepsTechnicalDetailsWithoutProgressNoise() {
        let out = "LMPROG|downloading|1|2|NA|NA|NA|NA|NA\n[youtube] x\nERROR: Video unavailable"
        let err = YTDLPErrorClassifier.classify(output: out, exitCode: 1)
        #expect(err.technicalDetails?.contains("LMPROG") == false)
        #expect(err.technicalDetails?.contains("ERROR: Video unavailable") == true)
        #expect(err.technicalDetails?.hasPrefix("exit code: 1") == true)
    }

    @Test func unknownErrorsSurfaceFirstErrorLine() {
        let err = YTDLPErrorClassifier.classify(output: "ERROR: something odd happened", exitCode: 1)
        #expect(err.kind == .unknown)
        #expect(err.message.contains("something odd happened"))
    }
}
