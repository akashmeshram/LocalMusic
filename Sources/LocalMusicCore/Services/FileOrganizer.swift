import Foundation

/// Values used to build a track's location. Everything is untrusted and is sanitized here.
public struct OrganizeMetadata: Sendable, Hashable {
    public var title: String
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?

    public init(title: String, artist: String? = nil, albumArtist: String? = nil, album: String? = nil,
                year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, genre: String? = nil) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
    }

    var effectiveArtist: String? {
        [albumArtist, artist].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
    var effectiveAlbum: String? {
        album?.trimmingCharacters(in: .whitespaces).isEmpty == false ? album : nil
    }
}

/// Computes destination paths inside the library root and moves files there safely.
///
/// Layout rules:
/// - album known:      `{folderTemplate}/{filenameTemplate}.ext`   (default `Artist/Year - Album/NN - Title.ext`)
/// - no album:         `Artist/Singles/Title.ext`
/// - nothing known:    `Unknown Artist/Unknown Album/Title.ext`
public struct FileOrganizer: Sendable {
    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"
    public static let singlesFolder = "Singles"

    public let root: URL
    public let folderTemplate: String
    public let filenameTemplate: String
    private let pathGuard: PathGuard

    public init(root: URL, folderTemplate: String = AppSettings.defaultFolderTemplate, filenameTemplate: String = AppSettings.defaultFilenameTemplate) {
        self.root = root.standardizedFileURL
        self.folderTemplate = folderTemplate
        self.filenameTemplate = filenameTemplate
        self.pathGuard = PathGuard(root: root)
    }

    // MARK: Path generation (pure)

    public func relativePath(for meta: OrganizeMetadata, fileExtension: String) -> String {
        let ext = FilenameSanitizer.sanitizeExtension(fileExtension)
        let title = FilenameSanitizer.sanitize(meta.title, fallback: "Untitled")
        let artist = meta.effectiveArtist.map { FilenameSanitizer.sanitize($0, fallback: Self.unknownArtist) }

        let folders: [String]
        let fileName: String
        if let album = meta.effectiveAlbum {
            let values = Self.values(for: meta, artist: artist ?? Self.unknownArtist, album: album, title: title)
            folders = Self.expand(folderTemplate, values: values)
            let names = Self.expand(filenameTemplate, values: values)
            fileName = names.last ?? title
        } else if let artist {
            folders = [artist, Self.singlesFolder]
            fileName = title
        } else {
            folders = [Self.unknownArtist, Self.unknownAlbum]
            fileName = title
        }
        let safeFolders = folders.isEmpty ? [Self.unknownArtist, Self.unknownAlbum] : folders
        return (safeFolders + [fileName + "." + ext]).joined(separator: "/")
    }

    public func destinationURL(for meta: OrganizeMetadata, fileExtension: String) -> URL {
        root.appendingPathComponent(relativePath(for: meta, fileExtension: fileExtension))
    }

    static func values(for meta: OrganizeMetadata, artist: String, album: String, title: String) -> [String: String] {
        var v: [String: String] = [:]
        v["AlbumArtist"] = artist
        v["Artist"] = meta.artist.map { FilenameSanitizer.sanitize($0, fallback: artist) } ?? artist
        v["Album"] = FilenameSanitizer.sanitize(album, fallback: unknownAlbum)
        v["Title"] = title
        v["Year"] = meta.year.map { String($0) } ?? ""
        v["Track"] = meta.trackNumber.map { String(format: "%02d", $0) } ?? ""
        v["Disc"] = meta.discNumber.map { String($0) } ?? ""
        v["Genre"] = meta.genre.map { FilenameSanitizer.sanitize($0) } ?? ""
        return v
    }

