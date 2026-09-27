import Testing
import Foundation
import AppKit
@testable import LocalMusicCore

@Suite("Mix")
struct MixTests {
    func input(_ title: String, _ seconds: Double) -> MixBuilder.Input {
        MixBuilder.Input(url: URL(fileURLWithPath: "/tmp/\(title).m4a"), title: title, duration: seconds)
    }

    @Test func overlapIsCappedByHalfOfEachNeighbour() {
        #expect(MixBuilder.overlap(crossfade: 3, before: 200, after: 180) == 3)
        #expect(MixBuilder.overlap(crossfade: 3, before: 3, after: 200) == 1.5)
        #expect(MixBuilder.overlap(crossfade: 3, before: 200, after: 1) == 0.5)
        #expect(MixBuilder.overlap(crossfade: 0, before: 200, after: 200) == 0)
        #expect(MixBuilder.overlap(crossfade: 3, before: 0.04, after: 200) == 0) // below the minimum → hard cut
    }

    @Test func planComputesChaptersAndTotal() {
        let plan = MixBuilder.plan([input("A", 100), input("B", 50), input("C", 4)], crossfade: 3)
        #expect(plan.overlaps == [3, 2])
        #expect(plan.chapters.map(\.title) == ["A", "B", "C"])
        #expect(plan.chapters[0].start == 0 && plan.chapters[0].end == 100)
        #expect(plan.chapters[1].start == 97 && plan.chapters[1].end == 147)
        #expect(plan.chapters[2].start == 145 && plan.chapters[2].end == 149)
        #expect(plan.totalDuration == 149)
    }

    @Test func planWithHardCutsIsPlainSum() {
        let plan = MixBuilder.plan([input("A", 10), input("B", 20)], crossfade: 0)
        #expect(plan.overlaps == [0])
        #expect(plan.totalDuration == 30)
        #expect(plan.chapters[1].start == 10)
    }

    @Test func filterGraphUsesCrossfadeOrConcatPerBoundary() {
        let graph = MixBuilder.filterGraph(count: 3, overlaps: [2.5, 0])
        #expect(graph.contains("[0:a]aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo[a0]"))
        #expect(graph.contains("[a0][a1]acrossfade=d=2.500:c1=tri:c2=tri[x1]"))
        #expect(graph.contains("[x1][a2]concat=n=2:v=0:a=1[out]"))
        #expect(MixBuilder.filterGraph(count: 1, overlaps: []).hasSuffix("[a0]anull[out]"))
    }

    @Test func argumentsAreLiteralAndEndWithOutput() {
        let out = URL(fileURLWithPath: "/tmp/mix.mp3")
        let args = MixBuilder.arguments(inputs: [input("A", 10), input("B; rm -rf /", 10)], overlaps: [1], bitrateKbps: 999, output: out)
        #expect(args.last == out.path)
        #expect(args.filter { $0 == "-i" }.count == 2)
        #expect(args.contains("/tmp/B; rm -rf /.m4a")) // passed as one argv entry, never a shell string
        #expect(args.contains("320k")) // bitrate clamped
        #expect(args.contains("libmp3lame"))
        #expect(!args.joined(separator: " ").contains("sh -c"))
    }

    // MARK: Collage

    static func solid(_ color: NSColor, size: Int = 64) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    @Test func layoutsCoverTheSquareWithoutOverlap() {
        for n in [1, 2, 3, 4, 5, 6, 7, 9, 12] {
            let rects = ArtworkCollage.layout(count: n)
            let area = rects.reduce(0) { $0 + $1.width * $1.height }
            #expect(abs(area - 1) < 1e-9, "count \(n) area \(area)")
            for (i, a) in rects.enumerated() {
                for b in rects[(i + 1)...] {
                    #expect(!a.intersects(b) || a.intersection(b).width * a.intersection(b).height < 1e-9, "count \(n) overlap")
                }
            }
        }
        #expect(ArtworkCollage.layout(count: 2).count == 4)
        #expect(ArtworkCollage.layout(count: 3).count == 4)
        #expect(ArtworkCollage.layout(count: 4).count == 4)
        #expect(ArtworkCollage.layout(count: 5).count == 9)
        #expect(ArtworkCollage.layout(count: 20).count == 9)
        #expect(ArtworkCollage.layout(count: 4).allSatisfy { abs($0.width - $0.height) < 1e-9 }) // square tiles, no cropping
    }

