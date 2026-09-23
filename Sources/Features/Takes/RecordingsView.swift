import SwiftUI
import Photos

struct RecordingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.recordings.isEmpty {
                    ScrollView {
                        EmptyStateView(
                            symbol: "video.badge.plus",
                            title: "No takes yet",
                            message: "Open Studio on a video in your Library, loop the part you're drilling and hit record. The countdown gives you time to get to your mark."
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                            ForEach(store.recordings) { recording in
                                NavigationLink(value: recording) {
                                    TakeCard(recording: recording)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    ShareLink(item: MediaStore.recordingURL(recording.filename)) {
                                        Label("Share raw take", systemImage: "square.and.arrow.up")
                                    }
                                    Button(role: .destructive) {
                                        store.deleteRecording(recording)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(Metric.gutter)
                    }
                }
            }
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle("Takes")
            .navigationDestination(for: Recording.self) { recording in
                TakeDetailView(recording: recording)
            }
        }
    }
}

private struct TakeCard: View {
    let recording: Recording
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                VideoThumbnail(url: MediaStore.recordingURL(recording.filename))
                    .frame(height: 120)
                Text(recording.durationSeconds.shortTimecodeText)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                    .padding(6)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.primaryText)
                    .lineLimit(1)
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(Palette.secondaryText)
                HStack(spacing: 4) {
                    if recording.referenceRate != 1.0 {
                        PillLabel(text: recording.rateText, tint: Palette.amber)
                    }
                    if let rating = recording.selfRating {
                        PillLabel(text: "\(rating)", symbol: "star.fill", tint: Palette.accent)
                    }
                }
            }
            .padding(10)
        }
        .cardSurface()
        .clipShape(RoundedRectangle(cornerRadius: Metric.cardCorner, style: .continuous))
    }
}

// MARK: - Detail

struct TakeDetailView: View {
    let recording: Recording

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = LocalPlaybackController()

    @State private var note = ""
    @State private var layMusic = true
    @State private var keepMic = true
    @State private var realTempo = true
    @State private var exportProgress: Double?
    @State private var exportedURL: URL?
    @State private var message: String?
    @State private var confirmDelete = false

    private var current: Recording {
        store.recordings.first { $0.id == recording.id } ?? recording
    }

    private var sourceItem: LibraryItem? { store.libraryItem(id: current.libraryItemID) }

