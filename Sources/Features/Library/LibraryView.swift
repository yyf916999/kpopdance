import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showPhotosPicker = false
    @State private var photosSelection: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var pendingImport: PendingImport?
    @State private var editingItem: LibraryItem?
    @State private var studioItem: LibraryItem?
    @State private var isCopying = false
    @State private var importError: String?

    private var videos: [LibraryItem] { store.library.filter { $0.kind == .video } }
    private var audio: [LibraryItem] { store.library.filter { $0.kind == .audio } }

    var body: some View {
        NavigationStack {
            Group {
                if store.library.isEmpty {
                    ScrollView {
                        EmptyStateView(
                            symbol: "film.stack",
                            title: "Your library is empty",
                            message: "Import videos you own — class recordings, paid choreography packs, files from your teacher — to unlock mirror, frame stepping, recording and export.",
                            actionTitle: "Import from Photos",
                            action: { showPhotosPicker = true }
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                } else {
                    list
                }
            }
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showPhotosPicker = true } label: {
                            Label("From Photos", systemImage: "photo.on.rectangle")
                        }
                        Button { showFileImporter = true } label: {
                            Label("From Files (video or audio)", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photosSelection, matching: .videos)
            .onChange(of: photosSelection) { newValue in
                guard let newValue else { return }
                photosSelection = nil
                Task { await importFromPhotos(newValue) }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie, .audio],
                          allowsMultipleSelection: false) { result in
                Task { await importFromFiles(result) }
            }
            .sheet(item: $pendingImport) { pending in
                LibraryItemEditor(mode: .importing(pending))
            }
            .sheet(item: $editingItem) { item in
                LibraryItemEditor(mode: .editing(item))
            }
            .fullScreenCover(item: $studioItem) { item in
                StudioView(choreography: item.choreographyID.flatMap { store.catalog.choreography(id: $0) },
                           item: item)
            }
            .overlay {
                if isCopying {
                    ProgressView("Copying…")
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surfaceRaised))
                }
            }
            .alert("Import failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var list: some View {
        List {
            if !videos.isEmpty {
                Section {
                    ForEach(videos) { item in
                        Button { studioItem = item } label: { LibraryRow(item: item) }
                            .contextMenu { rowMenu(item) }
                            .swipeActions { swipe(item) }
                    }
                } header: {
                    Text("Videos · tap to open Studio")
                }
            }
            if !audio.isEmpty {
                Section {
                    ForEach(audio) { item in
                        Button { editingItem = item } label: { LibraryRow(item: item) }
                            .contextMenu { rowMenu(item) }
                            .swipeActions { swipe(item) }
                    }
                } header: {
                    Text("Audio · used as music for takes")
                }
            }
            Section {
                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: MediaStore.totalBytesUsed(), countStyle: .file))
                        .foregroundColor(Palette.secondaryText)
                }
                .font(.system(size: 13))
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func rowMenu(_ item: LibraryItem) -> some View {
        if item.kind == .video {
            Button { studioItem = item } label: { Label("Open Studio", systemImage: "figure.dance") }
        }
        Button { editingItem = item } label: { Label("Edit details", systemImage: "pencil") }
        Button(role: .destructive) { store.deleteLibraryItem(item) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func swipe(_ item: LibraryItem) -> some View {
        Button(role: .destructive) { store.deleteLibraryItem(item) } label: {
            Label("Delete", systemImage: "trash")
        }
        Button { editingItem = item } label: { Label("Edit", systemImage: "pencil") }
            .tint(Palette.violet)
    }

    // MARK: - Import

    @MainActor
    private func importFromPhotos(_ selection: PhotosPickerItem) async {
        isCopying = true
        defer { isCopying = false }
        do {
            guard let movie = try await selection.loadTransferable(type: PickedMovie.self) else {
                importError = "Photos didn't hand over a video file."
                return
            }
            pendingImport = PendingImport(scratchURL: movie.url, kind: .video)
        } catch {
            importError = error.localizedDescription
        }
    }

    @MainActor
    private func importFromFiles(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let source = urls.first else { return }
            isCopying = true
            defer { isCopying = false }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let dest = MediaStore.scratchDirectory.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.copyItem(at: source, to: dest)
                let probe = await MediaProbe.probe(dest)
                pendingImport = PendingImport(
                    scratchURL: dest,
                    kind: probe.hasVideo ? .video : .audio,
                    suggestedTitle: source.deletingPathExtension().lastPathComponent
                )
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

struct LibraryRow: View {
    let item: LibraryItem
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            if item.kind == .video {
                VideoThumbnail(url: MediaStore.mediaURL(item.filename))
                    .frame(width: 72, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.surfaceRaised)
                    .frame(width: 72, height: 48)
                    .overlay(Image(systemName: "waveform").foregroundColor(Palette.violet))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.durationSeconds.shortTimecodeText)
                    if let id = item.choreographyID, let choreo = store.catalog.choreography(id: id) {
                        Text("·")
                        Text(choreo.title).foregroundColor(Palette.mint)
                    }
                    if item.linkedAudioItemID != nil {
                        Image(systemName: "music.note")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(Palette.secondaryText)
                .lineLimit(1)
                Text(item.provenance.label)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Poster frame for any local video, loaded lazily.
struct VideoThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Palette.surfaceRaised)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundColor(Palette.tertiaryText)
            }
        }
        .clipped()
        .task(id: url) {
            image = await RecordingComposer.thumbnail(for: url)
        }
    }
}

// MARK: - Import plumbing

struct PendingImport: Identifiable {
    let id = UUID()
    let scratchURL: URL
    let kind: MediaKind
    var suggestedTitle: String = ""
}

/// Photos hands videos over as a file; copy it out of the transient location before it vanishes.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = MediaStore.scratchDirectory.appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

enum MediaProbe {
    struct Result {
        var duration: Double
        var size: CGSize?
        var hasVideo: Bool
    }

    static func probe(_ url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var size: CGSize?
        if let track = tracks.first {
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let applied = natural.applying(transform)
            size = CGSize(width: abs(applied.width), height: abs(applied.height))
        }
        return Result(duration: duration.isFinite ? duration : 0, size: size, hasVideo: !tracks.isEmpty)
    }
}

// MARK: - Editor

/// Used both to finish an import and to edit an existing item. Provenance is required on import:
/// it is the one question that decides whether the file belongs in the app at all.
struct LibraryItemEditor: View {
    enum Mode {
        case importing(PendingImport)
        case editing(LibraryItem)
    }

    let mode: Mode
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var provenance: MediaProvenance?
    @State private var choreographyID: String?
    @State private var linkedAudioID: UUID?
    @State private var saving = false
    @State private var didLoad = false

    private var kind: MediaKind {
        switch mode {
        case .importing(let pending): return pending.kind
        case .editing(let item): return item.kind
        }
    }

    private var isImport: Bool {
        if case .importing = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Class run-through, week 3", text: $title)
                }

                Section {
                    ForEach(MediaProvenance.allCases) { option in
                        Button {
                            provenance = option
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundColor(Palette.primaryText)
                                    Text(option.detail)
                                        .font(.system(size: 11))
                                        .foregroundColor(Palette.tertiaryText)
                                }
                                Spacer()
                                if provenance == option {
                                    Image(systemName: "checkmark").foregroundColor(Palette.mint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Where is this from?")
                } footer: {
                    Text("Only import media you have the right to use. Downloads of other people's YouTube videos don't qualify.")
                }

                Section {
                    Picker("Routine", selection: $choreographyID) {
                        Text("None").tag(String?.none)
                        ForEach(store.catalog.choreographies) { choreo in
                            Text("\(choreo.title) — \(choreo.artist)").tag(Optional(choreo.id))
                        }
                    }
                } header: {
                    Text("Link to a routine")
                } footer: {
                    Text("Linked videos unlock Studio from that routine's page, and your practice time counts toward it.")
                }

                if kind == .video {
                    let audioItems = store.library.filter { $0.kind == .audio }
                    Section {
                        Picker("Music track", selection: $linkedAudioID) {
                            Text("Use this video's own audio").tag(UUID?.none)
                            ForEach(audioItems) { audio in
                                Text(audio.title).tag(Optional(audio.id))
                            }
                        }
                        .disabled(audioItems.isEmpty)
                    } header: {
                        Text("Music for exported takes")
                    } footer: {
                        Text(audioItems.isEmpty
                             ? "Import an audio file you own to lay a clean track under your takes."
                             : "This track is laid under takes when you export them.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle(isImport ? "Import" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if case .importing(let pending) = mode { MediaStore.delete(pending.scratchURL) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImport ? "Import" : "Save") {
                        Task { await save() }
                    }
                    .disabled(provenance == nil || saving)
                }
            }
            .onAppear(perform: loadInitial)
            .interactiveDismissDisabled(isImport)
        }
    }

    private func loadInitial() {
        guard !didLoad else { return }
        didLoad = true
        switch mode {
        case .importing(let pending):
            title = pending.suggestedTitle
        case .editing(let item):
            title = item.title
            provenance = item.provenance
            choreographyID = item.choreographyID
            linkedAudioID = item.linkedAudioItemID
        }
    }

    @MainActor
    private func save() async {
        guard let provenance else { return }
        saving = true
        defer { saving = false }
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)

        switch mode {
        case .importing(let pending):
            let ext = pending.scratchURL.pathExtension.isEmpty ? "mov" : pending.scratchURL.pathExtension
            let filename = "\(UUID().uuidString).\(ext)"
            let dest = MediaStore.mediaURL(filename)
            do {
                try FileManager.default.moveItem(at: pending.scratchURL, to: dest)
            } catch {
                return
            }
            let probe = await MediaProbe.probe(dest)
            let fallbackTitle = choreographyID.flatMap { store.catalog.choreography(id: $0)?.title }
                ?? (pending.kind == .video ? "Imported video" : "Imported track")
            store.addLibraryItem(LibraryItem(
                title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                kind: pending.kind,
                filename: filename,
                durationSeconds: probe.duration,
                provenance: provenance,
                choreographyID: choreographyID,
                linkedAudioItemID: linkedAudioID,
                naturalSizeWidth: probe.size.map { Double($0.width) },
                naturalSizeHeight: probe.size.map { Double($0.height) }
            ))
            Haptics.success()

        case .editing(var item):
            if !cleanTitle.isEmpty { item.title = cleanTitle }
            item.provenance = provenance
            item.choreographyID = choreographyID
            item.linkedAudioItemID = linkedAudioID
            store.updateLibraryItem(item)
        }
        dismiss()
    }
}
