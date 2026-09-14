import SwiftUI
import LocalMusicCore

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        NavigationSplitView {
            SidebarView(selection: $env.selectedSidebar)
        } detail: {
            detail
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar()
        }
        .frame(minWidth: 960, minHeight: 600)
        .task {
            await env.refreshTools()
            await env.library.load()
            await env.library.rescan()
            let urls = LaunchOptions.downloadURLs
            if !urls.isEmpty { env.selectedSidebar = .downloads }
            for url in urls { await env.downloads.submit(url) }
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
        case .downloads:
            DownloadsView()
        case let scope:
            SongsView(scope: scope)
        }
    }
}

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach([SidebarItem.songs, .recentlyAdded, .favorites]) { item in
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
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }
}
