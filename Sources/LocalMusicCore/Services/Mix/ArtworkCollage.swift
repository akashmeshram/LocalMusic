import Foundation
import AppKit
import CryptoKit

/// Builds one square cover for a mix out of the covers of its songs. Songs from the same album
/// share a tile; a single distinct cover is used unchanged.
public enum ArtworkCollage {
    public struct Source: Sendable {
        /// Album identity (album + album artist); `nil` when unknown, in which case only the
        /// image bytes decide whether two covers are "the same".
        public var albumKey: String?
        public var image: Data

        public init(albumKey: String?, image: Data) {
            self.albumKey = albumKey
            self.image = image
        }
    }

    public static let side = 1200
    public static let maxTiles = 9

    public static func albumKey(album: String?, albumArtist: String?, artist: String?) -> String? {
        guard let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty else { return nil }
        let who = (albumArtist ?? artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (album + "|" + who).lowercased()
    }

    /// Drops repeated covers, keeping first-seen order. A cover repeats when its bytes match or
    /// when it belongs to an album already represented.
    public static func distinct(_ sources: [Source]) -> [Data] {
        var seenHashes = Set<Data>()
        var seenAlbums = Set<String>()
        var out: [Data] = []
        for s in sources {
            let hash = Data(SHA256.hash(data: s.image))
            if seenHashes.contains(hash) { continue }
            if let key = s.albumKey {
                if seenAlbums.contains(key) { continue }
                seenAlbums.insert(key)
            }
            seenHashes.insert(hash)
            out.append(s.image)
        }
        return out
    }

    /// Tile rectangles in unit coordinates (origin top-left) for `count` covers. Tiles are always
    /// square so album covers are never cropped: 2–4 covers → 2×2, more → 3×3.
    public static func layout(count: Int) -> [CGRect] {
        switch count {
        case ..<1: return []
        case 1: return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case 2, 3, 4: return grid(columns: 2, rows: 2)
        default: return grid(columns: 3, rows: 3)
        }
    }

    static func grid(columns: Int, rows: Int) -> [CGRect] {
        var rects: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<columns {
                rects.append(CGRect(x: Double(c) / Double(columns), y: Double(r) / Double(rows),
                                    width: 1 / Double(columns), height: 1 / Double(rows)))
            }
        }
        return rects
    }

    /// Chooses which cover goes in each cell. Two covers form a checkerboard, three repeat the
    /// first, and larger sets wrap so no cell is left blank. More than nine uses the first nine.
    public static func tiles(for count: Int) -> [Int] {
        let n = min(count, maxTiles)
        let cells = layout(count: n).count
        guard cells > 0 else { return [] }
        if n == 2 { return [0, 1, 1, 0] }
        return (0..<cells).map { $0 % n }
    }

    /// The final cover: the only cover unchanged, or a rendered composite (JPEG).
    public static func compose(_ sources: [Source]) -> Data? {
        let covers = distinct(sources)
        if covers.isEmpty { return nil }
        if covers.count == 1 { return covers[0] }
        return render(covers)
    }

    public static func render(_ covers: [Data], side: Int = side) -> Data? {
        let images = covers.compactMap { NSImage(data: $0) }.filter { $0.size.width > 0 && $0.size.height > 0 }
        guard !images.isEmpty else { return nil }
        let rects = layout(count: min(images.count, maxTiles))
        let order = tiles(for: images.count)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        for (cell, imageIndex) in order.enumerated() {
            let unit = rects[cell]
            // Flip y: unit coordinates are top-left based, AppKit bitmaps are bottom-left based.
            let dest = NSRect(x: unit.minX * Double(side), y: (1 - unit.maxY) * Double(side),
                              width: unit.width * Double(side), height: unit.height * Double(side)).integral
            drawAspectFill(images[imageIndex], in: dest)
        }
        ctx.flushGraphics()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    static func drawAspectFill(_ image: NSImage, in dest: NSRect) {
        let size = image.size
        let scale = max(dest.width / size.width, dest.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let origin = NSPoint(x: dest.midX - drawn.width / 2, y: dest.midY - drawn.height / 2)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: dest).addClip()
        image.draw(in: NSRect(origin: origin, size: drawn), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
