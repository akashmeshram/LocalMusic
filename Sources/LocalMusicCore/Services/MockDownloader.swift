import Foundation

/// Simulates the download engine for previews and UI work. Produces a real, playable WAV file
/// (a short sine tone) so the whole pipeline — organize, index, play — can be exercised offline.
public struct MockDownloader: MediaDownloading {
    public var stepDelay: Duration
    public var failURLsContaining: String?

    public init(stepDelay: Duration = .milliseconds(120), failURLsContaining: String? = "fail") {
        self.stepDelay = stepDelay
        self.failURLsContaining = failURLsContaining
    }

    public func probe(url: URL) async throws -> MediaProbe {
        try await Task.sleep(for: stepDelay)
        if url.absoluteString.contains("playlist") {
            let entries = (1...5).map { i in
                MediaEntry(id: "mock\(i)", url: URL(string: "https://example.com/watch?v=mock\(i)")!,
                           title: "Mock Track \(i)", uploader: "Mock Artist", duration: 120 + Double(i * 7), playlistIndex: i)
            }
            return .playlist(PlaylistInfo(title: "Mock Playlist", url: url, uploader: "Mock Artist", entries: entries))
        }
        return .single(MediaEntry(id: url.lastPathComponent, url: url, title: "Mock Song", uploader: "Mock Artist", duration: 3))
    }

    public func download(_ request: DownloadRequest, onProgress: @escaping @Sendable (DownloadProgress) -> Void, onLog: @escaping @Sendable (String) -> Void) async throws -> DownloadResult {
        onLog("[mock] starting \(request.url.absoluteString)")
        let total: Int64 = 3_200_000
        for step in 0...20 {
            try await Task.sleep(for: stepDelay)
            let done = total * Int64(step) / 20
            onProgress(DownloadProgress(fraction: Double(step) / 20, downloadedBytes: done, totalBytes: total,
                                        speedBytesPerSecond: 1_400_000, etaSeconds: (20 - step) / 4, phase: "download"))
        }
        if let needle = failURLsContaining, request.url.absoluteString.contains(needle) {
            throw LocalMusicError(kind: .videoUnavailable, message: "This media is unavailable (mock).", technicalDetails: "[mock] simulated failure")
        }
        onProgress(DownloadProgress(fraction: 1, phase: "ExtractAudio"))
        try await Task.sleep(for: stepDelay)
        try FileManager.default.createDirectory(at: request.destinationDirectory, withIntermediateDirectories: true)
        let n = Int.random(in: 1...999)
        let file = request.destinationDirectory.appendingPathComponent("Mock Song \(n) [mock].wav")
        try Self.sineWave(seconds: 3, frequency: 220 + Double(n % 5) * 110).write(to: file)
        var meta = SourceMetadata()
        meta.title = "Mock Song \(n)"
        meta.artist = "Mock Artist"
        meta.album = "Mock Album"
        meta.releaseYear = 2024
        meta.trackNumber = n % 12 + 1
        meta.duration = 3
        meta.webpageURL = request.url
        meta.extractor = "Mock"
        onLog("[mock] wrote \(file.lastPathComponent)")
        return DownloadResult(fileURL: file, infoJSONURL: nil, metadata: meta, log: "[mock] ok")
    }

    /// 16-bit mono PCM WAV.
    public static func sineWave(seconds: Double, frequency: Double, sampleRate: Int = 44_100) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let envelope = min(1, min(t * 8, (seconds - t) * 8))
            let sample = Int16(sin(2 * .pi * frequency * t) * 0.4 * envelope * Double(Int16.max))
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
