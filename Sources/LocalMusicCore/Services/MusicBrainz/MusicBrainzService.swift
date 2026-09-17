import Foundation

/// MusicBrainz web service client. Honors the 1 request/second rule, identifies the app with a
/// descriptive User-Agent, caches responses on disk, and treats 503s as "MusicBrainz is down".
public actor MusicBrainzService {
    public static let userAgent = "LocalMusic/0.1 (open-source macOS music organizer; local desktop app)"
    static let base = URL(string: "https://musicbrainz.org/ws/2/")!
    static let minimumInterval: TimeInterval = 1.1

    private let cache: MetadataCache
    private let session: URLSession
    private var lastRequest = Date.distantPast
    /// Circuit breaker: after retries are exhausted, further lookups fail fast until this time so a
    /// throttled or down MusicBrainz cannot stall every job in the queue for minutes.
    private var unavailableUntil: Date?
    static let cooldown: TimeInterval = 60

    public init(cache: MetadataCache = MetadataCache(), session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    // MARK: Search

    /// Searches recordings by title/artist. Returns parsed recordings ordered by MusicBrainz's score.
    public func searchRecordings(title: String, artist: String?, duration: TimeInterval? = nil, limit: Int = 25) async throws -> [MBRecording] {
        let query = Self.luceneQuery(title: title, artist: artist, duration: duration)
        let key = "mb:recording:\(limit):\(query)"
        if let cached = cache.get(key) {
            return Self.parseRecordingSearch(cached)
        }
        var components = URLComponents(url: Self.base.appendingPathComponent("recording"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let data = try await get(components.url!)
        cache.set(key, data)
        return Self.parseRecordingSearch(data)
    }

    /// Looks up recordings by MBID list (used after an AcoustID hit).
    public func recording(id: String) async throws -> MBRecording? {
        let key = "mb:recording-id:\(id)"
        if let cached = cache.get(key) { return Self.parseRecording(cached) }
        var components = URLComponents(url: Self.base.appendingPathComponent("recording/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "artist-credits+releases+release-groups+media+isrcs"),
        ]
        let data = try await get(components.url!)
        cache.set(key, data)
        return Self.parseRecording(data)
    }

    /// Lucene query with special characters escaped; artist and a ±15 s duration window are optional.
    public static func luceneQuery(title: String, artist: String?, duration: TimeInterval? = nil) -> String {
        var q = "recording:\"\(escape(title))\""
        if let artist, !artist.trimmingCharacters(in: .whitespaces).isEmpty {
            q += " AND artist:\"\(escape(artist))\""
        }
        if let duration, duration > 0 {
            let lo = max(0, Int((duration - 15) * 1000)), hi = Int((duration + 15) * 1000)
            q += " AND dur:[\(lo) TO \(hi)]"
        }
        return q
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Transport

    private func get(_ url: URL) async throws -> Data {
        if let until = unavailableUntil {
            if until > Date() {
                throw LocalMusicError(kind: .network, message: "MusicBrainz is rate-limiting this network; lookups are paused for a minute. The track keeps its original metadata; use Re-identify Metadata later.")
            }
            unavailableUntil = nil
        }
        var attempt = 0
        while true {
            attempt += 1
            let wait = Self.minimumInterval - Date().timeIntervalSince(lastRequest)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastRequest = Date()
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            Log.debug("GET \(url.absoluteString)", .metadata)
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw LocalMusicError(kind: .network, message: "Could not reach MusicBrainz.", technicalDetails: error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return data
            case 503, 429, 502, 504:
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(Double(attempt) * 3))
                    continue
                }
                unavailableUntil = Date().addingTimeInterval(Self.cooldown)
                Log.warning("MusicBrainz unavailable (HTTP \(status)); pausing lookups for \(Int(Self.cooldown))s", .metadata)
                throw LocalMusicError(kind: .network, message: "MusicBrainz is busy or down (HTTP \(status)). The track was kept with its original metadata; use Re-identify Metadata later.", technicalDetails: String(data: data, encoding: .utf8))
            case 404:
                return Data("{}".utf8)
            default:
                throw LocalMusicError(kind: .network, message: "MusicBrainz returned HTTP \(status).", technicalDetails: String(data: data, encoding: .utf8))
            }
        }
    }

    // MARK: Parsing

    public static func parseRecordingSearch(_ data: Data) -> [MBRecording] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["recordings"] as? [[String: Any]] else { return [] }
        return list.compactMap(parseRecording(dict:))
    }

    public static func parseRecording(_ data: Data) -> MBRecording? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseRecording(dict: json)
    }

    static func parseRecording(dict r: [String: Any]) -> MBRecording? {
        guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
        let credit = artistCredit(r["artist-credit"])
        let artistIDs = (r["artist-credit"] as? [[String: Any]])?.compactMap { ($0["artist"] as? [String: Any])?["id"] as? String } ?? []
        let releases = (r["releases"] as? [[String: Any]])?.compactMap(parseRelease(dict:)) ?? []
        let isrcs = (r["isrcs"] as? [String]) ?? (r["isrcs"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        return MBRecording(id: id, title: title, artistCredit: credit.isEmpty ? "Unknown Artist" : credit, artistIDs: artistIDs,
                           lengthMs: r["length"] as? Int, searchScore: r["score"] as? Int ?? 0, releases: releases, isrcs: isrcs)
    }

    static func parseRelease(dict r: [String: Any]) -> MBRelease? {
        guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
        let group = r["release-group"] as? [String: Any]
        var trackNumber: Int?, discNumber: Int?, trackCount: Int?
        if let media = r["media"] as? [[String: Any]], let m = media.first {
            discNumber = m["position"] as? Int
            trackCount = m["track-count"] as? Int
            if let track = (m["track"] as? [[String: Any]])?.first {
                trackNumber = (track["number"] as? String).flatMap { Int($0.filter(\.isNumber)) } ?? (track["position"] as? Int)
            } else if let offset = m["track-offset"] as? Int {
                trackNumber = offset + 1
            }
        }
        let credit = artistCredit(r["artist-credit"])
        return MBRelease(id: id, title: title, date: r["date"] as? String, status: r["status"] as? String,
                         country: r["country"] as? String, primaryType: group?["primary-type"] as? String,
                         secondaryTypes: group?["secondary-types"] as? [String] ?? [], releaseGroupID: group?["id"] as? String,
                         trackNumber: trackNumber, discNumber: discNumber, trackCount: trackCount,
                         artistCredit: credit.isEmpty ? nil : credit)
    }

    static func artistCredit(_ any: Any?) -> String {
        guard let credits = any as? [[String: Any]] else { return "" }
        return credits.map { c in
            let name = (c["name"] as? String) ?? ((c["artist"] as? [String: Any])?["name"] as? String) ?? ""
            return name + ((c["joinphrase"] as? String) ?? "")
        }.joined()
    }
}
