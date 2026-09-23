import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var apiKeyDraft = ""
    @State private var hasKey = ContentService.shared.hasAPIKey
    @State private var keyStatus: String?
    @State private var checkingKey = false
    @State private var confirmClearCache = false

    var body: some View {
        NavigationStack {
            Form {
                youTubeSection
                studioSection
                recordingSection
                tutorialSection
                storageSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ink.ignoresSafeArea())
            .navigationTitle("Settings")
            .confirmationDialog("Clear cached tutorial lists?", isPresented: $confirmClearCache,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { store.clearTutorialCache() }
            } message: {
                Text("They'll be fetched again the next time you open each routine, which uses API quota.")
            }
        }
    }

    // MARK: - YouTube

    private var youTubeSection: some View {
        Section {
            if hasKey {
                HStack {
                    Label("API key saved", systemImage: "checkmark.seal.fill")
                        .foregroundColor(Palette.mint)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        ContentService.shared.apiKey = nil
                        hasKey = false
                        keyStatus = nil
                    }
                }
                Button {
                    Task { await checkKey() }
                } label: {
                    HStack {
                        Text("Test the key")
                        if checkingKey { Spacer(); ProgressView() }
                    }
                }
                .disabled(checkingKey)
            } else {
                SecureField("Paste YouTube Data API v3 key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    ContentService.shared.apiKey = trimmed
                    apiKeyDraft = ""
                    hasKey = ContentService.shared.hasAPIKey
                    Task { await checkKey() }
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyStatus {
                Text(keyStatus)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondaryText)
            }
        } header: {
            Text("YouTube")
        } footer: {
            Text("Optional. With a free key from Google Cloud Console the app finds reference videos and ranks tutorials for you. Without one, paste links yourself. The key is stored in the Keychain and only used for read-only metadata lookups.")
        }
    }

    @MainActor
    private func checkKey() async {
        checkingKey = true
        defer { checkingKey = false }
        // `videos.list` costs 1 quota unit, versus 100 for a search — the cheapest honest probe.
        let api = YouTubeAPI(apiKey: ContentService.shared.apiKey, regionCode: store.settings.tutorialRegionCode)
        do {
            _ = try await api.details(for: ["jNQXAC9IVRw"])
            keyStatus = "Key works."
        } catch {
            keyStatus = (error as? YouTubeAPIError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Studio

    private var studioSection: some View {
        Section("Studio") {
            Picker("Default layout", selection: $store.settings.defaultLayout) {
                ForEach(StudioLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.symbol).tag(layout)
                }
            }
            Picker("Default speed", selection: $store.settings.defaultSpeed) {
                ForEach(PlaybackSpeed.allCases) { speed in
                    Text(speed.label).tag(speed.rawValue)
                }
            }
            Toggle("Mirror reference by default", isOn: $store.settings.mirrorByDefault)
            Toggle("Show positioning grid", isOn: $store.settings.showGridOverlay)
            Toggle("Keep screen awake", isOn: $store.settings.keepScreenAwakeInStudio)
        }
    }

    // MARK: - Recording

    private var recordingSection: some View {
        Section {
            Stepper(value: $store.settings.countdownSeconds, in: 0...15) {
                HStack {
                    Text("Countdown")
                    Spacer()
                    Text(store.settings.countdownSeconds == 0 ? "Off" : "\(store.settings.countdownSeconds)s")
                        .foregroundColor(Palette.secondaryText)
                }
            }
            Toggle("Stop at the end of the loop", isOn: $store.settings.autoStopAtSectionEnd)
            if store.settings.autoStopAtSectionEnd {
                Stepper(value: $store.settings.loopCountBeforeStop, in: 1...10) {
                    HStack {
                        Text("Runs per take")
                        Spacer()
                        Text("\(store.settings.loopCountBeforeStop)")
                            .foregroundColor(Palette.secondaryText)
                    }
                }
            }
            Toggle("Use front camera", isOn: $store.settings.useFrontCamera)
            Toggle("Save takes mirrored", isOn: $store.settings.saveTakesMirrored)
            Toggle("Record microphone", isOn: $store.settings.micEnabled)
        } header: {
            Text("Recording")
        } footer: {
            Text("Mirrored takes match what you saw while dancing, which is what most dancers want when reviewing.")
        }
    }

    // MARK: - Tutorials

    private var tutorialSection: some View {
        Section("Tutorials") {
            Toggle("Rank mirrored tutorials higher", isOn: $store.settings.preferMirroredTutorials)
            Picker("Language", selection: $store.settings.tutorialLanguageHint) {
                Text("English").tag("en")
                Text("Korean").tag("ko")
                Text("Japanese").tag("ja")
                Text("Spanish").tag("es")
            }
            Picker("Region", selection: $store.settings.tutorialRegionCode) {
                ForEach(["US", "GB", "KR", "JP", "CA", "AU", "PH", "BR", "MX", "DE", "FR"], id: \.self) { code in
                    Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                }
            }
            Button("Clear cached tutorial lists", role: .destructive) { confirmClearCache = true }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage") {
            row("Library files", "\(store.library.count)")
            row("Takes", "\(store.recordings.count)")
            row("Space used", ByteCountFormatter.string(fromByteCount: MediaStore.totalBytesUsed(), countStyle: .file))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            Button("Show the “two kinds of video” intro again") {
                store.settings.hasAcceptedRightsNotice = false
            }
            row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(Palette.secondaryText)
        }
    }
}
