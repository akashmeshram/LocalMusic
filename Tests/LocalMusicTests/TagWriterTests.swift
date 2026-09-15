import Testing
import Foundation
import AVFoundation
@testable import LocalMusicCore

@Suite("TagWriters")
struct TagWriterTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LMTags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 1, count: 32)

    @Test func id3RoundTripPreservesAudioAndForeignFrames() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Build a v2.3 tag with TIT2 "Old" (latin1) and a USLT frame, followed by fake audio.
        var body = Data()
        func frame(_ id: String, _ payload: Data) { body.append(Data(id.utf8)); body.appendBE32(UInt32(payload.count)); body.appendBE16(0); body.append(payload) }
        frame("TIT2", Data([0]) + Data("Old".utf8))
        frame("USLT", Data([0]) + Data("eng".utf8) + Data([0]) + Data([0]) + Data("la la la".utf8))
        var file = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]); file.appendBE32(ID3TagWriter.toSyncsafe(body.count)); file.append(body)
        let audio = Data((0..<2000).map { UInt8($0 % 251) })
        file.append(audio)
        let url = dir.appendingPathComponent("t.mp3")
        try file.write(to: url)

        let tags = TrackTags(title: "Jóga 🎵", artist: "Björk", albumArtist: "Björk", album: "Homogenic", trackNumber: 3, trackTotal: 10, discNumber: 1, genre: "Electronic", year: 1997, composer: "Björk", musicBrainzRecordingID: "rec-1", artwork: .replace(Self.png))
        try await ID3TagWriter().write(tags, to: url)

        let written = try Data(contentsOf: url)
        let parsed = ID3TagWriter.parse(written)
        #expect(written.suffix(audio.count) == audio)
        func text(_ id: String) -> String? { parsed.frames.first { $0.id == id }.flatMap(ID3TagWriter.textValue) }
        #expect(text("TIT2") == "Jóga 🎵")
        #expect(text("TPE1") == "Björk")
        #expect(text("TALB") == "Homogenic")
        #expect(text("TRCK") == "3/10")
        #expect(text("TPOS") == "1")
        #expect(text("TDRC") == "1997")
        #expect(text("TCON") == "Electronic")
        #expect(parsed.frames.contains { $0.id == "USLT" })
        #expect(parsed.frames.filter { $0.id == "TIT2" }.count == 1)
        let apic = parsed.frames.first { $0.id == "APIC" }
        #expect(apic?.data.suffix(Self.png.count) == Self.png)
        #expect(parsed.frames.contains { $0.id == "UFID" })

        // Second write with .remove drops the picture and keeps everything consistent.
        var tags2 = tags; tags2.artwork = .remove; tags2.title = "Second"
        try await ID3TagWriter().write(tags2, to: url)
        let parsed2 = ID3TagWriter.parse(try Data(contentsOf: url))
        #expect(!parsed2.frames.contains { $0.id == "APIC" })
        #expect(parsed2.frames.first { $0.id == "TIT2" }.flatMap(ID3TagWriter.textValue) == "Second")
        #expect(try Data(contentsOf: url).suffix(audio.count) == audio)
    }

    @Test func id3WritesTagOntoUntaggedFile() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("raw.mp3")
        let audio = Data([0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 7, count: 500))
        try audio.write(to: url)
        try await ID3TagWriter().write(TrackTags(title: "New"), to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: [0x49, 0x44, 0x33, 0x04]))
        #expect(data.suffix(audio.count) == audio)
        #expect(ID3TagWriter.parse(data).frames.first?.id == "TIT2")
    }

    @Test func flacRoundTrip() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var file = Data("fLaC".utf8)
        let streamInfo = Data(repeating: 0xAB, count: 34)
        file.append(0x00); file.append(contentsOf: [0, 0, 34]); file.append(streamInfo)
        let comments = FLACTagWriter.buildComments(vendor: "reference libFLAC", comments: ["TITLE=Old", "REPLAYGAIN_TRACK_GAIN=-6.5 dB"])
        file.append(0x84); file.append(contentsOf: [0, UInt8(comments.count >> 8), UInt8(comments.count & 0xFF)]); file.append(comments)
        let audio = Data([0xFF, 0xF8] + [UInt8](repeating: 3, count: 1000))
        file.append(audio)
        let url = dir.appendingPathComponent("t.flac")
        try file.write(to: url)

        let tags = TrackTags(title: "Sky", artist: "Artist", album: "Album", trackNumber: 2, year: 2020, artwork: .replace(Self.png))
        try await FLACTagWriter().write(tags, to: url)
        let data = try Data(contentsOf: url)
        let (blocks, offset) = try #require(FLACTagWriter.parse(data))
        #expect(data.slice(offset, data.count - offset) == audio)
        #expect(blocks.first?.type == 0 && blocks.first?.data == streamInfo)
        let vc = try #require(blocks.first { $0.type == 4 })
        let parsed = FLACTagWriter.parseComments(vc.data)
        #expect(parsed.vendor == "reference libFLAC")
        #expect(parsed.comments.contains("TITLE=Sky"))
        #expect(parsed.comments.contains("TRACKNUMBER=2"))
        #expect(parsed.comments.contains("DATE=2020"))
        #expect(parsed.comments.contains("REPLAYGAIN_TRACK_GAIN=-6.5 dB"))
        #expect(!parsed.comments.contains("TITLE=Old"))
        #expect(blocks.contains { $0.type == 6 && $0.data.suffix(Self.png.count) == Self.png })
        #expect(blocks.last?.type == 1)
    }

    @Test func mp4RoundTripThroughAVFoundation() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.m4a")
        try await Self.makeAAC(at: url)
        let before = try await AudioMetadataReader.read(url)
        #expect(before.duration > 0.5)

        let jpeg = try #require(Self.solidJPEG())
        let tags = TrackTags(title: "Tagged ✓", artist: "Someone", albumArtist: "Someone", album: "An Album", trackNumber: 4, trackTotal: 12, discNumber: 2, genre: "Ambient", year: 2021, composer: "C", musicBrainzRecordingID: "rec-123", musicBrainzReleaseID: "rel-456", artwork: .replace(jpeg))
        try await MP4TagWriter().write(tags, to: url)
        let after = try await AudioMetadataReader.read(url)
        let allItems = try await AVURLAsset(url: url).load(.metadata)
        let mbItems = allItems.filter { MP4TagWriter.isMusicBrainzItem($0) }
        #expect(mbItems.count == 2)
        let trackIDItem = mbItems.first { ($0.identifier.flatMap { AVMetadataItem.key(forIdentifier: $0) as? String }) == "com.apple.iTunes.MusicBrainz Track Id" }
        #expect(try await trackIDItem?.load(.stringValue) == "rec-123")
        #expect(after.title == "Tagged ✓")
        #expect(after.artist == "Someone")
        #expect(after.albumArtist == "Someone")
        #expect(after.album == "An Album")
        #expect(after.trackNumber == 4 && after.trackTotal == 12)
        #expect(after.discNumber == 2)
        #expect(after.genre == "Ambient")
        #expect(after.year == 2021)
        #expect(after.composer == "C")
        #expect(after.artwork != nil)
        #expect(abs(after.duration - before.duration) < 0.1)

        var tags2 = tags; tags2.artwork = .remove; tags2.album = nil; tags2.musicBrainzRecordingID = nil; tags2.musicBrainzReleaseID = nil
        try await MP4TagWriter().write(tags2, to: url)
        let third = try await AudioMetadataReader.read(url)
        #expect(third.artwork == nil && third.album == nil && third.title == "Tagged ✓")
        let remaining = try await AVURLAsset(url: url).load(.metadata).filter { MP4TagWriter.isMusicBrainzItem($0) }
        #expect(remaining.isEmpty)
        #expect(MP4TagWriter.item(AVMetadataIdentifier("itsk/----:bogus"), "x" as NSString) == nil)
    }

    /// Encodes one second of silence as AAC.
    static func makeAAC(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let frames = 44100
        let pcm = MockDownloader.sineWave(seconds: 1, frequency: 440).suffix(frames * 2)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: pcm.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &block)
        try pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: pcm.count) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        input.append(sample!)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LocalMusicError(kind: .unknown, message: "writer failed") }
    }

    static func solidJPEG() -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return rep?.representation(using: .jpeg, properties: [:])
    }
}

import AppKit
