import Foundation
import AppKit

/// Turns one audio file plus one still image into an upload-ready MP4: the photo fitted inside
/// the frame over a blurred, darkened copy of itself, H.264 video and AAC audio.
public struct VideoBuilder: Sendable {
    public static let width = 1920
    public static let height = 1080
    public static let frameRate = 1
    public static let audioBitrateKbps = 192

    public let ffmpeg: URL?

    public init(ffmpeg: URL?) {
        self.ffmpeg = ffmpeg
    }

    // MARK: Pure helpers

    /// Input 1 is the image. The background covers the frame (then blur + darken); the
    /// foreground fits inside it and sits centred on top.
    public static func filterGraph(width: Int = width, height: Int = height) -> String {
        let bg = "[0:v]scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height),boxblur=luma_radius=24:luma_power=3:chroma_radius=24:chroma_power=3,eq=brightness=-0.18:saturation=0.85[bg]"
        let fg = "[0:v]scale=\(width):\(height):force_original_aspect_ratio=decrease[fg]"
        let out = "[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]"
        return [bg, fg, out].joined(separator: ";")
    }

    public static func arguments(image: URL, audio: URL, duration: TimeInterval, output: URL,
                                 width: Int = width, height: Int = height) -> [String] {
        [
            "-y", "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-progress", "pipe:1",
            "-loop", "1", "-framerate", "\(frameRate)", "-i", image.path,
            "-i", audio.path,
            "-filter_complex", filterGraph(width: width, height: height),
            "-map", "[v]", "-map", "1:a",
            "-c:v", "libx264", "-preset", "medium", "-tune", "stillimage", "-crf", "20",
            "-r", "\(frameRate)", "-g", "\(frameRate * 5)", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "\(audioBitrateKbps)k", "-ar", "44100", "-ac", "2",
            "-t", String(format: "%.3f", max(0, duration)),
            "-movflags", "+faststart", "-f", "mp4", output.path,
        ]
    }

    /// `m:ss` below an hour, `h:mm:ss` above, as YouTube expects in descriptions.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Text to paste into the YouTube description: title, artist, timestamped track list and sources.
    public static func description(title: String, artist: String?, chapters: [TrackChapter], sources: [String]) -> String {
        var lines = [title]
        if let artist, !artist.isEmpty { lines.append(artist) }
        if !chapters.isEmpty {
            lines.append("")
            lines.append("Tracklist:")
            for c in chapters { lines.append("\(timestamp(c.start)) \(c.title)") }
        }
        let links = sources.filter { !$0.isEmpty }
        if !links.isEmpty {
            lines.append("")
            lines.append("Sources:")
            lines += links
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Fraction done from one line of `-progress pipe:1` output (`out_time_us=…`; older
    /// builds label the same microsecond value `out_time_ms`).
    public static func progress(line: String, duration: TimeInterval) -> Double? {
        guard duration > 0 else { return nil }
        for key in ["out_time_us=", "out_time_ms="] where line.hasPrefix(key) {
            guard let us = Double(line.dropFirst(key.count)) else { return nil }
            return min(1, max(0, us / 1_000_000 / duration))
        }
        return nil
    }

    /// Re-encodes any image NSImage can read (JPEG, PNG, HEIC, TIFF…) into a plain PNG so
    /// ffmpeg always gets a format it decodes, with orientation already applied.
    public static func normalizeImage(_ source: URL, to destination: URL) throws {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw LocalMusicError(kind: .invalidAudio, message: "The image could not be read.", technicalDetails: source.path)
        }
        try png.write(to: destination, options: .atomic)
    }

    // MARK: Rendering

    public func build(image: URL, audio: URL, duration: TimeInterval, output: URL,
                      onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                      onLog: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard let ffmpeg else {
            throw LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to export a video. Install it with: brew install ffmpeg")
        }
        let args = Self.arguments(image: image, audio: audio, duration: duration, output: output)
        Log.info("ffmpeg video: \(audio.lastPathComponent) + \(image.lastPathComponent) → \(output.lastPathComponent)", .tools)
        var log: [String] = []
        var code: Int32 = -1
        do {
            for try await event in ProcessRunner.stream(ffmpeg, arguments: args) {
                switch event {
                case .stdout(let l):
                    if let f = Self.progress(line: l, duration: duration) { onProgress(f) }
                case .stderr(let l):
                    log.append(l); onLog(l)
                case .exit(let c): code = c
                }
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        guard code == 0, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw LocalMusicError(kind: .toolFailed, message: "ffmpeg could not build the video.",
                                  technicalDetails: "exit code \(code)\n" + log.joined(separator: "\n"))
        }
        onProgress(1)
    }
}
