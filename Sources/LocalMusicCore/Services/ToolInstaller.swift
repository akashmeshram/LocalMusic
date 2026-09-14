import Foundation
import CryptoKit

/// Downloads the official standalone `yt-dlp_macos` build into the app's own support folder.
/// This is the one install the app performs, and only after the user explicitly asks for it:
/// it touches nothing outside `~/Library/Application Support/LocalMusic/bin`, verifies the
/// published SHA-256 checksum, and can be removed by deleting that folder.
public struct ToolInstaller: Sendable {
    public static let binDirectory = AppPaths.applicationSupport.appendingPathComponent("bin", isDirectory: true)
    public static let ytdlpURL = binDirectory.appendingPathComponent("yt-dlp")
    static let assetName = "yt-dlp_macos"
    static let releaseBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
    public static let approximateSize = "≈ 30 MB"

    public enum Stage: Sendable, Equatable {
        case fetchingChecksum, downloading(fraction: Double?), verifying, done
    }

    public init() {}

    /// True when the app-managed binary exists (whether or not it is the one currently in use).
    public static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: ytdlpURL.path) }

    public static func isAppManaged(_ path: URL?) -> Bool {
        path?.standardizedFileURL.path == ytdlpURL.standardizedFileURL.path
    }

    /// Downloads, verifies and installs yt-dlp. Returns the detected version.
    public func installYTDLP(progress: @escaping @Sendable (Stage) -> Void) async throws -> String {
        progress(.fetchingChecksum)
        let expected = try await fetchExpectedChecksum()

        progress(.downloading(fraction: nil))
        let tmp = try await download(URL(string: Self.releaseBase + Self.assetName)!) { progress(.downloading(fraction: $0)) }
        defer { try? FileManager.default.removeItem(at: tmp) }

        progress(.verifying)
        let data = try Data(contentsOf: tmp)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw LocalMusicError(kind: .toolFailed, message: "The downloaded yt-dlp did not match its published checksum, so it was discarded.",
                                  technicalDetails: "expected \(expected)\nactual   \(actual)")
        }
        try FileManager.default.createDirectory(at: Self.binDirectory, withIntermediateDirectories: true)
        let staging = Self.binDirectory.appendingPathComponent(".yt-dlp.download")
        try data.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        Self.removeQuarantine(staging)
        _ = try FileManager.default.replaceItemAt(Self.ytdlpURL, withItemAt: staging)

        let info = await ToolLocator.detect(.ytDLP, override: Self.ytdlpURL.path)
        guard info.isUsable, let version = info.version else {
            try? FileManager.default.removeItem(at: Self.ytdlpURL)
            let why: String = { if case .broken(let w) = info.status { return w }; return "not runnable" }()
            throw LocalMusicError(kind: .toolFailed, message: "yt-dlp was downloaded but does not run on this Mac.", technicalDetails: why)
        }
        progress(.done)
        Log.info("installed yt-dlp \(version) to \(Self.ytdlpURL.path)", .tools)
        return version
    }

    public func removeYTDLP() throws {
        if FileManager.default.fileExists(atPath: Self.ytdlpURL.path) {
            try FileManager.default.removeItem(at: Self.ytdlpURL)
        }
    }

    func fetchExpectedChecksum() async throws -> String {
        let url = URL(string: Self.releaseBase + "SHA2-256SUMS")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(MusicBrainzService.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw LocalMusicError(kind: .network, message: "Could not fetch the yt-dlp checksum list from GitHub.")
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts.last.map(String.init) == Self.assetName, parts[0].count == 64 {
                return String(parts[0]).lowercased()
            }
        }
        throw LocalMusicError(kind: .network, message: "The yt-dlp checksum list did not mention \(Self.assetName).")
    }

    func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(MusicBrainzService.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalMusicError(kind: .network, message: "Could not download yt-dlp from GitHub.", technicalDetails: response.description)
        }
        let total = http.expectedContentLength
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer); received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    progress(total > 0 ? Double(received) / Double(total) : nil)
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); received += Int64(buffer.count) }
        guard received > 1_000_000 else {
            throw LocalMusicError(kind: .network, message: "The yt-dlp download was incomplete.")
        }
        return tmp
    }

    /// Files written by the app are not quarantined, but be explicit so Gatekeeper never blocks the tool.
    static func removeQuarantine(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, "com.apple.quarantine", 0) }
        }
    }
}
