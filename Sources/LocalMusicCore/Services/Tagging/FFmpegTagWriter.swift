import Foundation

/// Fallback for containers without a native writer (Ogg/Opus, WAV, AIFF): stream-copies through
/// ffmpeg with `-metadata`. Artwork is not embedded for these formats.
public struct FFmpegTagWriter: TagWriter {
    let ffmpeg: FFmpegService

    public func write(_ tags: TrackTags, to file: URL) async throws {
        guard let exe = ffmpeg.ffmpeg else {
            throw LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to tag .\(file.pathExtension) files.")
        }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).lmtmp.\(file.pathExtension)")
        var args = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-i", file.path, "-map", "0", "-c", "copy"]
        func meta(_ key: String, _ value: String?) { if let v = value, !v.isEmpty { args += ["-metadata", "\(key)=\(v)"] } }
        meta("title", tags.title)
        meta("artist", tags.artist)
        meta("album_artist", tags.albumArtist)
        meta("album", tags.album)
        meta("track", tags.trackNumber.map { n in tags.trackTotal.map { "\(n)/\($0)" } ?? "\(n)" })
        meta("disc", tags.discNumber.map(String.init))
        meta("genre", tags.genre)
        meta("date", tags.year.map(String.init))
        meta("composer", tags.composer)
        meta("comment", tags.comment)
        args.append(tmp.path)
        let out = try await ProcessRunner.run(exe, arguments: args)
        guard out.exitCode == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            throw LocalMusicError(kind: .toolFailed, message: "ffmpeg could not write tags.", technicalDetails: out.stderr)
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }
}
