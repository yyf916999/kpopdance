import Foundation
import Combine

/// Single source of truth for user data. Small enough to keep in one object; everything it owns
/// is a value type, so views can diff cheaply and nothing mutates behind SwiftUI's back.
///
/// Deliberately not actor-isolated: it is only ever touched from SwiftUI view bodies and from
/// main-queue callbacks, and keeping it unannotated avoids isolation churn across the capture
/// and web-bridge callbacks that also feed it.
final class AppStore: ObservableObject {
    @Published private(set) var catalog: Catalog
    @Published private(set) var progress: [String: ChoreographyProgress]
    @Published private(set) var library: [LibraryItem]
    @Published private(set) var recordings: [Recording]
    @Published var settings: PracticeSettings {
        didSet { FileStore.save(settings, to: Keys.settings) }
    }

    private var tutorialCache: [String: TutorialCacheEntry]

    private enum Keys {
        static let progress = "progress"
        static let library = "library"
        static let recordings = "recordings"
        static let settings = "settings"
        static let tutorialCache = "tutorial-cache"
    }

    init(catalog: Catalog = .loadBundled()) {
        self.catalog = catalog
        self.progress = FileStore.load([String: ChoreographyProgress].self, from: Keys.progress) ?? [:]
        self.library = FileStore.load([LibraryItem].self, from: Keys.library) ?? []
        self.recordings = FileStore.load([Recording].self, from: Keys.recordings) ?? []
        self.settings = FileStore.load(PracticeSettings.self, from: Keys.settings) ?? .default
        self.tutorialCache = FileStore.load([String: TutorialCacheEntry].self, from: Keys.tutorialCache) ?? [:]
        pruneMissingFiles()
    }

    // MARK: - Progress

    func progress(for id: String) -> ChoreographyProgress {
        progress[id] ?? ChoreographyProgress(choreographyID: id)
    }

    func updateProgress(_ id: String, _ mutate: (inout ChoreographyProgress) -> Void) {
        var record = progress(for: id)
        mutate(&record)
        progress[id] = record
        FileStore.save(progress, to: Keys.progress)
    }

    func toggleFavorite(_ id: String) {
        updateProgress(id) { $0.isFavorite.toggle() }
    }

    func effectiveDifficulty(for choreography: Choreography) -> Difficulty {
        progress(for: choreography.id).difficultyOverride ?? choreography.difficulty
    }

    func recordPracticeTime(_ seconds: Double, for id: String) {
        guard seconds > 1 else { return }
        updateProgress(id) {
            $0.totalPracticeSeconds += seconds
            $0.lastPracticedAt = Date()
        }
    }

    var favorites: [Choreography] {
        catalog.choreographies.filter { progress(for: $0.id).isFavorite }
    }

    var recentlyPracticed: [Choreography] {
        catalog.choreographies
            .compactMap { choreo -> (Choreography, Date)? in
                guard let at = progress(for: choreo.id).lastPracticedAt else { return nil }
                return (choreo, at)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - Sections

    func addSection(_ section: PracticeSection, to id: String) {
        updateProgress(id) { $0.sections.append(section) }
    }

    func removeSection(_ sectionID: UUID, from id: String) {
        updateProgress(id) { $0.sections.removeAll { $0.id == sectionID } }
    }

    func renameSection(_ sectionID: UUID, to label: String, in id: String) {
        updateProgress(id) { record in
            guard let idx = record.sections.firstIndex(where: { $0.id == sectionID }) else { return }
            record.sections[idx].label = label
        }
    }

    // MARK: - Library

    func addLibraryItem(_ item: LibraryItem) {
        library.append(item)
        library.sort { $0.importedAt > $1.importedAt }
        FileStore.save(library, to: Keys.library)
    }

    func updateLibraryItem(_ item: LibraryItem) {
        guard let idx = library.firstIndex(where: { $0.id == item.id }) else { return }
        library[idx] = item
        FileStore.save(library, to: Keys.library)
    }

    func deleteLibraryItem(_ item: LibraryItem) {
        MediaStore.delete(MediaStore.mediaURL(item.filename))
        library.removeAll { $0.id == item.id }
        FileStore.save(library, to: Keys.library)
    }

    func libraryItem(id: UUID?) -> LibraryItem? {
        guard let id else { return nil }
        return library.first { $0.id == id }
    }

    func libraryItems(for choreographyID: String) -> [LibraryItem] {
        library.filter { $0.choreographyID == choreographyID }
    }

    // MARK: - Recordings

    func addRecording(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        FileStore.save(recordings, to: Keys.recordings)
        if let choreoID = recording.choreographyID {
            updateProgress(choreoID) {
                $0.takeCount += 1
                $0.lastPracticedAt = Date()
            }
        }
    }

    func updateRecording(_ recording: Recording) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx] = recording
        FileStore.save(recordings, to: Keys.recordings)
    }

    func deleteRecording(_ recording: Recording) {
        MediaStore.delete(MediaStore.recordingURL(recording.filename))
        recordings.removeAll { $0.id == recording.id }
        FileStore.save(recordings, to: Keys.recordings)
    }

    func recordings(for choreographyID: String) -> [Recording] {
        recordings.filter { $0.choreographyID == choreographyID }
    }

    // MARK: - Tutorial cache

    func cachedTutorials(for id: String) -> [TutorialVideo]? {
        guard let entry = tutorialCache[id], entry.isFresh() else { return nil }
        return entry.videos
    }

    func staleCachedTutorials(for id: String) -> [TutorialVideo]? {
        tutorialCache[id]?.videos
    }

    func storeTutorials(_ videos: [TutorialVideo], for id: String) {
        tutorialCache[id] = TutorialCacheEntry(choreographyID: id, videos: videos, fetchedAt: Date())
        FileStore.save(tutorialCache, to: Keys.tutorialCache)
    }

    func clearTutorialCache() {
        tutorialCache = [:]
        FileStore.save(tutorialCache, to: Keys.tutorialCache)
    }

    // MARK: - Resolved reference videos

    func resolvedPracticeVideoID(for choreography: Choreography) -> String? {
        choreography.knownPracticeVideoID ?? progress(for: choreography.id).resolvedPracticeVideoID
    }

    func storeResolvedPracticeVideo(_ videoID: String, for id: String) {
        updateProgress(id) {
            $0.resolvedPracticeVideoID = videoID
            $0.resolvedAt = Date()
        }
    }

    // MARK: - Housekeeping

    /// Recordings and imports can vanish if the user offloads the app or restores a backup that
    /// carried the index but not the media. Drop index rows whose file is gone so the UI never
    /// shows a tile that cannot play.
    private func pruneMissingFiles() {
        let fm = FileManager.default
        let survivingLibrary = library.filter { fm.fileExists(atPath: MediaStore.mediaURL($0.filename).path) }
        let survivingRecordings = recordings.filter { fm.fileExists(atPath: MediaStore.recordingURL($0.filename).path) }
        if survivingLibrary.count != library.count {
            library = survivingLibrary
            FileStore.save(library, to: Keys.library)
        }
        if survivingRecordings.count != recordings.count {
            recordings = survivingRecordings
            FileStore.save(recordings, to: Keys.recordings)
        }
    }
}
