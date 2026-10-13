import Foundation
import Combine
import SwiftUI

enum LoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case needsAPIKey
}

/// What the top player is currently showing. The official reference is the anchor of the screen;
/// tutorials are swapped in temporarily and the user can always get back to the reference.
enum NowPlayingSource: Equatable {
    case reference
    case tutorial(String)

    var tutorialID: String? {
        if case .tutorial(let id) = self { return id }
        return nil
    }
}

final class ChoreographyDetailModel: ObservableObject {
    let choreography: Choreography
    let player = YouTubePlaybackController()

    @Published var referencePhase: LoadPhase = .idle
    @Published var tutorialPhase: LoadPhase = .idle
    @Published var tutorials: [TutorialVideo] = []
    @Published var nowPlaying: NowPlayingSource = .reference
    @Published var activeBadgeFilters: Set<TutorialBadge> = []
    @Published var unsupportedNotice: PlaybackCapabilities?
    @Published var pasteSheetVisible = false
    @Published var toast: String?

    private var referenceVideoID: String?
    private weak var store: AppStore?
    private var practiceClockStart: Date?

    init(choreography: Choreography) {
        self.choreography = choreography
    }

    func attach(store: AppStore) {
        self.store = store
    }

    var currentTutorial: TutorialVideo? {
        guard let id = nowPlaying.tutorialID else { return nil }
        return tutorials.first { $0.id == id }
    }

    var visibleTutorials: [TutorialVideo] {
        guard let store else { return tutorials }
        let hidden = Set(store.progress(for: choreography.id).hiddenTutorialIDs)
        let pinned = store.progress(for: choreography.id).pinnedTutorialIDs

        let shown = tutorials.filter { video in
            if hidden.contains(video.id) { return false }
            guard !activeBadgeFilters.isEmpty else { return true }
            return activeBadgeFilters.isSubset(of: Set(video.badges))
        }
        // Pinned tutorials float to the top in the order the user pinned them — that is their
        // personal lesson plan, and ranking should not reshuffle it under them.
        let pinnedVideos = pinned.compactMap { id in shown.first { $0.id == id } }
        let rest = shown.filter { !pinned.contains($0.id) }
        return pinnedVideos + rest
    }

    var badgeCounts: [TutorialBadge: Int] {
        var counts: [TutorialBadge: Int] = [:]
        for video in tutorials {
            for badge in video.badges { counts[badge, default: 0] += 1 }
        }
        return counts
    }

    // MARK: - Loading

    @MainActor
    func loadEverything() async {
        await loadReference()
        await loadTutorials()
    }

    @MainActor
    func loadReference(forceRefresh: Bool = false) async {
        guard let store else { return }

        if !forceRefresh, let cached = store.resolvedPracticeVideoID(for: choreography) {
            referenceVideoID = cached
            referencePhase = .loaded
            player.load(videoID: cached)
            return
        }

        guard ContentService.shared.hasAPIKey else {
            referencePhase = .needsAPIKey
            return
        }

        referencePhase = .loading
        do {
            let id = try await ContentService.shared.resolveReferenceVideo(
                for: choreography, region: store.settings.tutorialRegionCode,
                ignoringCatalogID: forceRefresh
            )
            referenceVideoID = id
            store.storeResolvedPracticeVideo(id, for: choreography.id)
            referencePhase = .loaded
            player.load(videoID: id)
        } catch {
            referencePhase = .failed((error as? YouTubeAPIError)?.errorDescription
                                     ?? error.localizedDescription)
        }
    }

