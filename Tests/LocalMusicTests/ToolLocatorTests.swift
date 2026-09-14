import Testing
import Foundation
@testable import LocalMusicCore

@Suite("ToolLocator")
struct ToolLocatorTests {
    @Test func parsesVersions() {
        #expect(ToolLocator.parseVersion(tool: .ytDLP, output: "2026.03.17\n") == "2026.03.17")
        #expect(ToolLocator.parseVersion(tool: .ytDLP, output: "Traceback (most recent call last)") == nil)
        #expect(ToolLocator.parseVersion(tool: .ffmpeg, output: "ffmpeg version 8.1 Copyright (c) 2000-2025 the FFmpeg developers\nbuilt with clang") == "8.1")
        #expect(ToolLocator.parseVersion(tool: .ffprobe, output: "ffprobe version n7.1-3-gabc Copyright") == "n7.1-3-gabc")
        #expect(ToolLocator.parseVersion(tool: .fpcalc, output: "fpcalc version 1.5.1") == "1.5.1")
    }

    @Test func overridePathMustBeExecutable() {
        #expect(ToolLocator.locate(.ytDLP, override: "/definitely/not/here") == nil)
        #expect(ToolLocator.locate(.ffmpeg, override: "/bin/ls")?.path == "/bin/ls")
    }

    @Test func searchesHomebrewPathsFirst() {
        let dirs = ToolLocator.searchDirectories.map(\.path)
        #expect(dirs.first == ToolInstaller.binDirectory.path)
        #expect(dirs[1] == "/opt/homebrew/bin")
        #expect(dirs.contains("/usr/local/bin"))
    }
}
