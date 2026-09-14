import Foundation

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        string(Int64(bytesPerSecond)) + "/s"
    }
}

public enum DurationFormatter {
    /// `3:07` or `1:02:33`.
    public static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–:––" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// ETA style, or `—` when unknown.
    public static func eta(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        return string(TimeInterval(seconds))
    }
}
