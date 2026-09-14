import Foundation
import os

/// Structured logging: `os.Logger` for Console.app plus a rotating file under
/// `~/Library/Logs/LocalMusic/`. Never log secrets; use `Log.redacted(_:)` for anything sensitive.
public enum Log {
    public enum Category: String, Sendable {
        case app, download, ytdlp, ffmpeg, library, playback, metadata, tools, persistence
    }

    public static let logsDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/LocalMusic", isDirectory: true)
    }()

    private static let subsystem = "dev.localmusic"
    private static let file = FileLogger(directory: logsDirectory, fileName: "LocalMusic.log")

    public static func debug(_ message: String, _ category: Category = .app) {
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(message, privacy: .public)")
        file.write(level: "DEBUG", category: category.rawValue, message: message)
    }

    public static func info(_ message: String, _ category: Category = .app) {
        Logger(subsystem: subsystem, category: category.rawValue).info("\(message, privacy: .public)")
        file.write(level: "INFO", category: category.rawValue, message: message)
    }

    public static func warning(_ message: String, _ category: Category = .app) {
        Logger(subsystem: subsystem, category: category.rawValue).warning("\(message, privacy: .public)")
        file.write(level: "WARN", category: category.rawValue, message: message)
    }

    public static func error(_ message: String, _ category: Category = .app) {
        Logger(subsystem: subsystem, category: category.rawValue).error("\(message, privacy: .public)")
        file.write(level: "ERROR", category: category.rawValue, message: message)
    }

    /// Replaces the middle of a secret so its presence can be logged without its value.
    public static func redacted(_ secret: String) -> String {
        guard secret.count > 6 else { return "••••" }
        return "\(secret.prefix(2))••••\(secret.suffix(2))"
    }
}

/// Serial, lock-protected file logger with size-based rotation.
final class FileLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let fileURL: URL
    private let maxBytes: Int = 5 * 1024 * 1024
    private var handle: FileHandle?
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(directory: URL, fileName: String) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    func write(level: String, category: String, message: String) {
        let line = "\(dateFormatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        do {
            if handle == nil { try open() }
            if let size = try? handle?.seekToEnd(), size > UInt64(maxBytes) { try rotate() }
            handle?.write(Data(line.utf8))
        } catch {
            // Logging must never crash the app.
        }
    }

    private func open() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        _ = try handle?.seekToEnd()
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let rotated = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: rotated)
        try FileManager.default.moveItem(at: fileURL, to: rotated)
        try open()
    }
}
