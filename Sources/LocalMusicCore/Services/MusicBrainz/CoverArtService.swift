import Foundation

/// Cover Art Archive client: front cover for a release, falling back to the release group.
public struct CoverArtService: Sendable {
    let cache: MetadataCache
    let artwork: ArtworkService

    public init(cache: MetadataCache = MetadataCache(), artwork: ArtworkService) {
        self.cache = cache
        self.artwork = artwork
    }

    /// Returns normalized image bytes, or nil when no cover exists. Negative results are cached.
    public func frontCover(releaseID: String?, releaseGroupID: String?) async -> Data? {
        var urls: [String] = []
        if let releaseID { urls.append("https://coverartarchive.org/release/\(releaseID)/front-1200") }
        if let releaseGroupID { urls.append("https://coverartarchive.org/release-group/\(releaseGroupID)/front-1200") }
        for string in urls {
            let key = "caa:\(string)"
            if let cached = cache.get(key) {
                if cached.isEmpty { continue }
                return cached
            }
            guard let url = URL(string: string) else { continue }
            do {
                let data = try await artwork.fetch(url)
                let normalized = artwork.normalized(data)
                cache.set(key, normalized)
                Log.info("cover art found for \(string)", .metadata)
                return normalized
            } catch {
                cache.set(key, Data())
                Log.debug("no cover art at \(string): \(error.localizedDescription)", .metadata)
            }
        }
        return nil
    }
}
