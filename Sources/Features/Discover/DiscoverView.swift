import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var selectedTag: String?
    @State private var maxDifficulty: Difficulty?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: []) {
                    if !store.recentlyPracticed.isEmpty && query.isEmpty && selectedTag == nil {
                        continueSection
                    }
                    if !store.favorites.isEmpty && query.isEmpty && selectedTag == nil {
                        favoritesSection
                    }
                    browseSection
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.vertical, 16)
            }
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle("Practice Room")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Song, artist or vibe")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    difficultyMenu
                }
            }
            .navigationDestination(for: Choreography.self) { choreography in
                ChoreographyDetailView(choreography: choreography)
            }
        }
    }

    // MARK: - Sections

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Pick up where you left off",
                          subtitle: "Your last few routines")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(store.recentlyPracticed.prefix(8))) { choreography in
                        NavigationLink(value: choreography) {
                            ContinueCard(
                                choreography: choreography,
                                progress: store.progress(for: choreography.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Saved", subtitle: "\(store.favorites.count) routines")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.favorites) { choreography in
                        NavigationLink(value: choreography) {
                            ChoreographyCard(
                                choreography: choreography,
                                difficulty: store.effectiveDifficulty(for: choreography),
                                isFavorite: true
                            )
                            .frame(width: 168)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: query.isEmpty ? "All routines" : "Results",
                subtitle: "\(filtered.count) of \(store.catalog.choreographies.count)"
            )
            tagRow
            if filtered.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "Nothing matches",
                    message: "Try a different song, or clear the filters. You can also practice any video you own from the Library tab.",
                    actionTitle: "Clear filters",
                    action: clearFilters
                )
                .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(filtered) { choreography in
                        NavigationLink(value: choreography) {
                            ChoreographyCard(
                                choreography: choreography,
                                difficulty: store.effectiveDifficulty(for: choreography),
                                isFavorite: store.progress(for: choreography.id).isFavorite
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.catalog.allTags, id: \.self) { tag in
                    Button {
                        Haptics.tap()
                        selectedTag = (selectedTag == tag) ? nil : tag
                    } label: {
                        PillLabel(text: tag, tint: Palette.violet, filled: selectedTag == tag)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var difficultyMenu: some View {
        Menu {
            Button("Any difficulty") { maxDifficulty = nil }
            ForEach(Difficulty.allCases) { level in
                Button("\(level.label) or easier") { maxDifficulty = level }
            }
        } label: {
            Image(systemName: maxDifficulty == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    // MARK: - Filtering

    private var filtered: [Choreography] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.catalog.choreographies.filter { choreography in
            if let selectedTag, !choreography.tags.contains(selectedTag) { return false }
            if let maxDifficulty,
               store.effectiveDifficulty(for: choreography).rawValue > maxDifficulty.rawValue {
                return false
            }
            guard !needle.isEmpty else { return true }
            return choreography.searchHaystack.contains(needle)
        }
    }

    private func clearFilters() {
        query = ""
        selectedTag = nil
        maxDifficulty = nil
    }
}

// MARK: - Cards

struct ChoreographyCard: View {
    let choreography: Choreography
    let difficulty: Difficulty
    var isFavorite: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ArtworkTile(choreography: choreography)
                if isFavorite {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.accent)
                        .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(choreography.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Palette.primaryText)
                    .lineLimit(1)
                Text(choreography.displaySubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    PillLabel(text: difficulty.label, tint: Palette.difficultyColor(difficulty))
                    PillLabel(text: choreography.referenceKind.label, tint: Palette.tertiaryText)
                }
            }
            .padding(10)
        }
        .cardSurface()
    }
}

/// No artwork ships with the app (album covers are not ours to bundle), so the tile is generated
/// from the title itself — deterministic per routine, so a card stays recognisable between visits.
struct ArtworkTile: View {
    let choreography: Choreography

    private var hue: Double {
        let hash = abs(choreography.id.hashValue)
        return Double(hash % 360) / 360.0
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.55),
                    Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1.0),
                          saturation: 0.7, brightness: 0.28)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
        }
        .frame(height: 96)
        .clipped()
    }

    private var initials: String {
        let words = choreography.title.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}

struct ContinueCard: View {
    let choreography: Choreography
    let progress: ChoreographyProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(choreography.title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Palette.primaryText)
                .lineLimit(1)
            Text(choreography.artist)
                .font(.system(size: 11))
                .foregroundColor(Palette.secondaryText)

            HStack(spacing: 10) {
                Label(practiceTimeText, systemImage: "clock")
                Label("\(progress.takeCount)", systemImage: "video")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Palette.mint)

            if !progress.sections.isEmpty {
                Text("\(progress.sections.count) marked section\(progress.sections.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.tertiaryText)
            }
        }
        .padding(12)
        .frame(width: 180, alignment: .leading)
        .cardSurface(raised: true)
    }

    private var practiceTimeText: String {
        let minutes = Int(progress.totalPracticeSeconds / 60)
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
