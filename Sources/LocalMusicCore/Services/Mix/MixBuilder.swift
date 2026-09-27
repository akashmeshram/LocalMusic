import Foundation

/// Joins several audio files into one MP3 with ffmpeg, crossfading (or butt-joining) at every
/// boundary, and computes the chapter timeline that results. The filter graph is built from
/// literal arguments only; no shell is involved.
public struct MixBuilder: Sendable {
    public struct Input: Sendable, Hashable {
        public var url: URL
        public var title: String
        public var duration: TimeInterval

        public init(url: URL, title: String, duration: TimeInterval) {
            self.url = url
            self.title = title
            self.duration = duration
        }
    }

    public struct Plan: Sendable, Hashable {
        /// Effective overlap applied at each boundary (count - 1 entries).
        public var overlaps: [TimeInterval]
        public var chapters: [TrackChapter]
        public var totalDuration: TimeInterval
    }

    public static let minimumCrossfade: TimeInterval = 0.05
    public static let sampleRate = 44_100

    public let ffmpeg: URL?

    public init(ffmpeg: URL?) {
        self.ffmpeg = ffmpeg
    }

    // MARK: Timeline (pure)

    /// Crossfade at a boundary can never exceed half of either neighbour, so short clips still
    /// keep most of their audio. Below `minimumCrossfade` the boundary becomes a hard cut.
    public static func overlap(crossfade: TimeInterval, before: TimeInterval, after: TimeInterval) -> TimeInterval {
        let candidate = min(max(0, crossfade), before / 2, after / 2)
        return candidate < minimumCrossfade ? 0 : candidate
    }

    public static func plan(_ inputs: [Input], crossfade: TimeInterval) -> Plan {
        var overlaps: [TimeInterval] = []
        var chapters: [TrackChapter] = []
        var cursor: TimeInterval = 0
        for (i, input) in inputs.enumerated() {
            let end = cursor + max(0, input.duration)
            chapters.append(TrackChapter(title: input.title, start: cursor, end: end))
            if i + 1 < inputs.count {
                let o = overlap(crossfade: crossfade, before: input.duration, after: inputs[i + 1].duration)
                overlaps.append(o)
                cursor = end - o
            } else {
                cursor = end
            }
        }
        return Plan(overlaps: overlaps, chapters: chapters, totalDuration: cursor)
    }

    // MARK: ffmpeg arguments (pure)

    /// `-filter_complex` graph: normalise every input to 44.1 kHz stereo float, then fold the
    /// chain left to right with `acrossfade` (or `concat` for hard cuts).
    public static func filterGraph(count: Int, overlaps: [TimeInterval]) -> String {
        precondition(count >= 1 && overlaps.count == count - 1)
        var parts: [String] = []
        for i in 0..<count {
            parts.append("[\(i):a]aformat=sample_fmts=fltp:sample_rates=\(sampleRate):channel_layouts=stereo[a\(i)]")
        }
        var current = "[a0]"
        for i in 1..<max(count, 1) {
            let out = i == count - 1 ? "[out]" : "[x\(i)]"
            let o = overlaps[i - 1]
            if o > 0 {
                parts.append("\(current)[a\(i)]acrossfade=d=\(String(format: "%.3f", o)):c1=tri:c2=tri\(out)")
            } else {
                parts.append("\(current)[a\(i)]concat=n=2:v=0:a=1\(out)")
            }
            current = out
        }
        if count == 1 { parts.append("[a0]anull[out]") }
        return parts.joined(separator: ";")
    }

    public static func arguments(inputs: [Input], overlaps: [TimeInterval], bitrateKbps: Int, output: URL) -> [String] {
        var args = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error"]
        for input in inputs { args += ["-i", input.url.path] }
        args += ["-filter_complex", filterGraph(count: inputs.count, overlaps: overlaps),
                 "-map", "[out]", "-map_metadata", "-1", "-vn",
                 "-c:a", "libmp3lame", "-b:a", "\(max(64, min(bitrateKbps, 320)))k",
                 "-ar", "\(sampleRate)", "-ac", "2", "-id3v2_version", "4", "-f", "mp3", output.path]
        return args
    }

    // MARK: Execution

    public func build(_ inputs: [Input], crossfade: TimeInterval, bitrateKbps: Int, output: URL,
                      onLog: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Plan {
        guard let ffmpeg else {
            throw LocalMusicError(kind: .toolMissing, message: "ffmpeg is required to build a mix. Install it with: brew install ffmpeg")
        }
        guard !inputs.isEmpty else {
            throw LocalMusicError(kind: .invalidAudio, message: "A mix needs at least one song.")
        }
        let plan = Self.plan(inputs, crossfade: crossfade)
        let args = Self.arguments(inputs: inputs, overlaps: plan.overlaps, bitrateKbps: bitrateKbps, output: output)
        Log.info("ffmpeg mix: \(inputs.count) inputs, crossfade \(crossfade)s → \(output.lastPathComponent)", .tools)
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
            throw LocalMusicError(kind: .toolFailed, message: "ffmpeg could not build the mix.",
                                  technicalDetails: "exit code \(code)\n" + log.joined(separator: "\n"))
        }
        return plan
    }
}
