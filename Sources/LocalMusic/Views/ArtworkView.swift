import SwiftUI
import AppKit
import LocalMusicCore

/// Small in-memory image cache so table rows don't hit the disk on every redraw.
@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ArtworkView: View {
    @Environment(AppEnvironment.self) private var env
    let fileName: String?
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 4

    var body: some View {
        Group {
            if let fileName, let url = env.artwork.url(for: fileName), let image = ImageStore.shared.image(for: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Remote thumbnail (used only for queue rows before the file exists).
struct RemoteThumbnail: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) } else { placeholder }
                }
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var placeholder: some View {
        ZStack { Rectangle().fill(.quaternary); Image(systemName: "waveform").foregroundStyle(.secondary) }
    }
}
