import Testing
import Foundation
import AppKit
@testable import LocalMusicCore

@Suite("Video export")
struct VideoTests {
    @Test func filterGraphFitsThePhotoOverABlurredCopy() {
        let graph = VideoBuilder.filterGraph(width: 1920, height: 1080)
        // Background: cover the frame, blur and darken. Foreground: fit inside, centred.
        #expect(graph.contains("scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080"))
        #expect(graph.contains("boxblur"))
        #expect(graph.contains("scale=1920:1080:force_original_aspect_ratio=decrease"))
        #expect(graph.contains("overlay=(W-w)/2:(H-h)/2"))
        #expect(graph.hasSuffix("format=yuv420p[v]"))
    }

    @Test func argumentsAreLiteralAndYouTubeReady() {
        let args = VideoBuilder.arguments(image: URL(fileURLWithPath: "/tmp/a photo; rm -rf.png"),
                                          audio: URL(fileURLWithPath: "/tmp/mix.mp3"),
                                          duration: 123.4, output: URL(fileURLWithPath: "/tmp/out.mp4"))
        #expect(args.last == "/tmp/out.mp4")
        #expect(args.contains("/tmp/a photo; rm -rf.png")) // one argv entry, never a shell string
        // Image is input 0 looped at the video frame rate; audio is input 1.
        let imageIndex = args.firstIndex(of: "/tmp/a photo; rm -rf.png")!
        let audioIndex = args.firstIndex(of: "/tmp/mix.mp3")!
        #expect(imageIndex < audioIndex)
        #expect(args[imageIndex - 1] == "-i" && args[audioIndex - 1] == "-i")
        #expect(args.contains("-loop") && args.contains("1"))
        #expect(args.contains("libx264") && args.contains("aac") && args.contains("+faststart") && args.contains("yuv420p"))
        #expect(args.contains("stillimage"))
        #expect(args.contains("-map") && args.contains("[v]") && args.contains("1:a"))
        #expect(args.contains("-t") && args.contains("123.400"))
        #expect(args.contains("-progress") && args.contains("pipe:1"))
        #expect(!args.joined(separator: " ").contains("sh -c"))
    }

    @Test func timestampsUseYouTubeChapterFormat() {
        #expect(VideoBuilder.timestamp(0) == "0:00")
        #expect(VideoBuilder.timestamp(59.9) == "0:59")
        #expect(VideoBuilder.timestamp(201) == "3:21")
        #expect(VideoBuilder.timestamp(3600) == "1:00:00")
        #expect(VideoBuilder.timestamp(3725.4) == "1:02:05")
    }

    @Test func descriptionListsChaptersAndSources() {
        let chapters = [TrackChapter(title: "Carefree", start: 0, end: 203),
                        TrackChapter(title: "Test of MP3 File", start: 201, end: 212),
                        TrackChapter(title: "Investigations", start: 209, end: 303)]
        let text = VideoBuilder.description(title: "Live Mix", artist: "Various Artists", chapters: chapters,
                                            sources: ["https://a.example/1", "https://b.example/2"])
        #expect(text.hasPrefix("Live Mix\nVarious Artists\n"))
        #expect(text.contains("Tracklist:\n0:00 Carefree\n3:21 Test of MP3 File\n3:29 Investigations\n"))
        #expect(text.contains("Sources:\nhttps://a.example/1\nhttps://b.example/2"))
        #expect(text.hasSuffix("\n"))

        let plain = VideoBuilder.description(title: "Single", artist: nil, chapters: [], sources: [])
        #expect(plain == "Single\n")
    }

    @Test func id3CommentRoundTripsThroughOwnParser() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMVideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.mp3")
        try Data((0..<500).map { UInt8($0 % 200) }).write(to: url)
        let comment = "Mix of 2 songs\n1. Ärtist – Song\n   https://a.example/1\n"
        try await ID3TagWriter().write(TrackTags(title: "T", comment: comment), to: url)
        let frames = ID3TagWriter.parse(try Data(contentsOf: url)).frames
        #expect(ID3TagWriter.comment(in: frames) == comment)
        #expect(ID3TagWriter.comment(in: []) == nil)
        // Latin-1 encoded COMM from other taggers decodes too.
        var latin = Data([0x00]); latin.append(Data("eng".utf8)); latin.append(0); latin.append(Data("caf\u{E9}".data(using: .isoLatin1)!))
        #expect(ID3TagWriter.comment(in: [ID3TagWriter.Frame(id: "COMM", data: latin)]) == "café")
    }

    @Test func progressLinesYieldAFraction() {
        #expect(VideoBuilder.progress(line: "out_time_us=61700000", duration: 123.4) == 0.5)
        #expect(VideoBuilder.progress(line: "out_time_ms=61700000", duration: 123.4) == 0.5)
        #expect(VideoBuilder.progress(line: "out_time_us=999999999", duration: 10) == 1)
        #expect(VideoBuilder.progress(line: "frame=12", duration: 10) == nil)
        #expect(VideoBuilder.progress(line: "out_time_us=5", duration: 0) == nil)
    }

    @Test func normalizedImageIsPNGWithSameSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMVideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("photo.jpg")
        try MixTests.solid(.orange, size: 300).write(to: jpeg) // PNG bytes with a .jpg name: NSImage sniffs content
        let out = dir.appendingPathComponent("frame.png")
        try VideoBuilder.normalizeImage(jpeg, to: out)
        let dims = try #require(ImageInfo.dimensions(of: try Data(contentsOf: out)))
        #expect(dims.0 == 300 && dims.1 == 300)
        #expect(try Data(contentsOf: out).starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(throws: (any Error).self) { try VideoBuilder.normalizeImage(dir.appendingPathComponent("missing.png"), to: out) }
    }

    /// Real render: a 1-second sine WAV plus a square photo → 1920×1080 H.264/AAC MP4.
    @Test func buildsAPlayableMP4() async throws {
        guard let ffmpeg = ToolLocator.locate(.ffmpeg), let ffprobe = ToolLocator.locate(.ffprobe) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMVideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try MockDownloader.sineWave(seconds: 2, frequency: 440).write(to: wav)
        let photo = dir.appendingPathComponent("photo.png")
        try MixTests.solid(.purple, size: 400).write(to: photo)
        let out = dir.appendingPathComponent("video.mp4")

        var fractions: [Double] = []
        let box = FractionBox()
        try await VideoBuilder(ffmpeg: ffmpeg).build(image: photo, audio: wav, duration: 2, output: out,
                                                     onProgress: { box.append($0) })
        fractions = box.values
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(fractions.last.map { $0 >= 0.9 } == true, "progress \(fractions)")

        let probe = try await ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", out.path])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any])
        let streams = try #require(json["streams"] as? [[String: Any]])
        let video = try #require(streams.first { $0["codec_type"] as? String == "video" })
        let audio = try #require(streams.first { $0["codec_type"] as? String == "audio" })
        #expect(video["codec_name"] as? String == "h264")
        #expect(video["width"] as? Int == 1920 && video["height"] as? Int == 1080)
        #expect(video["pix_fmt"] as? String == "yuv420p")
        #expect(audio["codec_name"] as? String == "aac")
        let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        #expect(abs(duration - 2) < 0.3, "duration \(duration)")
    }
}

final class FractionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.withLock { _values } }
    func append(_ v: Double) { lock.withLock { _values.append(v) } }
}
