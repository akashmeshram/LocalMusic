import Foundation

/// Finds yt-dlp / ffmpeg / ffprobe / fpcalc, verifies they run, and reports versions.
/// Never installs anything.
public enum ToolLocator {
    /// Search order: explicit override, Homebrew (Apple Silicon), Homebrew (Intel), MacPorts,
    /// pip/pipx user installs, then everything on PATH.
    public static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent("Library/Python/3.12/bin").path,
            home.appendingPathComponent("Library/Python/3.11/bin").path,
            "/usr/bin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func locate(_ tool: Tool, override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(tool.executableName)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Detects a single tool and probes its version by running it.
    public static func detect(_ tool: Tool, override: String? = nil) async -> ToolInfo {
        guard let path = locate(tool, override: override) else {
            return ToolInfo(tool: tool, path: nil, version: nil, status: .missing)
        }
        do {
            let output = try await ProcessRunner.run(path, arguments: tool.versionArguments)
            let text = output.stdout.isEmpty ? output.stderr : output.stdout
            if output.exitCode == 0, let version = parseVersion(tool: tool, output: text) {
                return ToolInfo(tool: tool, path: path, version: version, status: .ok)
            }
            let detail = (output.stderr.isEmpty ? output.stdout : output.stderr)
                .split(separator: "\n").prefix(3).joined(separator: " ")
            return ToolInfo(tool: tool, path: path, version: nil,
                            status: .broken(detail.isEmpty ? "Exited with status \(output.exitCode)" : String(detail.prefix(300))))
        } catch {
            return ToolInfo(tool: tool, path: path, version: nil, status: .broken(error.localizedDescription))
        }
    }

    public static func detectAll(overrides: [Tool: String] = [:]) async -> [Tool: ToolInfo] {
        await withTaskGroup(of: ToolInfo.self, returning: [Tool: ToolInfo].self) { group in
            for tool in Tool.allCases {
                group.addTask { await detect(tool, override: overrides[tool]) }
            }
            var result: [Tool: ToolInfo] = [:]
            for await info in group { result[info.tool] = info }
            return result
        }
    }

    static func parseVersion(tool: Tool, output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        switch tool {
        case .ytDLP:
            let v = firstLine.trimmingCharacters(in: .whitespaces)
            return v.range(of: #"^\d{4}\.\d{2}\.\d{2}"#, options: .regularExpression) != nil ? v : nil
        case .ffmpeg, .ffprobe:
            // "ffmpeg version 8.1 Copyright ..." or "ffmpeg version n7.1-3-gabc"
            guard let range = firstLine.range(of: #"version\s+(\S+)"#, options: .regularExpression) else { return nil }
            return String(firstLine[range]).replacingOccurrences(of: "version", with: "").trimmingCharacters(in: .whitespaces)
        case .fpcalc:
            guard let range = firstLine.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
            return String(firstLine[range])
        }
    }

    // MARK: Updates

    public static func locateHomebrew() -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// True when the executable lives inside a Homebrew prefix.
    public static func isHomebrewManaged(_ path: URL?) -> Bool {
        guard let p = path?.resolvingSymlinksInPath().path else { return false }
        return p.hasPrefix("/opt/homebrew/") || p.hasPrefix("/usr/local/Cellar/") || p.hasPrefix("/usr/local/Homebrew/")
    }

    /// Reports outdated tools. Homebrew installs are checked with `brew outdated`; a standalone
    /// yt-dlp release is compared against the latest GitHub release tag. Read-only; never upgrades.
    public static func checkForUpdates(tools: [Tool: ToolInfo]) async -> ToolUpdateReport {
        var items: [ToolUpdateReport.Item] = []
        var messages: [String] = []

        let brewTools = tools.values.filter { $0.isUsable && isHomebrewManaged($0.path) }
        let formulas = Array(Set(brewTools.map(\.tool.homebrewFormula))).sorted()
        if !formulas.isEmpty {
            if let brew = locateHomebrew() {
                do {
                    let output = try await ProcessRunner.run(brew, arguments: ["outdated", "--json=v2", "--formula"] + formulas)
                    if let data = output.stdout.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let list = json["formulae"] as? [[String: Any]] {
                        for entry in list {
                            guard let name = entry["name"] as? String,
                                  let installed = (entry["installed_versions"] as? [String])?.last,
                                  let latest = entry["current_version"] as? String else { continue }
                            items.append(.init(formula: name, installed: installed, latest: latest, remedy: "brew upgrade \(name)"))
                        }
                    } else {
                        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        messages.append(detail.isEmpty ? "Could not read Homebrew's response." : detail)
                    }
                } catch {
                    messages.append(error.localizedDescription)
                }
            } else {
                messages.append("Homebrew was not found.")
            }
        }

        if let ytdlp = tools[.ytDLP], ytdlp.isUsable, !isHomebrewManaged(ytdlp.path), let installed = ytdlp.version {
            if let latest = await latestYTDLPRelease() {
                if latest != installed, latest > installed {
                    let writable = ytdlp.path.map { FileManager.default.isWritableFile(atPath: $0.path) } ?? false
                    let remedy = writable ? "yt-dlp -U" : "sudo yt-dlp -U   (or: brew install yt-dlp)"
                    items.append(.init(formula: "yt-dlp", installed: installed, latest: latest, remedy: remedy))
                }
            } else {
                messages.append("Could not reach GitHub to check the standalone yt-dlp release.")
            }
        }
        for info in tools.values where !info.isUsable && info.tool.isRequired {
            messages.append("\(info.tool.rawValue) is missing or broken — brew install \(info.tool.homebrewFormula)")
        }
        return ToolUpdateReport(outdated: items, message: messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }

    /// Latest yt-dlp version from the GitHub release redirect (no API rate limit involved).
    static func latestYTDLPRelease() async -> String? {
        guard let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("LocalMusic/0.1 (update check)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url?.absoluteString,
              let range = final.range(of: "/releases/tag/") else { return nil }
        let tag = String(final[range.upperBound...])
        return tag.range(of: #"^\d{4}\.\d{2}\.\d{2}"#, options: .regularExpression) != nil ? tag : nil
    }
}
