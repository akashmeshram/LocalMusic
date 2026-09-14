import Testing
import Foundation
@testable import LocalMusicCore

@Suite("YTDLPService")
struct YTDLPServiceTests {
    @Test func argumentsPassURLLastAfterDoubleDash() {
        let url = URL(string: "https://example.com/watch?v=--evil")!
        let req = DownloadRequest(url: url, destinationDirectory: URL(fileURLWithPath: "/tmp/in"), format: .original,
                                  ffmpegDirectory: URL(fileURLWithPath: "/opt/homebrew/bin"), archiveFile: URL(fileURLWithPath: "/tmp/a.txt"))
        let args = YTDLPService.arguments(for: req)
        #expect(args.suffix(2) == ["--", url.absoluteString])
        #expect(args.contains("--no-playlist"))
        #expect(args.contains("--embed-thumbnail"))
        #expect(args.contains("--ffmpeg-location"))
        #expect(args.contains("--download-archive"))
        #expect(!args.contains(where: { $0.contains("$") || $0.contains("|") && !$0.hasPrefix("download:") && !$0.hasPrefix("postprocess:") && !$0.hasPrefix("after_move:") }))
    }

    @Test func formatPolicies() {
        func args(_ f: PreferredFormat, ffmpeg: Bool) -> [String] {
            YTDLPService.arguments(for: DownloadRequest(url: URL(string: "https://e.com")!, destinationDirectory: URL(fileURLWithPath: "/tmp"), format: f, ffmpegDirectory: ffmpeg ? URL(fileURLWithPath: "/x") : nil, archiveFile: nil))
        }
        #expect(args(.original, ffmpeg: true).contains("best"))
        #expect(args(.m4a, ffmpeg: true).contains("m4a"))
        #expect(args(.mp3, ffmpeg: true).contains("mp3"))
        let none = args(.mp3, ffmpeg: false)
        #expect(!none.contains("--extract-audio"))
        #expect(!none.contains("--embed-metadata"))
    }

    @Test func parsesSingleProbe() {
        let json: [String: Any] = ["id": "abc", "title": "Song", "uploader": "Up", "duration": 200.5, "webpage_url": "https://www.youtube.com/watch?v=abc", "thumbnail": "https://i/x.jpg"]
        guard case .single(let e) = YTDLPService.parseProbe(json, requestedURL: URL(string: "https://youtu.be/abc")!) else { Issue.record("x"); return }
        #expect(e.id == "abc" && e.title == "Song" && e.duration == 200.5 && e.uploader == "Up")
        #expect(e.thumbnailURL?.absoluteString == "https://i/x.jpg")
    }

    @Test func parsesFlatPlaylistProbe() {
        let json: [String: Any] = [
            "_type": "playlist", "title": "My List", "extractor": "youtube:tab",
            "entries": [
                ["id": "a1", "title": "One", "url": "https://www.youtube.com/watch?v=a1", "duration": 100],
                ["id": "a2", "title": "[Private video]"],
                ["id": "a3", "title": "Three", "thumbnails": [["url": "https://t/1.jpg", "width": 100], ["url": "https://t/2.jpg", "width": 400]]],
            ],
        ]
        guard case .playlist(let p) = YTDLPService.parseProbe(json, requestedURL: URL(string: "https://youtube.com/playlist?list=x")!) else { Issue.record("x"); return }
        #expect(p.title == "My List")
        #expect(p.entries.count == 3)
        #expect(p.entries[1].title == "Untitled 2")
        #expect(p.entries[2].url.absoluteString == "https://www.youtube.com/watch?v=a3")
        #expect(p.entries[2].thumbnailURL?.absoluteString == "https://t/2.jpg")
    }

    @Test func parsesInfoJSON() {
        let json: [String: Any] = ["title": "Artist - Song (Official Video)", "track": "Song", "artist": "Artist", "album": "Album", "release_year": 2019, "upload_date": "20190102", "duration": 180, "extractor_key": "Youtube", "webpage_url": "https://www.youtube.com/watch?v=abc"]
        let m = YTDLPService.parseInfo(json)
        #expect(m.track == "Song" && m.artist == "Artist" && m.album == "Album" && m.releaseYear == 2019 && m.duration == 180)
        #expect(m.extractor == "Youtube")
        #expect(m.uploadDate != nil)
    }
}
