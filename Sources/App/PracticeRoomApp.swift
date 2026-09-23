import SwiftUI

@main
struct PracticeRoomApp: App {
    @StateObject private var store = AppStore()

    init() {
        Appearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}

enum Appearance {
    static func apply() {
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Palette.ink)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Palette.ink)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
                .tag(0)

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.3d.down.right") }
                .tag(1)

            RecordingsView()
                .tabItem { Label("Takes", systemImage: "video.badge.checkmark") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .sheet(isPresented: needsRightsNotice) {
            RightsNoticeSheet()
                .interactiveDismissDisabled()
        }
    }

    /// Shown once, on first launch. It is not a EULA dump — it is two screens explaining which
    /// features work on which kind of video and why, because that asymmetry is the single most
    /// confusing thing about the app if you meet it cold.
    private var needsRightsNotice: Binding<Bool> {
        Binding(
            get: { !store.settings.hasAcceptedRightsNotice },
            set: { newValue in
                if !newValue { store.settings.hasAcceptedRightsNotice = true }
            }
        )
    }
}
