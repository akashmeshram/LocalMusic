import Foundation

/// Exports the certificate authorities macOS trusts into a PEM bundle and hands it to
/// Python-based tools (yt-dlp) through `SSL_CERT_FILE`. python.org builds of Python ship
/// their own trust store, so without this yt-dlp fails on networks with an inspecting proxy
/// or on machines whose Python never had certificates installed. This only grants yt-dlp the
/// same trust the operating system already has; it never disables verification.
public enum CertificateBundle {
    public static var bundleURL: URL { AppPaths.applicationSupport.appendingPathComponent("macos-trusted-roots.pem") }
    static let maxAge: TimeInterval = 24 * 3600
    static let keychains = [
        "/System/Library/Keychains/SystemRootCertificates.keychain",
        "/Library/Keychains/System.keychain",
    ]

    /// Environment additions for a child process, or empty if the user already configured one.
    public static func environment() async -> [String: String] {
        if ProcessInfo.processInfo.environment["SSL_CERT_FILE"] != nil { return [:] }
        guard let url = await ensureBundle() else { return [:] }
        return ["SSL_CERT_FILE": url.path]
    }

    /// Regenerates the bundle when missing or stale. Returns nil if it could not be produced.
    public static func ensureBundle() async -> URL? {
        let url = bundleURL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < maxAge,
           (attrs[.size] as? Int ?? 0) > 0 {
            return url
        }
        let security = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: security.path) else { return nil }
        var pem = ""
        for keychain in keychains where FileManager.default.fileExists(atPath: keychain) {
            if let out = try? await ProcessRunner.run(security, arguments: ["find-certificate", "-a", "-p", keychain]), out.exitCode == 0 {
                pem += out.stdout + "\n"
            }
        }
        let count = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        guard count > 0 else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pem.write(to: url, atomically: true, encoding: .utf8)
            Log.info("exported \(count) trusted root certificates for yt-dlp", .tools)
            return url
        } catch {
            Log.warning("could not write certificate bundle: \(error.localizedDescription)", .tools)
            return nil
        }
    }
}
