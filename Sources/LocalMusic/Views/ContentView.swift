import SwiftUI
import UniformTypeIdentifiers
import LocalMusicCore

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        NavigationSplitView {
            SidebarView(selection: $env.selectedSidebar)
        } detail: {
            detail.background(Color(nsColor: .windowBackgroundColor))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar()
        }
        .frame(minWidth: 960, minHeight: 600)
        .task {
            await env.refreshTools()
            await env.library.load()
            await env.library.rescan()
            if let sel = LaunchOptions.initialSelection {
                switch sel {
                case "albums", "album": env.selectedSidebar = .albums
                case "artists": env.selectedSidebar = .artists
                case "recent": env.selectedSidebar = .recentlyAdded
                case "favorites": env.selectedSidebar = .favorites
                case "downloads": env.selectedSidebar = .downloads
                case "playlist":
                    let p: PlaylistRecord
                    if let existing = env.library.playlists.first { p = existing }
                    else { p = await env.library.createPlaylist(name: "Demo Playlist", trackIDs: env.library.tracks.map(\.id)) }
                    env.selectedSidebar = .playlist(p.id)
                default: env.selectedSidebar = .songs
                }
            }
            let urls = LaunchOptions.downloadURLs
            if !urls.isEmpty { env.selectedSidebar = .downloads }
            for url in urls { await env.downloads.submit(url) }
            if let scenarios = LaunchOptions.e2eScenarios {
                let ok = await E2ERunner(env: env).run(scenarios)
                LaunchOptions.capture(to: LaunchOptions.screenshotDirectory ?? FileManager.default.temporaryDirectory, index: 99)
                exit(ok ? 0 : 1)
            }
        }
        .alert("Startup problem", isPresented: Binding(get: { env.startupError != nil }, set: { if !$0 { env.startupError = nil } })) {
            Button("OK") {}
        } message: {
            Text(env.startupError?.message ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.selectedSidebar ?? .songs {
        case .downloads: DownloadsView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .playlist(let id): PlaylistView(playlistID: id).id(id)
        case let scope: SongsView(scope: scope)
        }
    }
}

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: SidebarItem?
    @State private var renaming: PlaylistRecord?
    @State private var renameText = ""
    @State private var deleting: PlaylistRecord?
    @State private var dropTarget: UUID?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(SidebarItem.libraryItems) { item in
                    Label(item.title, systemImage: item.systemImage).tag(item)
                }
            }
            Section("Activity") {
                if env.toolsChecked, !env.missingRequiredTools.isEmpty {
                    Button { selection = .downloads } label: {
                        Label("Tools missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
                Label {
                    HStack {
                        Text(SidebarItem.downloads.title)
                        Spacer()
                        if env.downloads.unfinishedCount > 0 {
                            Text("\(env.downloads.unfinishedCount)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: SidebarItem.downloads.systemImage)
                }
                .tag(SidebarItem.downloads)
            }
            Section {
                ForEach(env.library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .tag(SidebarItem.playlist(playlist.id))
                        .listRowBackground(dropTarget == playlist.id ? Color.accentColor.opacity(0.25) : nil)
                        .onDrop(of: [.utf8PlainText, .text], isTargeted: Binding(get: { dropTarget == playlist.id }, set: { dropTarget = $0 ? playlist.id : nil })) { providers in
                            Self.handleDrop(providers) { ids in Task { await env.library.addTracks(ids, toPlaylist: playlist.id) } }
                        }
                        .contextMenu {
                            Button("Play") { env.playback.play(env.library.tracks(inPlaylist: playlist.id)) }
                            Button("Rename…") { renameText = playlist.name; renaming = playlist }
                            Button("Export M3U8…") { export(playlist) }
                            Divider()
                            Button("Delete Playlist…", role: .destructive) { deleting = playlist }
                        }
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button { Task { let p = await env.library.createPlaylist(); selection = .playlist(p.id); renameText = p.name; renaming = p } } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New Playlist")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let p = renaming { Task { await env.library.renamePlaylist(p.id, to: renameText) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Playlist", role: .destructive) {
                if let p = deleting {
                    if selection == .playlist(p.id) { selection = .songs }
                    Task { await env.library.deletePlaylist(p.id) }
                }
            }
        } message: { Text("The songs stay in your library; only the playlist is removed.") }
    }

    static func handleDrop(_ providers: [NSItemProvider], _ apply: @escaping @Sendable ([UUID]) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else { return false }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) ? UTType.utf8PlainText.identifier : UTType.text.identifier
        provider.loadItem(forTypeIdentifier: type) { @Sendable item, _ in
            let string = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? (item as? NSString).map(String.init)
            guard let string, let ids = TrackDrag.parse(string), !ids.isEmpty else { return }
            apply(ids)
        }
        return true
    }

    private func export(_ playlist: PlaylistRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = playlist.name + ".m3u8"
        if panel.runModal() == .OK, let url = panel.url { try? env.library.exportPlaylist(playlist.id, to: url) }
    }
}
