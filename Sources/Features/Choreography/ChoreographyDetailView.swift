import SwiftUI
import UIKit

struct ChoreographyDetailView: View {
    let choreography: Choreography

    @EnvironmentObject private var store: AppStore
    @StateObject private var model: ChoreographyDetailModel
    @State private var showSectionNamer = false
    @State private var newSectionName = ""
    @State private var showStudio = false

    init(choreography: Choreography) {
        self.choreography = choreography
        _model = StateObject(wrappedValue: ChoreographyDetailModel(choreography: choreography))
    }

    var body: some View {
        VStack(spacing: 0) {
            playerStage
            Divider().overlay(Palette.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    headerBlock
                    TransportBar(
                        controller: model.player,
                        availableSpeeds: model.player.availableRates,
                        onUnsupported: model.explainUnsupported
                    )
                    practiceToolsRow
                    sectionsBlock
                    tutorialsBlock
                }
                .padding(.horizontal, Metric.gutter)
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
        }
        .background(Palette.ink.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            model.attach(store: store)
            model.beginPracticeClock()
            await model.loadEverything()
        }
        .onDisappear {
            model.endPracticeClock()
            model.player.teardown()
        }
        .sheet(isPresented: $model.pasteSheetVisible) {
            PasteLinkSheet(model: model)
        }
        .sheet(item: Binding(
            get: { model.unsupportedNotice.map { CapabilityNotice(capability: $0) } },
            set: { if $0 == nil { model.unsupportedNotice = nil } }
        )) { notice in
            UnsupportedCapabilitySheet(capability: notice.capability, choreography: choreography)
        }
        .fullScreenCover(isPresented: $showStudio) {
            StudioView(choreography: choreography)
        }
        .alert("Name this section", isPresented: $showSectionNamer) {
            TextField("Chorus, killing part, bridge…", text: $newSectionName)
            Button("Save") {
                let label = newSectionName.trimmingCharacters(in: .whitespaces)
                model.saveCurrentLoopAsSection(named: label.isEmpty ? "Section" : label)
                newSectionName = ""
            }
            Button("Cancel", role: .cancel) { newSectionName = "" }
        } message: {
            if let loop = model.player.loop {
                Text("\(loop.start.shortTimecodeText) to \(loop.end.shortTimecodeText)")
            }
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: - Player stage

    /// The reference video owns the top of the screen and never scrolls away. Nothing is ever
    /// drawn on top of the player's frame — badges and chips live below the 16:9 box, which is
    /// both a YouTube embed requirement and, conveniently, the layout a learner wants.
    private var playerStage: some View {
        ZStack {
            Color.black
            switch model.referencePhase {
            case .loaded:
                YouTubePlayerSurface(controller: model.player)
            case .loading, .idle:
                ProgressView().tint(.white)
            case .needsAPIKey:
                missingKeyStage
            case .failed(let message):
                failureStage(message)
            }

            if let problem = model.player.problem {
                playerProblemStage(problem)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var missingKeyStage: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 26))
                .foregroundColor(Palette.tertiaryText)
            Text("No YouTube API key yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("Add one in Settings to find references automatically, or paste the link yourself.")
                .font(.system(size: 11))
                .foregroundColor(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            HStack(spacing: 10) {
                Button("Paste a link") { model.pasteSheetVisible = true }
                    .buttonStyle(.borderedProminent)
                Button("Search YouTube") {
                    if let url = YouTubeLink.searchURL(for: choreography.practiceSearch.query) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 12, weight: .semibold))
            .controlSize(.small)
        }
    }

    private func failureStage(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundColor(Palette.amber)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("Try again") {
                    Task { await model.loadReference(forceRefresh: true) }
                }
                Button("Paste a link") { model.pasteSheetVisible = true }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func playerProblemStage(_ problem: PlaybackProblem) -> some View {
        VStack(spacing: 8) {
            Text(problem.message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            if let hint = problem.recoveryHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                if let url = model.player.watchURL {
                    Button("Open in YouTube") { UIApplication.shared.open(url) }
                }
                Button("Re-resolve") {
                    Task { await model.loadReference(forceRefresh: true) }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(choreography.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(Palette.primaryText)
                    Text(choreography.displaySubtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondaryText)
                }
                Spacer()
                Button {
                    Haptics.tap()
                    store.toggleFavorite(choreography.id)
                } label: {
                    Image(systemName: store.progress(for: choreography.id).isFavorite
                          ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 18))
                        .foregroundColor(Palette.accent)
                }
                .accessibilityLabel("Save routine")
            }

            HStack(spacing: 6) {
                let difficulty = store.effectiveDifficulty(for: choreography)
                PillLabel(text: difficulty.label,
                          symbol: "flame",
                          tint: Palette.difficultyColor(difficulty))
                PillLabel(text: nowPlayingLabel,
                          symbol: model.nowPlaying == .reference ? "figure.dance" : "graduationcap",
                          tint: Palette.violet)
                if model.nowPlaying != .reference {
                    Button {
                        Haptics.tap()
                        model.playReference()
                    } label: {
                        PillLabel(text: "Back to practice", symbol: "arrow.uturn.left",
                                  tint: Palette.mint, filled: true)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(store.effectiveDifficulty(for: choreography).blurb)
                .font(.system(size: 12))
                .foregroundColor(Palette.tertiaryText)
        }
    }

    private var nowPlayingLabel: String {
        switch model.nowPlaying {
        case .reference: return choreography.referenceKind.label
        case .tutorial: return model.currentTutorial?.channelTitle ?? "Tutorial"
        }
    }

    // MARK: - Practice tools

    /// The row where the rights model becomes visible. Mirror and Record are not hidden on the
    /// YouTube source — they are present and they explain themselves, then point at the path that
    /// does work. Hiding them would just make users think the app lacks the feature.
    private var practiceToolsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                toolButton(
                    title: "Mirror",
                    symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    enabled: model.player.capabilities.contains(.mirror),
                    tint: Palette.violet
                ) {
                    model.explainUnsupported(.mirror)
                }

                toolButton(
                    title: "Record a take",
                    symbol: "record.circle",
                    enabled: model.player.capabilities.contains(.cameraOverlay),
                    tint: Palette.record
                ) {
                    if store.libraryItems(for: choreography.id).isEmpty {
                        model.explainUnsupported(.cameraOverlay)
                    } else {
                        showStudio = true
                    }
                }

                toolButton(
                    title: "Mark section",
                    symbol: "scissors",
                    enabled: model.player.loop?.isUsable ?? false,
                    tint: Palette.mint
                ) {
                    showSectionNamer = true
                }
            }

            if !store.libraryItems(for: choreography.id).isEmpty {
                Button {
                    showStudio = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.dance")
                        Text("Open Studio — mirror, ghost overlay and recording are all available for your \(store.libraryItems(for: choreography.id).count) linked file\(store.libraryItems(for: choreography.id).count == 1 ? "" : "s")")
                            .multilineTextAlignment(.leading)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.mint)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.mint.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toolButton(title: String, symbol: String, enabled: Bool,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                    if !enabled {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.amber)
                            .offset(x: 10, y: -5)
                    }
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(enabled ? tint : Palette.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(enabled ? tint.opacity(0.14) : Palette.surface)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sectionsBlock: some View {
        let sections = store.progress(for: choreography.id).sections
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your sections",
                              subtitle: "Tap to loop the part you're drilling")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sections) { section in
                            Button {
                                Haptics.thud()
                                model.player.applySection(section)
                                model.player.play()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(section.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Palette.primaryText)
                                    Text("\(section.start.shortTimecodeText) · \(Int(section.duration))s")
                                        .font(.system(size: 10))
                                        .foregroundColor(Palette.secondaryText)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeSection(section.id, from: choreography.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tutorials

    private var tutorialsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Tutorials",
                subtitle: tutorialSubtitle,
                actionTitle: model.tutorialPhase == .loaded ? "Refresh" : nil,
                action: { Task { await model.loadTutorials(forceRefresh: true) } }
            )

            switch model.tutorialPhase {
            case .loading, .idle:
                HStack(spacing: 10) {
                    ProgressView().tint(Palette.secondaryText)
                    Text("Ranking tutorials…")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondaryText)
                }
                .padding(.vertical, 20)

            case .needsAPIKey:
                EmptyStateView(
                    symbol: "key.horizontal",
                    title: "Tutorial ranking needs a key",
                    message: "Add a free YouTube Data API key in Settings and this list fills itself with mirrored, slowed, step-by-step lessons ranked for learnability. Or paste a tutorial link you already trust.",
                    actionTitle: "Paste a tutorial link",
                    action: { model.pasteSheetVisible = true }
                )
                .frame(maxWidth: .infinity)

            case .failed(let message):
                EmptyStateView(
                    symbol: "wifi.exclamationmark",
                    title: "Couldn't load tutorials",
                    message: message,
                    actionTitle: "Try again",
                    action: { Task { await model.loadTutorials(forceRefresh: true) } }
                )
                .frame(maxWidth: .infinity)

            case .loaded:
                badgeFilterRow
                ForEach(model.visibleTutorials) { video in
                    TutorialRow(
                        video: video,
                        isPlaying: model.nowPlaying.tutorialID == video.id,
                        isPinned: model.isPinned(video),
                        onPlay: { model.play(tutorial: video) },
                        onPin: { model.togglePin(video) },
                        onHide: { model.hide(video) }
                    )
                }
                if model.hiddenCount > 0 {
                    Button("Show \(model.hiddenCount) hidden") { model.unhideAll() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.secondaryText)
                }
                Button {
                    model.pasteSheetVisible = true
                } label: {
                    Label("Add a tutorial by link", systemImage: "link.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.violet)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tutorialSubtitle: String {
        guard case .loaded = model.tutorialPhase else {
            return "Ranked for learnability, not clicks"
        }
        let mirrored = model.badgeCounts[.mirrored] ?? 0
        return "\(model.visibleTutorials.count) found · \(mirrored) mirrored"
    }

    private var badgeFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TutorialBadge.allCases) { badge in
                    let count = model.badgeCounts[badge] ?? 0
                    if count > 0 {
                        Button {
                            Haptics.tap()
                            if model.activeBadgeFilters.contains(badge) {
                                model.activeBadgeFilters.remove(badge)
                            } else {
                                model.activeBadgeFilters.insert(badge)
                            }
                        } label: {
                            PillLabel(
                                text: "\(badge.label) \(count)",
                                symbol: badge.symbol,
                                tint: badge == .mirrored ? Palette.mint : Palette.violet,
                                filled: model.activeBadgeFilters.contains(badge)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    Task { await model.loadReference(forceRefresh: true) }
                } label: {
                    Label("Re-resolve reference video", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    model.pasteSheetVisible = true
                } label: {
                    Label("Set reference from link", systemImage: "link")
                }
                if let url = model.player.watchURL {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open in YouTube", systemImage: "arrow.up.forward.square")
                    }
                }
                Divider()
                Menu("Difficulty") {
                    ForEach(Difficulty.allCases) { level in
                        Button(level.label) {
                            store.updateProgress(choreography.id) { $0.difficultyOverride = level }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Palette.surfaceRaised))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation { model.toast = nil }
                    }
                }
        }
    }
}

/// `sheet(item:)` needs an Identifiable, and `PlaybackCapabilities` is an OptionSet.
struct CapabilityNotice: Identifiable {
    let capability: PlaybackCapabilities
    var id: Int { capability.rawValue }
}
