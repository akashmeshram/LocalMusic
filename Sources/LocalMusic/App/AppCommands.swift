import SwiftUI
import LocalMusicCore

struct AppCommands: Commands {
    let env: AppEnvironment

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