    @MainActor
    func loadTutorials(forceRefresh: Bool = false) async {
        guard let store else { return }

        if !forceRefresh, let cached = store.cachedTutorials(for: choreography.id) {
            tutorials = cached
            tutorialPhase = .loaded
            return
        }

        guard ContentService.shared.hasAPIKey else {
            // Even with no key we can show whatever was cached from a previous session rather
            // than an empty screen.
            if let stale = store.staleCachedTutorials(for: choreography.id), !stale.isEmpty {
                tutorials = stale
                tutorialPhase = .loaded
            } else {
                tutorialPhase = .needsAPIKey
            }
            return
        }

        tutorialPhase = .loading
        do {
            let results = try await ContentService.shared.fetchTutorials(
                for: choreography,
                channelBoosts: store.catalog.tutorialChannelBoosts,
                settings: store.settings
            )
            tutorials = results
            store.storeTutorials(results, for: choreography.id)
            tutorialPhase = .loaded
        } catch {
            // A quota error with a stale cache should show the stale cache, not an error wall.
            if let stale = store.staleCachedTutorials(for: choreography.id), !stale.isEmpty {
                tutorials = stale
                tutorialPhase = .loaded
                toast = (error as? YouTubeAPIError)?.errorDescription
            } else {
                tutorialPhase = .failed((error as? YouTubeAPIError)?.errorDescription
                                        ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Playback selection

    func playReference() {
        guard let referenceVideoID else { return }
        nowPlaying = .reference
        player.clearLoop()
        player.load(videoID: referenceVideoID, autoplay: true)
    }

    func play(tutorial: TutorialVideo) {
        guard tutorial.isEmbeddable else {
            toast = "That channel doesn't allow off-YouTube playback. Opening it in YouTube."
            if let url = tutorial.watchURL { UIApplication.shared.open(url) }
            return
        }
        nowPlaying = .tutorial(tutorial.id)
        player.clearLoop()
        player.load(videoID: tutorial.id, autoplay: true)
    }

    @MainActor
    func addPastedVideo(_ urlText: String) async {
        guard let store else { return }
        do {
            let video = try await ContentService.shared.lookupSingleVideo(
                url: urlText, region: store.settings.tutorialRegionCode
            )
            if !tutorials.contains(where: { $0.id == video.id }) {
                tutorials.insert(video, at: 0)
                store.storeTutorials(tutorials, for: choreography.id)
            }
            store.updateProgress(choreography.id) { record in
                if !record.pinnedTutorialIDs.contains(video.id) {
                    record.pinnedTutorialIDs.insert(video.id, at: 0)
                }
            }
            tutorialPhase = .loaded
            play(tutorial: video)
            pasteSheetVisible = false
        } catch {
            toast = (error as? YouTubeAPIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Lets the user override a bad automatic match for the main reference video.
    @MainActor
    func setReference(fromPastedURL urlText: String) {
        guard let id = YouTubeLink.videoID(from: urlText), let store else {
            toast = "That doesn't look like a YouTube link."
            return
        }
        referenceVideoID = id
        store.storeResolvedPracticeVideo(id, for: choreography.id)
        referencePhase = .loaded
        nowPlaying = .reference
        player.load(videoID: id, autoplay: true)
        pasteSheetVisible = false
    }

    // MARK: - Tutorial list actions

    func togglePin(_ video: TutorialVideo) {
        guard let store else { return }
        Haptics.tap()
        store.updateProgress(choreography.id) { record in
            if let index = record.pinnedTutorialIDs.firstIndex(of: video.id) {
                record.pinnedTutorialIDs.remove(at: index)
            } else {
                record.pinnedTutorialIDs.insert(video.id, at: 0)
            }
        }
        objectWillChange.send()
    }

    func hide(_ video: TutorialVideo) {
        guard let store else { return }
        store.updateProgress(choreography.id) { record in
            record.hiddenTutorialIDs.append(video.id)
            record.pinnedTutorialIDs.removeAll { $0 == video.id }
        }
        toast = "Hidden. Undo from the list menu."
        objectWillChange.send()
    }

    func unhideAll() {
        guard let store else { return }
        store.updateProgress(choreography.id) { $0.hiddenTutorialIDs = [] }
        objectWillChange.send()
    }

    func isPinned(_ video: TutorialVideo) -> Bool {
        store?.progress(for: choreography.id).pinnedTutorialIDs.contains(video.id) ?? false
    }

    var hiddenCount: Int {
        store?.progress(for: choreography.id).hiddenTutorialIDs.count ?? 0
    }

    // MARK: - Sections

    func saveCurrentLoopAsSection(named label: String) {
        guard let loop = player.loop, loop.isUsable, let store else { return }
        store.addSection(
            PracticeSection(label: label, start: loop.start, end: loop.end),
            to: choreography.id
        )
        Haptics.success()
        toast = "Saved “\(label)”"
        objectWillChange.send()
    }

    // MARK: - Capability explanation

    /// The user asked for something the embedded player is not permitted to do. Surface the real
    /// reason plus the route that does work, rather than a disabled button with no explanation.
    func explainUnsupported(_ capability: PlaybackCapabilities) {
        unsupportedNotice = capability
    }

    // MARK: - Practice clock

    func beginPracticeClock() {
        practiceClockStart = Date()
    }

    func endPracticeClock() {
        guard let practiceClockStart, let store else { return }
        store.recordPracticeTime(Date().timeIntervalSince(practiceClockStart), for: choreography.id)
        self.practiceClockStart = nil
    }
}
