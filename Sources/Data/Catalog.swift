import Foundation

/// Decoded shape of `catalog.json`. Kept separate from `Choreography` so the on-disk format can
/// stay terse (no repeated query strings) while the model stays explicit.
private struct CatalogFile: Decodable {
    struct Entry: Decodable {
        let id: String
        let title: String
        let artist: String
        let year: Int
        let difficulty: Int
        let referenceKind: String
        let tags: [String]
        let officialChannels: [String]
        let knownPracticeVideoID: String?
    }

    let version: Int
    let tutorialChannelBoosts: [String]
    let globalTutorialExcludeTerms: [String]
    let globalPracticeExcludeTerms: [String]
    let choreographies: [Entry]
}

struct Catalog {
    let choreographies: [Choreography]
    let tutorialChannelBoosts: [String]

    static let empty = Catalog(choreographies: [], tutorialChannelBoosts: [])

    static func loadBundled() -> Catalog {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            assertionFailure("catalog.json is missing from the app bundle")
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(CatalogFile.self, from: data)
            let items = file.choreographies.map { entry -> Choreography in
                Choreography(
                    id: entry.id,
                    title: entry.title,
                    artist: entry.artist,
                    year: entry.year,
                    difficulty: Difficulty(rawValue: entry.difficulty) ?? .moderate,
                    referenceKind: ReferenceKind(rawValue: entry.referenceKind) ?? .dancePractice,
                    tags: entry.tags,
                    practiceSearch: practiceSeed(for: entry, excluding: file.globalPracticeExcludeTerms),
                    tutorialSearch: tutorialSeed(for: entry, excluding: file.globalTutorialExcludeTerms),
                    knownPracticeVideoID: entry.knownPracticeVideoID
                )
            }
            return Catalog(choreographies: items, tutorialChannelBoosts: file.tutorialChannelBoosts)
        } catch {
            assertionFailure("catalog.json failed to decode: \(error)")
            return .empty
        }
    }

    private static func practiceSeed(for entry: CatalogFile.Entry, excluding terms: [String]) -> VideoSearchSeed {
        let suffix: String
        switch ReferenceKind(rawValue: entry.referenceKind) ?? .dancePractice {
        case .dancePractice: suffix = "dance practice"
        case .performance: suffix = "performance video"
        case .musicVideo: suffix = "official mv"
        }
        return VideoSearchSeed(
            query: "\(entry.artist) \(entry.title) \(suffix)",
            channelHints: entry.officialChannels,
            excludeTerms: terms
        )
    }

    private static func tutorialSeed(for entry: CatalogFile.Entry, excluding terms: [String]) -> VideoSearchSeed {
        VideoSearchSeed(
            query: "\(entry.artist) \(entry.title) dance tutorial",
            channelHints: [],
            excludeTerms: terms
        )
    }

    func choreography(id: String) -> Choreography? {
        choreographies.first { $0.id == id }
    }

    /// Facets used by the Discover filter row, derived from the data rather than hardcoded.
    var allTags: [String] {
        Array(Set(choreographies.flatMap { $0.tags })).sorted()
    }

    var allArtists: [String] {
        Array(Set(choreographies.map { $0.artist })).sorted()
    }
}
