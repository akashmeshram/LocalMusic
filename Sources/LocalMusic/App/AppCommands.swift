import SwiftUI
import UniformTypeIdentifiers
import LocalMusicCore

struct AppCommands: Commands {
    let env: AppEnvironment

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText, UTType(filenameExtension: "m3u") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let (playlist, unmatched) = try await env.library.importPlaylist(from: url)
                env.selectedSidebar = .playlist(playlist.id)
                if unmatched > 0 {
                    let alert = NSAlert()
                    alert.messageText = "Imported “\(playlist.name)”"
                    alert.informativeText = "\(unmatched) entr\(unmatched == 1 ? "y" : "ies") could not be matched to songs in your library and were skipped."
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Download from URL…") {
                env.selectedSidebar = .downloads
                env.focusURLFieldToken += 1
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Paste & Download") {
                env.selectedSidebar = .downloads
                if let text = NSPasteboard.general.string(forType: .string) {
                    Task { await env.downloads.submit(text) }
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("New Playlist") {
                Task { let p = await env.library.createPlaylist(); env.selectedSidebar = .playlist(p.id) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Import Playlist (M3U8)…") { importPlaylist() }
        }

        CommandGroup(after: .sidebar) {
            Button("Songs") { env.selectedSidebar = .songs }.keyboardShortcut("1", modifiers: .command)
            Button("Albums") { env.selectedSidebar = .albums }.keyboardShortcut("2", modifiers: .command)
            Button("Artists") { env.selectedSidebar = .artists }.keyboardShortcut("3", modifiers: .command)
            Button("Recently Added") { env.selectedSidebar = .recentlyAdded }.keyboardShortcut("4", modifiers: .command)
            Button("Favorites") { env.selectedSidebar = .favorites }.keyboardShortcut("5", modifiers: .command)
            Button("Downloads") { env.selectedSidebar = .downloads }.keyboardShortcut("6", modifiers: .command)
            Divider()
        }

        CommandMenu("Library") {
            Button("Rescan Music Folder") { Task { await env.library.rescan() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Rebuild Library…") { Task { await env.library.rebuild() } }
            Divider()
            Button("Reveal Library Folder in Finder") { env.revealLibraryFolder() }
            Button("Open Logs Folder") { env.openLogsFolder() }
            Divider()
            Button("Check for Tool Updates") { Task { await env.checkForToolUpdates() } }
        }

        CommandMenu("Controls") {
            Button(env.playback.isPlaying ? "Pause" : "Play") { env.playback.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(env.playback.currentTrack == nil && env.playback.queue.isEmpty)
            Button("Next") { env.playback.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { env.playback.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { env.playback.isShuffling }, set: { _ in env.playback.toggleShuffle() }))
            Picker("Repeat", selection: Binding(get: { env.playback.repeatMode }, set: { env.playback.repeatMode = $0 })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Divider()
            Button("Volume Up") { env.playback.volume = min(1, env.playback.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { env.playback.volume = max(0, env.playback.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}
