import Foundation

/// Chromaprint fingerprint via `fpcalc`, and AcoustID lookup. Entirely optional: without an API
/// key or fpcalc the app simply skips this stage.
public struct FingerprintService: Sendable {
    public struct Fingerprint: Sendable, Hashable {
        public let duration: Int
        public let fingerprint: String
    }

    public let fpcalc: URL?

    public init(fpcalc: URL?) {
        self.fpcalc = fpcalc
    }

    public var isAvailable: Bool { fpcalc != nil }

    public func fingerprint(_ file: URL) async throws -> Fingerprint {
        guard let fpcalc else {
            throw LocalMusicError(kind: .toolMissing, message: "fpcalc (Chromaprint) is not installed. Install it with: brew install chromaprint")
        }
        let out = try await ProcessRunner.run(fpcalc, arguments: ["-json", "-length", "120", file.path])
        guard out.exitCode == 0, let data = out.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fp = json["fingerprint"] as? String else {
            throw LocalMusicError(kind: .toolFailed, message: "fpcalc could not fingerprint the file.", technicalDetails: out.stderr)
        }
        let duration = (json["duration"] as? Double).map { Int($0) } ?? (json["duration"] as? Int) ?? 0
        return Fingerprint(duration: duration, fingerprint: fp)
    }
}

public struct AcoustIDService: Sendable {
    public struct Match: Sendable, Hashable {
        public let score: Double
        public let recordingIDs: [String]
    }

    static let endpoint = URL(string: "https://api.acoustid.org/v2/lookup")!
    let cache: MetadataCache
    let session: URLSession

    public init(cache: MetadataCache = MetadataCache(), session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    /// Looks up a fingerprint. The API key is sent in the request body and never logged.
    public func lookup(_ fp: FingerprintService.Fingerprint, apiKey: String) async throws -> [Match] {
        let key = "acoustid:\(fp.duration):\(fp.fingerprint.prefix(64)):\(fp.fingerprint.count)"
        if let cached = cache.get(key) { return Self.parse(cached) }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(MusicBrainzService.userAgent, forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "duration", value: String(fp.duration)),
            URLQueryItem(name: "fingerprint", value: fp.fingerprint),
            URLQueryItem(name: "meta", value: "recordingids"),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        Log.info("AcoustID lookup (key \(Log.redacted(apiKey)))", .metadata)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalMusicError(kind: .network, message: "AcoustID lookup failed.", technicalDetails: String(data: data, encoding: .utf8))
        }
        cache.set(key, data)
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [Match] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? String) == "ok",
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let score = r["score"] as? Double else { return nil }
            let ids = (r["recordings"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            return ids.isEmpty ? nil : Match(score: score, recordingIDs: ids)
        }.sorted { $0.score > $1.score }
    }
}
