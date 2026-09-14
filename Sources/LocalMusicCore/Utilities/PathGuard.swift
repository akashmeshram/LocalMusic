import Foundation

/// Confines file operations to a root directory. Every destination path derived from
/// untrusted metadata must pass through here before a move, copy or delete.
public struct PathGuard: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// True when `url` (after standardization and symlink resolution of existing ancestors) is inside `root`.
    public func contains(_ url: URL) -> Bool {
        let target = Self.resolveExistingAncestors(url.standardizedFileURL)
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    /// Returns the standardized URL or throws `LocalMusicError.pathEscapesLibrary`.
    public func validated(_ url: URL) throws -> URL {
        guard contains(url) else {
            throw LocalMusicError(kind: .pathEscapesLibrary,
                                  message: "Refused to touch a path outside the music library.",
                                  technicalDetails: "\(url.path) is not under \(root.path)")
        }
        return url.standardizedFileURL
    }

    /// Resolves symlinks for the longest existing prefix of the path so that a symlinked
    /// subfolder pointing outside the root is detected even when the leaf does not exist yet.
    static func resolveExistingAncestors(_ url: URL) -> URL {
        let fm = FileManager.default
        var existing = url
        var trailing: [String] = []
        while !fm.fileExists(atPath: existing.path) && existing.pathComponents.count > 1 {
            trailing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in trailing { resolved.appendPathComponent(component) }
        return resolved
    }
}
