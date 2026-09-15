import SwiftUI
import LocalMusicCore

@main
struct LocalMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup("LocalMusic") {
            ContentView()
                .environment(env)
                .onAppear { appDelegate.env = env }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { AppCommands(env: env) }

        Settings {
            SettingsView().environment(env)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var env: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        LaunchOptions.scheduleScreenshots()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let env, env.downloads.unfinishedCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Downloads in progress"
        alert.informativeText = "\(env.downloads.unfinishedCount) download(s) will be cancelled if you quit now."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            env.downloads.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }
}

/// Command-line switches used by the build scripts and UI tests:
/// `--mock` (simulated downloads), `--download=<url>` (queue at launch, repeatable),
/// `--screenshot=<dir>` (write PNGs of every window at a few points after launch).
/// Values are attached with `=` because AppKit treats bare positional arguments as documents
/// to open, which suppresses the initial SwiftUI window.
enum LaunchOptions {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func values(for flag: String) -> [String] {
        arguments.compactMap { $0.hasPrefix(flag + "=") ? String($0.dropFirst(flag.count + 1)) : nil }
    }

    static var downloadURLs: [String] { values(for: "--download") }
    /// `--profile=<dir>`: keep index, caches and music under this directory (demo / test sandbox).
    static var profileDirectory: URL? { values(for: "--profile").first.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    /// `--select=songs|albums|artists|recent|favorites|downloads|playlist` (playlist creates a demo list if none exists).
    static var initialSelection: String? { values(for: "--select").first }

    static var screenshotDirectory: URL? {
        values(for: "--screenshot").first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func scheduleScreenshots() {
        guard let dir = screenshotDirectory else { return }
        for (n, delay) in [2.0, 7.0, 15.0, 30.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { capture(to: dir, index: n + 1) }
        }
    }

    @MainActor
    static func capture(to dir: URL, index: Int) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (w, window) in NSApp.windows.filter({ $0.isVisible && $0.frame.height > 100 }).enumerated() {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // Composite over the window background so translucent materials look like they do on screen.
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
            }
            rep.draw(in: view.bounds)
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff),
                  let png = flat.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { continue }
            try? png.write(to: dir.appendingPathComponent("shot-\(index)-\(w).png"))
        }
    }
}
