import Foundation

/// Where a piece of local media came from. This is the hinge the whole rights model turns on:
/// mirroring, ghost overlay, audio muxing and export are only unlocked for media the user
/// actually holds rights to. Embedded YouTube playback never enters this path.
enum MediaProvenance: String, Codable, CaseIterable, Identifiable, Hashable {
    case ownFootage           // shot by the user, e.g. their own class recording
    case purchasedOrLicensed  // user bought it / holds a licence
    case openLicensed         // Creative Commons or otherwise openly licensed
    case classOrInstructor    // shared by their studio/instructor with permission

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ownFootage: return "I filmed this"
        case .purchasedOrLicensed: return "I bought or licensed it"
        case .openLicensed: return "Creative Commons / open licence"
        case .classOrInstructor: return "Shared by my studio or instructor"
        }
    }

    var detail: String {
        switch self {
        case .ownFootage: return "Practice room footage, class recordings, your own covers."
        case .purchasedOrLicensed: return "Paid choreography packs, licensed downloads."
        case .openLicensed: return "Explicitly licensed for reuse by the uploader."
        case .classOrInstructor: return "Your teacher gave you the file to practice with."
        }
    }
}

enum MediaKind: String, Codable, Hashable {
    case video
    case audio
}

/// A file the user imported into the app's sandbox.
struct LibraryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var subtitle: String?
    var kind: MediaKind
    var filename: String            // relative to MediaStore.mediaDirectory
    var durationSeconds: Double
    var importedAt: Date = Date()
    var provenance: MediaProvenance
    /// Set when the user links this file to a catalog choreography, which lets the app show
    /// the tutorial list for it and count practice time toward that routine.
    var choreographyID: String?
    /// Audio companion for a silent reference video, or the track to mux into takes.
    var linkedAudioItemID: UUID?
    var naturalSizeWidth: Double?
    var naturalSizeHeight: Double?

    var isPortrait: Bool {
        guard let w = naturalSizeWidth, let h = naturalSizeHeight else { return false }
        return h > w
    }
}

/// One practice take the user recorded.
struct Recording: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var filename: String            // relative to MediaStore.recordingsDirectory
    var createdAt: Date = Date()
    var durationSeconds: Double
    var choreographyID: String?
    var libraryItemID: UUID?
    var sectionLabel: String?
    /// Rate the reference was playing at while this take was recorded.
    var referenceRate: Double = 1.0
    var wasMirrored: Bool = false
    var micEnabled: Bool = true
    var musicMuxed: Bool = false
    var loopStart: Double?
    var loopEnd: Double?
    var selfRating: Int?            // 1...5
    var note: String?

    var rateText: String {
        referenceRate == 1.0 ? "full speed" : String(format: "%.2gx", referenceRate)
    }
}
