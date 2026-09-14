import Foundation

public protocol TagWriter: Sendable {
    func write(_ tags: TrackTags, to file: URL) async throws
}

/// Picks a writer by container. Native writers rewrite only the metadata region, so the encoded
/// audio is byte-for-byte untouched.
public struct TagWriterService: Sendable {
    public let ffmpeg: FFmpegService

    public init(ffmpeg: FFmpegService) {
        self.ffmpeg = ffmpeg
    }

    public static let nativeExtensions: Set<String> = ["m4a", "m4b", "mp4", "mp3", "flac"]

    public func canWrite(fileExtension ext: String) -> Bool {
        Self.nativeExtensions.contains(ext.lowercased()) || (ffmpeg.ffmpeg != nil && ["ogg", "oga", "opus", "wav", "aiff", "aif", "mka", "webm"].contains(ext.lowercased()))
    }

    public func write(_ tags: TrackTags, to file: URL) async throws {
        let ext = file.pathExtension.lowercased()
        let writer: any TagWriter
        switch ext {
        case "m4a", "m4b", "mp4": writer = MP4TagWriter()
        case "mp3": writer = ID3TagWriter()
        case "flac": writer = FLACTagWriter()
        default:
            guard ffmpeg.ffmpeg != nil else {
                throw LocalMusicError(kind: .toolMissing, message: "Editing tags in .\(ext) files needs ffmpeg. Install it with: brew install ffmpeg")
            }
            writer = FFmpegTagWriter(ffmpeg: ffmpeg)
        }
        try await writer.write(tags.normalized, to: file)
        Log.info("tags written to \(file.lastPathComponent)", .metadata)
    }

    /// Writes `data` next to `file`, then swaps it in atomically, preserving the original on failure.
    static func replaceAtomically(_ file: URL, with data: Data) throws {
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).lmtmp")
        try data.write(to: tmp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

extension Data {
    mutating func appendBE32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendLE32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    func be32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (UInt32(self[startIndex + offset]) << 24) | (UInt32(self[startIndex + offset + 1]) << 16) | (UInt32(self[startIndex + offset + 2]) << 8) | UInt32(self[startIndex + offset + 3])
    }

    func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset]) | (UInt32(self[startIndex + offset + 1]) << 8) | (UInt32(self[startIndex + offset + 2]) << 16) | (UInt32(self[startIndex + offset + 3]) << 24)
    }

    func be24(at offset: Int) -> UInt32 {
        guard offset + 3 <= count else { return 0 }
        return (UInt32(self[startIndex + offset]) << 16) | (UInt32(self[startIndex + offset + 1]) << 8) | UInt32(self[startIndex + offset + 2])
    }

    func slice(_ offset: Int, _ length: Int) -> Data {
        let start = startIndex + offset
        let end = Swift.min(start + Swift.max(length, 0), endIndex)
        return start < end ? Data(self[start..<end]) : Data()
    }
}

enum ImageSniffer {
    static func mimeType(of data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if data.count > 12, data[data.startIndex + 8..<data.startIndex + 12] == Data("WEBP".utf8) { return "image/webp" }
        return "image/jpeg"
    }
}
