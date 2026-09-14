import Testing
import Foundation
@testable import LocalMusicCore

@Suite("MockDownloader")
struct MockDownloaderTests {
    @Test func producesPlayableWavAndProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMMock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockDownloader(stepDelay: .milliseconds(1))
        let req = DownloadRequest(url: URL(string: "https://example.com/watch?v=1")!, destinationDirectory: dir, format: .original, ffmpegDirectory: nil, archiveFile: nil)
        let counter = Counter()
        let result = try await mock.download(req, onProgress: { _ in counter.increment() }, onLog: { _ in })
        #expect(counter.value >= 20)
        #expect(result.fileURL.pathExtension == "wav")
        let meta = try await AudioMetadataReader.read(result.fileURL)
        #expect(abs(meta.duration - 3) < 0.1)
        #expect(meta.isPlayable)
    }

    @Test func failsOnDemand() async {
        let mock = MockDownloader(stepDelay: .milliseconds(1))
        let req = DownloadRequest(url: URL(string: "https://example.com/fail")!, destinationDirectory: FileManager.default.temporaryDirectory, format: .original, ffmpegDirectory: nil, archiveFile: nil)
        await #expect(throws: LocalMusicError.self) { try await mock.download(req, onProgress: { _ in }, onLog: { _ in }) }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
