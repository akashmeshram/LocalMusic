import Foundation

/// Thin wrapper over ffmpeg/ffprobe for probing and the one conversion the app performs itself.
public struct FFmpegService: Sendable {
    public struct AudioInfo: Sendable, Hashable {
        public var duration: TimeInterval
        public var codec: String?
        public var bitrate: Int?
        public var sampleRate: Int?
        public var channels: Int?
        public var formatName: String?
    }

    public let ffmpeg: URL?
    public let ffprobe: URL?

    public init(ffmpeg: URL?, ffprobe: URL?) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Extensions AVFoundation can play natively; anything else gets converted to M4A when possible.
    public static let nativelyPlayableExtensions: Set<String> = ["m4a", "mp4", "aac", "mp3", "flac", "wav", "aif", "aiff", "caf", "alac", "m4b"]

    public static func needsConversion(fileExtension: String) -> Bool {
        !nativelyPlayableExtensions.contains(fileExtension.lowercased())
    }

    /// Validates a file and reads stream facts. Throws `.invalidAudio` if ffprobe finds no audio.
    public func probe(_ file: URL) async throws -> AudioInfo {
        guard let ffprobe else {
            throw LocalMusicError(kind: .toolMissing, message: "ffprobe is not installed.")
        }
        let args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-select_streams", "a:0", file.path]
        let out = try await ProcessRunner.run(ffprobe, arguments: args)
        guard out.exitCode == 0, let data = out.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LocalMusicError(kind: .invalidAudio, message: "The file is not a readable audio file.", technicalDetails: out.stderr)
        }
        let format = json["format"] as? [String: Any] ?? [:]
        let stream = (json["streams"] as? [[String: Any]])?.first
        guard let stream else {
            throw LocalMusicError(kind: .invalidAudio, message: "The file contains no audio stream.", technicalDetails: out.stdout)
        }
        let duration = Double(format["duration"] as? String ?? "") ?? Double(stream["duration"] as? String ?? "") ?? 0
        return AudioInfo(
            duration: duration,
            codec: stream["codec_name"] as? String,
            bitrate: Int(format["bit_rate"] as? String ?? "") ?? Int(stream["bit_rate"] as? String ?? ""),
            sampleRate: Int(stream["sample_rate"] as? String ?? ""),
            channels: stream["channels"] as? Int,
            formatName: format["format_name"] as? String)
    }

    /// Converts to AAC in an M4A container at 256 kb/s, keeping tags and cover art.
    public func convertToM4A(_ input: URL, output: URL, onLog: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard let ffmpeg else {
            throw LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to convert this file. Install it with: brew install ffmpeg")
        }
        let args = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", input.path,
                    "-map", "0:a:0", "-map", "0:v?", "-c:a", "aac", "-b:a", "256k", "-c:v", "copy",
                    "-disposition:v", "attached_pic", "-map_metadata", "0", "-movflags", "+faststart", output.path]
        var log: [String] = []
        var code: Int32 = -1
        for try await event in ProcessRunner.stream(ffmpeg, arguments: args) {
            switch event {
            case .stdout(let l), .stderr(let l): log.append(l); onLog(l)
            case .exit(let c): code = c
            }
        }
        try Task.checkCancellation()
        guard code == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw LocalMusicError(kind: .toolFailed, message: "ffmpeg could not convert the file.", technicalDetails: "exit code \(code)\n" + log.joined(separator: "\n"))
        }
    }
}
