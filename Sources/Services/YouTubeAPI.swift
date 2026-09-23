import Foundation

enum YouTubeAPIError: LocalizedError, Equatable {
    case missingKey
    case quotaExceeded
    case invalidKey
    case network(String)
    case decoding
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No YouTube API key set. Add one in Settings to load tutorial lists automatically."
        case .quotaExceeded:
            return "Today's YouTube API quota is used up. Cached tutorials still work; fresh lookups resume tomorrow."
        case .invalidKey:
            return "YouTube rejected that API key. Check it's a Data API v3 key with no HTTP referrer restriction."
        case .network(let detail):
            return "Couldn't reach YouTube: \(detail)"
        case .decoding:
            return "YouTube returned something unexpected."
        case .noResults:
            return "No videos matched."
        }
    }
}

/// Thin YouTube Data API v3 client.
///
/// Only two endpoints are used, and both are read-only metadata: `search.list` to find candidates
/// and `videos.list` to get the statistics, duration and embeddable flag needed to rank them.
/// No media is ever fetched through this client — playback always goes through the IFrame player.
///
/// Quota note: `search.list` costs 100 units against a 10,000 unit/day default, so results are
/// cached for a week and a single choreography costs one search plus one cheap detail call.
struct YouTubeAPI {
    var apiKey: String?
    var regionCode: String = "US"

    private let base = URL(string: "https://www.googleapis.com/youtube/v3/")!

    // MARK: - Public

    struct SearchHit {
        var videoID: String
        var title: String
        var channelTitle: String
        var channelID: String
        var description: String
        var publishedAt: Date
        var thumbnailURL: URL?
    }

    func search(query: String, maxResults: Int = 25) async throws -> [SearchHit] {
        guard let apiKey, !apiKey.isEmpty else { throw YouTubeAPIError.missingKey }
        var components = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "part", value: "snippet"),
            .init(name: "q", value: query),
            .init(name: "type", value: "video"),
            .init(name: "maxResults", value: String(min(50, maxResults))),
            .init(name: "videoEmbeddable", value: "true"),
            .init(name: "regionCode", value: regionCode),
            .init(name: "safeSearch", value: "none"),
            .init(name: "key", value: apiKey)
        ]
        let data = try await fetch(components.url!)
        do {
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.items.compactMap { item in
                guard let videoID = item.id.videoId else { return nil }
                return SearchHit(
                    videoID: videoID,
                    title: item.snippet.title.decodedHTMLEntities,
                    channelTitle: item.snippet.channelTitle,
                    channelID: item.snippet.channelId,
                    description: item.snippet.description,
                    publishedAt: Self.iso8601.date(from: item.snippet.publishedAt) ?? Date.distantPast,
                    thumbnailURL: item.snippet.thumbnails.best
                )
            }
        } catch {
            throw YouTubeAPIError.decoding
        }
    }

    struct VideoDetail {
        var videoID: String
        var durationSeconds: Int
        var viewCount: Int
        var likeCount: Int
        var isEmbeddable: Bool
        var defaultAudioLanguage: String?
        var tags: [String]
    }

    func details(for videoIDs: [String]) async throws -> [String: VideoDetail] {
        guard let apiKey, !apiKey.isEmpty else { throw YouTubeAPIError.missingKey }
        guard !videoIDs.isEmpty else { return [:] }

        var all: [String: VideoDetail] = [:]
        // videos.list accepts up to 50 ids per call and costs 1 unit regardless — batching here
        // is basically free compared with the 100-unit search.
        for chunk in videoIDs.chunked(into: 50) {
            var components = URLComponents(url: base.appendingPathComponent("videos"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                .init(name: "part", value: "contentDetails,statistics,status,snippet"),
                .init(name: "id", value: chunk.joined(separator: ",")),
                .init(name: "key", value: apiKey)
            ]
            let data = try await fetch(components.url!)
            guard let decoded = try? JSONDecoder().decode(VideosResponse.self, from: data) else {
                throw YouTubeAPIError.decoding
            }
            for item in decoded.items {
                all[item.id] = VideoDetail(
                    videoID: item.id,
                    durationSeconds: Self.parseISODuration(item.contentDetails.duration),
                    viewCount: Int(item.statistics.viewCount ?? "0") ?? 0,
                    likeCount: Int(item.statistics.likeCount ?? "0") ?? 0,
                    isEmbeddable: item.status.embeddable ?? true,
                    defaultAudioLanguage: item.snippet.defaultAudioLanguage,
                    tags: item.snippet.tags ?? []
                )
            }
        }
        return all
    }

    // MARK: - Networking

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200:
                return data
            case 403:
                // 403 covers both "quota gone" and "key not allowed"; the reason string is the
                // only way to tell them apart, and they need different advice.
                let reason = String(data: data, encoding: .utf8) ?? ""
                if reason.contains("quotaExceeded") || reason.contains("dailyLimitExceeded") {
                    throw YouTubeAPIError.quotaExceeded
                }
                throw YouTubeAPIError.invalidKey
            case 400:
                throw YouTubeAPIError.invalidKey
            default:
                throw YouTubeAPIError.network("HTTP \(http.statusCode)")
            }
        } catch let error as YouTubeAPIError {
            throw error
        } catch {
            throw YouTubeAPIError.network(error.localizedDescription)
        }
    }

    // MARK: - Parsing

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// YouTube reports durations as ISO 8601 periods, e.g. "PT12M34S" or "PT1H2M3S".
    static func parseISODuration(_ text: String) -> Int {
        var seconds = 0
        var number = ""
        var started = false
        for ch in text {
            if ch == "P" { continue }
            if ch == "T" { started = true; continue }
            if ch.isNumber {
                number.append(ch)
                continue
            }
            let value = Int(number) ?? 0
            number = ""
            switch ch {
            case "H": seconds += value * 3600
            case "M": seconds += started ? value * 60 : value * 60 * 60 * 24 * 30
            case "S": seconds += value
            case "D": seconds += value * 86_400
            case "W": seconds += value * 604_800
            default: break
            }
        }
        return seconds
    }

    // MARK: - Wire types

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let videoId: String? }
            let id: ID
            let snippet: Snippet
        }
        let items: [Item]
    }

    private struct Snippet: Decodable {
        let title: String
        let description: String
        let channelTitle: String
        let channelId: String
        let publishedAt: String
        let thumbnails: Thumbnails
    }

    private struct Thumbnails: Decodable {
        struct Image: Decodable { let url: String }
        let medium: Image?
        let high: Image?
        let standard: Image?
        let maxres: Image?

        var best: URL? {
            let candidate = maxres?.url ?? standard?.url ?? high?.url ?? medium?.url
            return candidate.flatMap(URL.init(string:))
        }
    }

    private struct VideosResponse: Decodable {
        struct Item: Decodable {
            struct ContentDetails: Decodable { let duration: String }
            struct Statistics: Decodable {
                let viewCount: String?
                let likeCount: String?
            }
            struct Status: Decodable { let embeddable: Bool? }
            struct DetailSnippet: Decodable {
                let defaultAudioLanguage: String?
                let tags: [String]?
            }
            let id: String
            let contentDetails: ContentDetails
            let statistics: Statistics
            let status: Status
            let snippet: DetailSnippet
        }
        let items: [Item]
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension String {
    /// YouTube snippets arrive HTML-escaped ("Don&#39;t"), which looks broken in a native list.
    var decodedHTMLEntities: String {
        guard contains("&") else { return self }
        var result = self
        let map = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ]
        for (entity, char) in map {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}
