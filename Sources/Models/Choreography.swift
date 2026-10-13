import Foundation

/// Editorial difficulty. These are opinions, not facts — the seed catalog ships with a
/// first guess and the user can override it per choreography.
enum Difficulty: Int, Codable, CaseIterable, Identifiable, Hashable {
    case rookie = 1
    case easy = 2
    case moderate = 3
    case hard = 4
    case killer = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .rookie: return "Rookie"
        case .easy: return "Easy"
        case .moderate: return "Moderate"
        case .hard: return "Hard"
        case .killer: return "Killer"
        }
    }

    var blurb: String {
        switch self {
        case .rookie: return "Point choreo, lots of repeats, forgiving timing."
        case .easy: return "Simple footwork, one or two tricky bars."
        case .moderate: return "Full-body, needs clean counts and a real chorus run."
        case .hard: return "Fast transitions, isolations, formation-dependent."
        case .killer: return "Pro-level speed and stamina. Expect weeks, not days."
        }
    }
}

/// What kind of reference video we point at. Dance practice videos are the gold standard
/// for learning: fixed camera, full body, no editing.
enum ReferenceKind: String, Codable, Hashable {
    case dancePractice
    case performance
    case musicVideo

    var label: String {
        switch self {
        case .dancePractice: return "Dance Practice"
        case .performance: return "Live Stage"
        case .musicVideo: return "Music Video"
        }
    }
}

/// We never ship guessed YouTube video IDs. IDs rot, get re-uploaded, and guessing them produces
/// a broken app. Each entry ships the search intent, and the resolver finds the current best match
/// once and caches it; only IDs verified against the official channel are pinned in the catalog.
struct VideoSearchSeed: Codable, Hashable {
    var query: String
    /// Channel names we trust for this kind of result, used as a ranking boost only.
    var channelHints: [String] = []
    /// Terms that almost always indicate the wrong kind of video for this slot.
    var excludeTerms: [String] = []
}

struct Choreography: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var artist: String
    var year: Int
    var difficulty: Difficulty
    var referenceKind: ReferenceKind
    var tags: [String]
    var practiceSearch: VideoSearchSeed
    var tutorialSearch: VideoSearchSeed

    /// Optional: the canonical reference ID, checked against the official channel. When set the
    /// video plays with no API key and no search. Left nil wherever it could not be verified.
    var knownPracticeVideoID: String?

    var displaySubtitle: String { "\(artist) · \(String(year))" }
    var searchHaystack: String { "\(title) \(artist) \(tags.joined(separator: " "))".lowercased() }
}

/// A user-marked slice of a choreography: the killing part, the bridge, the bit you keep
/// fumbling. Sections are user data, never catalog data.
struct PracticeSection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String
    var start: Double
    var end: Double
    var note: String?
    var createdAt: Date = Date()

    var duration: Double { max(0, end - start) }
}

/// Everything mutable that belongs to the user for a given choreography.
struct ChoreographyProgress: Codable, Hashable {
    var choreographyID: String
    var isFavorite: Bool = false
    var resolvedPracticeVideoID: String?
    var resolvedAt: Date?
    var difficultyOverride: Difficulty?
    var sections: [PracticeSection] = []
    var pinnedTutorialIDs: [String] = []
    var hiddenTutorialIDs: [String] = []
    var lastPracticedAt: Date?
    var totalPracticeSeconds: Double = 0
    var takeCount: Int = 0
    var notes: String = ""
}
