import Foundation

/// Orchestrates "what video should this screen show" across the API, the cache and the manual
/// fallbacks. Deliberately usable with no API key at all: without one the app still works, it just
/// asks the user to paste links instead of finding them.
final class ContentService {
    static let shared = ContentService()
    private init() {}

    var apiKey: String? {
        get { KeychainStore.get(KeychainStore.Account.youTubeAPIKey) }
        set { KeychainStore.set(newValue, for: KeychainStore.Account.youTubeAPIKey) }
    }

    var hasAPIKey: Bool {
        let key = apiKey
        return !(key ?? "").isEmpty
    }

    private func api(region: String) -> YouTubeAPI {
        YouTubeAPI(apiKey: apiKey, regionCode: region)
    }

    // MARK: - Reference video

    /// Finds the official dance practice (or performance/MV, per the entry) for a choreography.
    /// Returns the video ID; the caller caches it so this costs one search per routine, ever.
    func resolveReferenceVideo(for choreography: Choreography, region: String) async throws -> String {
        if let known = choreography.knownPracticeVideoID { return known }
        let client = api(region: region)
        let hits = try await client.search(query: choreography.practiceSearch.query, maxResults: 20)
        guard !hits.isEmpty else { throw YouTubeAPIError.noResults }
        let details = (try? await client.details(for: hits.map(\.videoID))) ?? [:]
        guard let best = TutorialRanker.pickReference(
            hits: hits,
            details: details,
            seed: choreography.practiceSearch,
            choreography: choreography
        ) else { throw YouTubeAPIError.noResults }
        return best.videoID
    }

    // MARK: - Tutorials

    func fetchTutorials(for choreography: Choreography,
                        channelBoosts: [String],
                        settings: PracticeSettings) async throws -> [TutorialVideo] {
        let client = api(region: settings.tutorialRegionCode)

        // Two passes. The first asks for mirrored tutorials explicitly because that phrasing
        // surfaces a genuinely different set of channels; the second is the broad query. Merged
        // and ranked together they cover far more of the useful long tail than either alone.
        //
        // The broad pass is the one allowed to fail the call: if the mirrored pass errors (or the
        // quota runs out mid-way) we would still rather show the broad results than nothing.
        let broadHits = try await client.search(
            query: choreography.tutorialSearch.query, maxResults: 25
        )
        let mirroredHits = (try? await client.search(
            query: choreography.tutorialSearch.query + " mirrored", maxResults: 15
        )) ?? []

        let combined = mirroredHits + broadHits
        var unique: [YouTubeAPI.SearchHit] = []
        var seen = Set<String>()
        for hit in combined where seen.insert(hit.videoID).inserted {
            unique.append(hit)
        }
        guard !unique.isEmpty else { throw YouTubeAPIError.noResults }

        let details = (try? await client.details(for: unique.map(\.videoID))) ?? [:]
        let ranker = TutorialRanker(
            choreography: choreography,
            channelBoosts: channelBoosts,
            preferMirrored: settings.preferMirroredTutorials,
            languageHint: settings.tutorialLanguageHint
        )
        let ranked = ranker.rank(
            hits: unique,
            details: details,
            excludeTerms: choreography.tutorialSearch.excludeTerms
        )
        guard !ranked.isEmpty else { throw YouTubeAPIError.noResults }
        return ranked
    }

    /// Builds a `TutorialVideo` from a pasted link. This is the escape hatch that keeps the app
    /// useful with no API key, and the way a user pins the one tutorial they actually like.
    func lookupSingleVideo(url: String, region: String) async throws -> TutorialVideo {
        guard let videoID = YouTubeLink.videoID(from: url) else {
            throw YouTubeAPIError.network("That doesn't look like a YouTube link.")
        }
        guard hasAPIKey else {
            // No key: we still know the ID, which is all the player needs. Metadata fills in as
            // placeholders so the row renders.
            return TutorialVideo(
                id: videoID, title: "Pasted video", channelTitle: "YouTube", channelID: "",
                description: "", publishedAt: Date(), durationSeconds: 0, viewCount: 0,
                likeCount: 0, thumbnailURL: YouTubeLink.thumbnailURL(for: videoID),
                badges: [], score: 0, isEmbeddable: true
            )
        }
        let client = api(region: region)
        let details = try await client.details(for: [videoID])
        let detail = details[videoID]
        return TutorialVideo(
            id: videoID,
            title: "Pasted video",
            channelTitle: "YouTube",
            channelID: "",
            description: "",
            publishedAt: Date(),
            durationSeconds: detail?.durationSeconds ?? 0,
            viewCount: detail?.viewCount ?? 0,
            likeCount: detail?.likeCount ?? 0,
            thumbnailURL: YouTubeLink.thumbnailURL(for: videoID),
            badges: [],
            score: 0,
            isEmbeddable: detail?.isEmbeddable ?? true
        )
    }
}

/// URL/ID plumbing kept in one place — YouTube has an inconvenient number of link shapes.
enum YouTubeLink {
    static func videoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A bare ID is 11 chars of the YouTube alphabet.
        if trimmed.count == 11, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }

        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        // /embed/ID, /shorts/ID, /live/ID
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) {
            return parts[1]
        }
        return nil
    }

    static func thumbnailURL(for videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components.url
    }

    static func watchURL(for videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }
}
