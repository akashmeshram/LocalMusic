import Foundation

public enum Tool: String, CaseIterable, Sendable, Identifiable, Codable {
    case ytDLP = "yt-dlp"
    case ffmpeg
    case ffprobe
    case fpcalc

    public var id: String { rawValue }
    public var executableName: String { rawValue }
    public var isRequired: Bool { self != .fpcalc }
    public var homebrewFormula: String {
        switch self {
        case .ytDLP: "yt-dlp"
        case .ffmpeg, .ffprobe: "ffmpeg"
        case .fpcalc: "chromaprint"
        }
    }
    var versionArguments: [String] {
        switch self {
        case .ytDLP: ["--version"]
        case .ffmpeg, .ffprobe: ["-version"]
        case .fpcalc: ["-version"]
        }
    }
}

public struct ToolInfo: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        case ok
        case missing
        /// Found on disk but failed to run (e.g. broken dylib link after a Homebrew upgrade).
        case broken(String)
    }

    public let tool: Tool
    public let path: URL?
    public let version: String?
    public let status: Status

    public var id: Tool { tool }
    public var isUsable: Bool { status == .ok }

    public init(tool: Tool, path: URL?, version: String?, status: Status) {
        self.tool = tool
        self.path = path
        self.version = version
        self.status = status
    }
}

public struct ToolUpdateReport: Sendable, Hashable {
    public struct Item: Sendable, Hashable, Identifiable {
        public let formula: String
        public let installed: String
        public let latest: String
        /// Command the user can run to update (never executed by the app).
        public let remedy: String
        public var id: String { formula }
        public init(formula: String, installed: String, latest: String, remedy: String) {
            self.formula = formula
            self.installed = installed
            self.latest = latest
            self.remedy = remedy
        }
    }
    public let outdated: [Item]
    public let checkedAt: Date
    public let message: String?

    public init(outdated: [Item], checkedAt: Date = Date(), message: String? = nil) {
        self.outdated = outdated
        self.checkedAt = checkedAt
        self.message = message
    }
}
