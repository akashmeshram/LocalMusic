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

    /// Asks Homebrew which of the tool formulas are outdated. Read-only; never upgrades.
    public static func checkForUpdates(tools: [Tool] = [.ytDLP, .ffmpeg]) async -> ToolUpdateReport {
        guard let brew = locateHomebrew() else {
            return ToolUpdateReport(outdated: [], message: "Homebrew was not found. Check for updates manually.")
        }
        let formulas = Array(Set(tools.map(\.homebrewFormula))).sorted()
        do {
            let output = try await ProcessRunner.run(brew, arguments: ["outdated", "--json=v2", "--formula"] + formulas)
            guard let data = output.stdout.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["formulae"] as? [[String: Any]]
            else {
                let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return ToolUpdateReport(outdated: [], message: detail.isEmpty ? "Could not read Homebrew's response." : detail)
            }
            let items = list.compactMap { entry -> ToolUpdateReport.Item? in
                guard let name = entry["name"] as? String,
                      let installed = (entry["installed_versions"] as? [String])?.last,
                      let latest = entry["current_version"] as? String else { return nil }
                return ToolUpdateReport.Item(formula: name, installed: installed, latest: latest)
            }
            let notBrew = formulas.filter { f in output.stderr.contains(f) && output.stderr.lowercased().contains("no available formula") }
            let message = notBrew.isEmpty ? nil : "Not managed by Homebrew: \(notBrew.joined(separator: ", "))"
            return ToolUpdateReport(outdated: items, message: message)
        } catch {
            return ToolUpdateReport(outdated: [], message: error.localizedDescription)
        }
    }
}
