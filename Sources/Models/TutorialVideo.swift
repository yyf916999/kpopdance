import Foundation

/// Signals we can derive from YouTube metadata that actually matter to someone trying to
/// learn a routine. These drive the filter chips in the tutorial list.
enum TutorialBadge: String, Codable, CaseIterable, Identifiable, Hashable {
    case mirrored
    case slowed
    case stepByStep
    case counts
    case fullRoutine
    case shortForm
    case korean
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mirrored: return "Mirrored"
        case .slowed: return "Slowed"
        case .stepByStep: return "Step by step"
        case .counts: return "Counts"
        case .fullRoutine: return "Full routine"
        case .shortForm: return "Short"
        case .korean: return "Korean"
        case .english: return "English"
        }
    }

    var symbol: String {
        switch self {
        case .mirrored: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .slowed: return "tortoise"
        case .stepByStep: return "list.number"
        case .counts: return "metronome"
        case .fullRoutine: return "music.note.list"
        case .shortForm: return "bolt"
        case .korean: return "character.bubble"
        case .english: return "text.bubble"
        }
    }
}

struct TutorialVideo: Identifiable, Codable, Hashable {
    let id: String              // YouTube video ID
    var title: String
    var channelTitle: String
    var channelID: String
    var description: String
    var publishedAt: Date
    var durationSeconds: Int
    var viewCount: Int
    var likeCount: Int
    var thumbnailURL: URL?
    var badges: [TutorialBadge]
    var score: Double
    var isEmbeddable: Bool

    var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }

    var durationText: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var viewCountText: String {
        switch viewCount {
        case 1_000_000...: return String(format: "%.1fM views", Double(viewCount) / 1_000_000)
        case 1_000...: return String(format: "%.0fK views", Double(viewCount) / 1_000)
        default: return "\(viewCount) views"
        }
    }
}

/// Cached result of a tutorial lookup so we do not burn YouTube API quota on every screen open.
struct TutorialCacheEntry: Codable {
    var choreographyID: String
    var videos: [TutorialVideo]
    var fetchedAt: Date

    func isFresh(ttl: TimeInterval = 60 * 60 * 24 * 7) -> Bool {
        Date().timeIntervalSince(fetchedAt) < ttl
    }
}
