import Foundation
import AppKit

public enum ImageInfo {
    public static func dimensions(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

/// Fetches, normalizes and caches artwork. Phase 2 sources: embedded art and the source thumbnail.
/// Cover Art Archive is layered on top in Phase 3.
public struct ArtworkService: Sendable {
    public let cache: ArtworkCache
    public static let maxEdge = 1400
    static let maxBytes = 12 * 1024 * 1024

    public init(cache: ArtworkCache) {
        self.cache = cache
    }

    /// Downloads an image over HTTPS; rejects non-images and oversized payloads.
    public func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https" || url.scheme == "http" else {
            throw LocalMusicError(kind: .malformedURL, message: "Artwork URL must be http(s).")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("LocalMusic/0.1 (local desktop app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalMusicError(kind: .network, message: "Artwork download failed.", technicalDetails: response.description)
        }
        guard data.count <= Self.maxBytes, ImageInfo.dimensions(of: data) != nil else {
            throw LocalMusicError(kind: .invalidAudio, message: "The artwork is not a usable image.")
        }
        return data
    }

    /// Converts to JPEG (or keeps PNG) and downsamples very large images. WebP thumbnails from
    /// video sites become JPEG so every tag format can embed them.
    public func normalized(_ data: Data) -> Data {
        let mime = ImageSniffer.mimeType(of: data)
        let dims = ImageInfo.dimensions(of: data)
        let tooBig = (dims.map { max($0.0, $0.1) } ?? 0) > Self.maxEdge
        if (mime == "image/jpeg" || mime == "image/png") && !tooBig { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? data
    }

    /// Crops a video thumbnail (16:9) to a centered square, which is what album art expects.
    public func squared(_ data: Data) -> Data {
        guard let (w, h) = ImageInfo.dimensions(of: data), w != h, abs(Double(w) / Double(h) - 1) > 0.15,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return data }
        let side = min(w, h)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return data }
        let rep = NSBitmapImageRep(cgImage: cropped)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? data
    }

    /// Stores normalized bytes in the cache and returns the cache file name.
    public func cacheNormalized(_ data: Data) throws -> (fileName: String, data: Data) {
        let bytes = normalized(data)
        return (try cache.store(bytes), bytes)
    }
}