    /// The music to lay under the take: the linked audio file if there is one, otherwise the
    /// reference video's own soundtrack. Both are library items, so both are media the user owns.
    private var musicItem: LibraryItem? {
        guard let sourceItem else { return nil }
        return store.libraryItem(id: sourceItem.linkedAudioItemID) ?? sourceItem
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    Color.black
                    LocalPlayerSurface(player: player.player)
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxHeight: 460)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Metric.cardCorner))

                TransportBar(controller: player,
                             availableSpeeds: PlaybackSpeed.allCases.map(\.rawValue),
                             compact: true)

                facts
                ratingRow
                noteField
                exportSection
            }
            .padding(Metric.gutter)
        }
        .background(Palette.ink.ignoresSafeArea())
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ShareLink(item: MediaStore.recordingURL(current.filename)) {
                        Label("Share raw take", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete take", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this take?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.teardown()
                store.deleteRecording(current)
                dismiss()
            }
        }
        .onAppear {
            note = current.note ?? ""
            player.load(url: MediaStore.recordingURL(current.filename))
        }
        .onDisappear {
            player.teardown()
            saveNote()
        }
    }

    private var facts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                PillLabel(text: current.rateText, symbol: "gauge.with.dots.needle.33percent",
                          tint: current.referenceRate == 1.0 ? Palette.secondaryText : Palette.amber)
                if let section = current.sectionLabel {
                    PillLabel(text: section, symbol: "repeat", tint: Palette.mint)
                }
                if current.wasMirrored {
                    PillLabel(text: "Mirrored", symbol: "arrow.left.and.right", tint: Palette.violet)
                }
                if !current.micEnabled {
                    PillLabel(text: "No mic", symbol: "mic.slash", tint: Palette.tertiaryText)
                }
                if let id = current.choreographyID, let choreo = store.catalog.choreography(id: id) {
                    PillLabel(text: choreo.title, symbol: "music.note", tint: Palette.accent)
                }
            }
        }
    }

    private var ratingRow: some View {
        HStack(spacing: 6) {
            Text("How did it feel?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.secondaryText)
            Spacer()
            ForEach(1...5, id: \.self) { value in
                Button {
                    Haptics.tap()
                    var updated = current
                    updated.selfRating = (current.selfRating == value) ? nil : value
                    store.updateRecording(updated)
                } label: {
                    Image(systemName: (current.selfRating ?? 0) >= value ? "star.fill" : "star")
                        .font(.system(size: 20))
                        .foregroundColor(Palette.accent)
                }
                .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
            }
        }
    }

    private var noteField: some View {
        TextField("Notes — what to fix next run", text: $note, axis: .vertical)
            .lineLimit(2...5)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .foregroundColor(Palette.primaryText)
            .onSubmit(saveNote)
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (current.note ?? "") else { return }
        var updated = current
        updated.note = trimmed.isEmpty ? nil : trimmed
        store.updateRecording(updated)
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Export", subtitle: "Make a clean version to keep or share")

            VStack(spacing: 0) {
                if let musicItem {
                    Toggle(isOn: $layMusic) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lay the music under it")
                            Text("From “\(musicItem.title)” in your library")
                                .font(.system(size: 11))
                                .foregroundColor(Palette.tertiaryText)
                        }
                    }
                    .padding(.vertical, 8)
                    if layMusic && current.micEnabled && current.referenceRate == 1.0 {
                        Toggle("Keep my mic quietly underneath", isOn: $keepMic)
                            .padding(.vertical, 8)
                    }
                } else {
                    Text("This take isn't linked to a library file, so there's no owned music to lay under it. The export keeps its own mic audio.")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.tertiaryText)
                        .padding(.vertical, 8)
                }
                if current.referenceRate != 1.0 && layMusic && musicItem != nil {
                    Text("You danced at \(current.rateText). The export is sped up to real tempo so it lines up with the music.")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.tertiaryText)
                        .padding(.vertical, 8)
                } else if current.referenceRate != 1.0 {
                    Toggle(isOn: $realTempo) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speed up to real tempo")
                            Text("You danced at \(current.rateText); export at full speed")
                                .font(.system(size: 11))
                                .foregroundColor(Palette.tertiaryText)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .font(.system(size: 14))
            .foregroundColor(Palette.primaryText)
            .tint(Palette.mint)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .cardSurface()

            if let exportProgress {
                ProgressView(value: exportProgress)
                    .tint(Palette.accent)
            } else {
                Button {
                    Task { await export() }
                } label: {
                    Label("Export take", systemImage: "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.violet))
                        .foregroundColor(.white)
                }
            }

            if let exportedURL {
                HStack(spacing: 10) {
                    ShareLink(item: exportedURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        saveToPhotos(exportedURL)
                    } label: {
                        Label("Save to Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.system(size: 13, weight: .semibold))
            }

            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondaryText)
            }
        }
    }

    @MainActor
    private func export() async {
        message = nil
        exportedURL = nil
        exportProgress = 0

        let useMusic = layMusic && musicItem != nil
        var options = RecordingComposer.MixOptions()
        if useMusic, let musicItem {
            options.musicURL = MediaStore.mediaURL(musicItem.filename)
            options.musicStartTime = current.loopStart ?? 0
            options.keepMicAudio = keepMic && current.micEnabled
        } else {
            options.keepMicAudio = current.micEnabled
        }
        // Music is laid in at its natural tempo, so a slowed take must be sped back up or the two
        // drift apart. The mic is retimed with the video and would chipmunk, so it is dropped.
        if current.referenceRate != 1.0 && (realTempo || useMusic) {
            options.normalizeFromRate = current.referenceRate
            options.keepMicAudio = false
        }

        let safeTitle = current.title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let destination = MediaStore.scratchDirectory
            .appendingPathComponent("\(safeTitle.isEmpty ? "take" : safeTitle)-export.mp4")

        do {
            let url = try await RecordingComposer.export(
                take: MediaStore.recordingURL(current.filename),
                options: options,
                to: destination,
                progress: { exportProgress = $0 }
            )
            exportedURL = url
            if useMusic, !current.musicMuxed {
                var updated = current
                updated.musicMuxed = true
                store.updateRecording(updated)
            }
            Haptics.success()
        } catch {
            message = error.localizedDescription
        }
        exportProgress = nil
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "Photo library access is off. Enable it in Settings to save takes." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        Haptics.success()
                        message = "Saved to Photos."
                    } else {
                        message = error?.localizedDescription ?? "Couldn't save to Photos."
                    }
                }
            }
        }
    }
}