    @Test func tilesWrapToFillEveryCell() {
        #expect(ArtworkCollage.tiles(for: 2) == [0, 1, 1, 0])
        #expect(ArtworkCollage.tiles(for: 3) == [0, 1, 2, 0])
        #expect(ArtworkCollage.tiles(for: 5) == [0, 1, 2, 3, 4, 0, 1, 2, 3])
        #expect(ArtworkCollage.tiles(for: 7) == [0, 1, 2, 3, 4, 5, 6, 0, 1])
        #expect(ArtworkCollage.tiles(for: 20).count == 9)
    }

    @Test func distinctDedupesByAlbumThenByBytes() {
        let red = Self.solid(.red), blue = Self.solid(.blue), green = Self.solid(.green)
        let sources = [
            ArtworkCollage.Source(albumKey: "abbey road|the beatles", image: red),
            ArtworkCollage.Source(albumKey: "abbey road|the beatles", image: blue),  // same album, different thumbnail → dropped
            ArtworkCollage.Source(albumKey: nil, image: red),                       // same bytes → dropped
            ArtworkCollage.Source(albumKey: "help!|the beatles", image: green),
            ArtworkCollage.Source(albumKey: nil, image: blue),                      // unknown album, new bytes → kept
        ]
        #expect(ArtworkCollage.distinct(sources) == [red, green, blue])
        #expect(ArtworkCollage.albumKey(album: " Help! ", albumArtist: nil, artist: "The Beatles") == "help!|the beatles")
        #expect(ArtworkCollage.albumKey(album: "", albumArtist: "x", artist: nil) == nil)
    }

    @Test func composeKeepsSingleCoverUnchangedAndRendersCollageOtherwise() throws {
        let red = Self.solid(.red), blue = Self.solid(.blue)
        let same = [ArtworkCollage.Source(albumKey: "a|x", image: red), ArtworkCollage.Source(albumKey: "a|x", image: blue)]
        #expect(ArtworkCollage.compose(same) == red)
        #expect(ArtworkCollage.compose([]) == nil)

        let mixed = [ArtworkCollage.Source(albumKey: "a|x", image: red), ArtworkCollage.Source(albumKey: "b|y", image: blue)]
        let collage = try #require(ArtworkCollage.compose(mixed))
        #expect(collage != red && collage != blue)
        let dims = try #require(ImageInfo.dimensions(of: collage))
        #expect(dims.0 == ArtworkCollage.side && dims.1 == ArtworkCollage.side)
        let bitmap = try #require(NSBitmapImageRep(data: collage))
        // Checkerboard: red top-left and bottom-right, blue top-right and bottom-left.
        let topLeft = try #require(bitmap.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
        let topRight = try #require(bitmap.colorAt(x: 1100, y: 100)?.usingColorSpace(.deviceRGB))
        let bottomRight = try #require(bitmap.colorAt(x: 1100, y: 1100)?.usingColorSpace(.deviceRGB))
        #expect(topLeft.redComponent > 0.8 && topLeft.blueComponent < 0.2)
        #expect(topRight.blueComponent > 0.8 && topRight.redComponent < 0.2)
        #expect(bottomRight.redComponent > 0.8 && bottomRight.blueComponent < 0.2)
    }

    // MARK: Chapters

    @Test func id3ChaptersRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMMix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.mp3")
        try Data((0..<500).map { UInt8($0 % 200) }).write(to: url)

        var tags = TrackTags(title: "Mix", artist: "Various Artists", album: "Mixes")
        tags.chapters = [TrackChapter(title: "Ône", start: 0, end: 100.25), TrackChapter(title: "Two", start: 97, end: 150)]
        try await ID3TagWriter().write(tags, to: url)
        let parsed = ID3TagWriter.parse(try Data(contentsOf: url))
        let chapters = ID3TagWriter.chapters(in: parsed.frames)
        #expect(chapters.map(\.title) == ["Ône", "Two"])
        #expect(chapters[0].end == 100.25 && chapters[1].start == 97)
        let toc = try #require(parsed.frames.first { $0.id == "CTOC" })
        #expect(toc.data.starts(with: Data("toc".utf8) + [0, 0x03, 2]))

        // Editing plain tags later leaves chapters untouched; writing new chapters replaces them.
        try await ID3TagWriter().write(TrackTags(title: "Renamed"), to: url)
        #expect(ID3TagWriter.chapters(in: ID3TagWriter.parse(try Data(contentsOf: url)).frames).count == 2)
        tags.chapters = [TrackChapter(title: "Only", start: 0, end: 5)]
        try await ID3TagWriter().write(tags, to: url)
        let again = ID3TagWriter.parse(try Data(contentsOf: url)).frames
        #expect(ID3TagWriter.chapters(in: again).map(\.title) == ["Only"])
        #expect(again.filter { $0.id == "CTOC" }.count == 1)
    }
}
