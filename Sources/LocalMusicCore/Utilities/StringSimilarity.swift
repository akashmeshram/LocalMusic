import Foundation

/// Fuzzy string comparison used for ranking metadata candidates. All scores are 0…1.
public enum StringSimilarity {
    /// Normalized Levenshtein similarity on folded strings.
    public static func levenshtein(_ a: String, _ b: String) -> Double {
        let x = Array(fold(a)), y = Array(fold(b))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Jaccard overlap of word tokens; robust to reordering ("Daft Punk" vs "Punk, Daft").
    public static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        if ta.isEmpty && tb.isEmpty { return 1 }
        if ta.isEmpty || tb.isEmpty { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    /// Best of edit-distance and token similarity, with a bonus when one string contains the other.
    public static func score(_ a: String, _ b: String) -> Double {
        let fa = fold(a), fb = fold(b)
        if fa == fb { return 1 }
        var s = max(levenshtein(fa, fb), tokenOverlap(fa, fb))
        if !fa.isEmpty, !fb.isEmpty, fa.contains(fb) || fb.contains(fa) { s = max(s, 0.85) }
        return s
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ s: String) -> [String] {
        fold(s).split(separator: " ").map(String.init).filter { !["the", "a", "an", "feat", "ft"].contains($0) }
    }
}
