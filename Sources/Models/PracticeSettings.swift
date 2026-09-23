import Foundation

enum StudioLayout: String, Codable, CaseIterable, Identifiable, Hashable {
    case referenceOnly
    case splitVertical      // reference above, camera below (portrait phone on a mirror)
    case splitHorizontal    // side by side (landscape / iPad)
    case ghostOverlay       // camera blended over the reference
    case cameraOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .referenceOnly: return "Reference"
        case .splitVertical: return "Stacked"
        case .splitHorizontal: return "Side by side"
        case .ghostOverlay: return "Ghost"
        case .cameraOnly: return "Just me"
        }
    }

    var symbol: String {
        switch self {
        case .referenceOnly: return "rectangle"
        case .splitVertical: return "rectangle.split.1x2"
        case .splitHorizontal: return "rectangle.split.2x1"
        case .ghostOverlay: return "square.stack"
        case .cameraOnly: return "person.crop.rectangle"
        }
    }
}

/// Speeds the app offers. 0.25 is genuinely useful for isolations; anything below that on the
/// YouTube player is not supported by the IFrame API.
enum PlaybackSpeed: Double, CaseIterable, Identifiable, Hashable {
    case quarter = 0.25
    case half = 0.5
    case threeQuarter = 0.75
    case normal = 1.0
    case fast = 1.25
    case double = 2.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .normal: return "1x"
        case .quarter: return "0.25x"
        case .half: return "0.5x"
        case .threeQuarter: return "0.75x"
        case .fast: return "1.25x"
        case .double: return "2x"
        }
    }
}

struct PracticeSettings: Codable, Hashable {
    var mirrorByDefault: Bool = true
    var defaultSpeed: Double = 1.0
    var countdownSeconds: Int = 5
    var micEnabled: Bool = true
    /// Save takes the way the user saw themselves (mirrored) rather than the way a camera
    /// actually sees them. Dancers overwhelmingly want the mirrored version for self-review.
    var saveTakesMirrored: Bool = true
    var useFrontCamera: Bool = true
    var showGridOverlay: Bool = false
    var autoStopAtSectionEnd: Bool = true
    var loopCountBeforeStop: Int = 1
    var defaultLayout: StudioLayout = .splitVertical
    var keepScreenAwakeInStudio: Bool = true
    var preferMirroredTutorials: Bool = true
    var tutorialRegionCode: String = "US"
    var tutorialLanguageHint: String = "en"
    var hasAcceptedRightsNotice: Bool = false
    var recordCountInBeeps: Bool = true

    static let `default` = PracticeSettings()
}