    /// Expands `{Key}` placeholders, drops dangling separators left by empty values, and
    /// sanitizes every path segment. Empty segments are removed.
    public static func expand(_ template: String, values: [String: String]) -> [String] {
        template.split(separator: "/", omittingEmptySubsequences: true).compactMap { rawSegment -> String? in
            var segment = String(rawSegment)
            for (key, value) in values {
                segment = segment.replacingOccurrences(of: "{\(key)}", with: value)
            }
            // Remove any unknown placeholders.
            segment = segment.replacingOccurrences(of: #"\{[A-Za-z]+\}"#, with: "", options: .regularExpression)
            segment = cleanSeparators(segment)
            let sanitized = FilenameSanitizer.sanitize(segment, fallback: "")
            return sanitized.isEmpty ? nil : sanitized
        }
    }

    static func cleanSeparators(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "()", with: "").replacingOccurrences(of: "[]", with: "")
        out = out.replacingOccurrences(of: #"\s*-\s*-\s*"#, with: " - ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix("- ") || out.hasPrefix("-") { out = String(out.dropFirst(out.hasPrefix("- ") ? 2 : 1)).trimmingCharacters(in: .whitespaces) }
        while out.hasSuffix(" -") || out.hasSuffix("-") { out = String(out.dropLast(out.hasSuffix(" -") ? 2 : 1)).trimmingCharacters(in: .whitespaces) }
        return out
    }

    // MARK: Moving

    public enum CollisionPolicy: Sendable {
        /// Append ` (2)`, ` (3)`… until the name is free (checked case-insensitively).
        case keepBoth
        /// Throw `.fileExists` so the caller can ask the user.
        case fail
        /// Replace the existing file (caller has already confirmed).
        case replace
    }

    /// Moves `source` to its computed location. Returns the final URL. Never escapes `root`.
    public func place(_ source: URL, as meta: OrganizeMetadata, fileExtension: String? = nil, collision: CollisionPolicy = .keepBoth) throws -> URL {
        let ext = fileExtension ?? source.pathExtension
        let proposed = try pathGuard.validated(destinationURL(for: meta, fileExtension: ext))
        return try move(source, to: proposed, collision: collision)
    }

    /// Moves a file to an explicit destination inside the root, applying the collision policy.
    public func move(_ source: URL, to proposed: URL, collision: CollisionPolicy = .keepBoth) throws -> URL {
        let fm = FileManager.default
        let destination = try pathGuard.validated(proposed)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var target = destination
        if Self.existsCaseInsensitively(target), source.standardizedFileURL != target.standardizedFileURL {
            switch collision {
            case .fail:
                throw LocalMusicError(kind: .fileExists, message: "A file named “\(target.lastPathComponent)” already exists.", technicalDetails: target.path)
            case .replace:
                try fm.removeItem(at: try pathGuard.validated(target))
            case .keepBoth:
                target = Self.uniqueURL(for: target)
            }
        }
        try fm.moveItem(at: source, to: target)
        Log.info("moved \(source.lastPathComponent) → \(target.path)", .library)
        return target
    }

    /// True if any entry in the parent directory matches the file name ignoring case.
    /// Works on case-sensitive and case-insensitive volumes alike.
    public static func existsCaseInsensitively(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return false }
        return items.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static func uniqueURL(for url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let suffix = " (\(n))"
            let trimmedBase = FilenameSanitizer.truncate(base, toBytes: FilenameSanitizer.maxComponentBytes - suffix.utf8.count)
            var candidate = parent.appendingPathComponent(trimmedBase + suffix)
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !existsCaseInsensitively(candidate) { return candidate }
            n += 1
        }
    }

    /// Removes now-empty directories between `url`'s parent and the root.
    public func pruneEmptyDirectories(from url: URL) {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let fm = FileManager.default
        while pathGuard.contains(dir), dir.standardizedFileURL != root, dir.pathComponents.count > root.pathComponents.count {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path),
                  items.filter({ $0 != ".DS_Store" }).isEmpty else { return }
            try? fm.removeItem(at: dir)
            dir.deleteLastPathComponent()
        }
    }
}
