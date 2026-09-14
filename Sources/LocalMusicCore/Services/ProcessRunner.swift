import Foundation

public enum ProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

/// Executes external tools with `Process` + `Pipe`. Arguments are passed as an array,
/// never through a shell, so untrusted input cannot be interpreted.
public enum ProcessRunner {
    /// Extra PATH entries so tools can find their own helpers (e.g. yt-dlp locating ffmpeg).
    public static let helperPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// Streams stdout/stderr line by line, then emits `.exit`. Cancelling the consuming task
    /// sends SIGTERM to the process.
    public static func stream(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = makeEnvironment(extra: environment)
            process.currentDirectoryURL = currentDirectory
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let group = DispatchGroup()
            func pump(_ handle: FileHandle, _ wrap: @escaping @Sendable (String) -> ProcessEvent) {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let splitter = LineSplitter()
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        for line in splitter.append(data) { continuation.yield(wrap(line)) }
                    }
                    if let rest = splitter.flush() { continuation.yield(wrap(rest)) }
                    try? handle.close()
                    group.leave()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: LocalMusicError(
                    kind: .toolFailed,
                    message: "Could not launch \(executable.lastPathComponent).",
                    technicalDetails: "\(executable.path): \(error.localizedDescription)"))
                return
            }

            pump(stdoutPipe.fileHandleForReading) { .stdout($0) }
            pump(stderrPipe.fileHandleForReading) { .stderr($0) }

            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning {
                    process.terminate()
                }
            }

            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                group.wait()
                continuation.yield(.exit(process.terminationStatus))
                continuation.finish()
            }
        }
    }

    /// Runs to completion and returns collected output. Does not throw on non-zero exit;
    /// inspect `exitCode`. Throws only if the process cannot be launched or the task is cancelled.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) async throws -> ProcessOutput {
        var out: [String] = []
        var err: [String] = []
        var code: Int32 = -1
        for try await event in stream(executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory) {
            switch event {
            case .stdout(let line): out.append(line)
            case .stderr(let line): err.append(line)
            case .exit(let c): code = c
            }
        }
        try Task.checkCancellation()
        return ProcessOutput(exitCode: code, stdout: out.joined(separator: "\n"), stderr: err.joined(separator: "\n"))
    }

    static func makeEnvironment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        let merged = helperPaths + existing.filter { !helperPaths.contains($0) }
        env["PATH"] = merged.joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        for (k, v) in extra { env[k] = v }
        return env
    }
}

/// Splits a byte stream into lines on `\n` or `\r` (progress bars often use `\r`).
final class LineSplitter {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1), !s.isEmpty {
                lines.append(s)
            }
        }
        return lines
    }

    func flush() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return nil }
        return String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1)
    }
}
