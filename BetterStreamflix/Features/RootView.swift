import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case home, movies, series, library, search, settings
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var homeTitleTransitionNamespace
    @Namespace private var movieTitleTransitionNamespace
    @Namespace private var seriesTitleTransitionNamespace
    @Namespace private var libraryTitleTransitionNamespace
    @Namespace private var searchTitleTransitionNamespace
    @StateObject private var homeTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var movieTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var seriesTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var libraryTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var searchTitleTransitionSelection = TitleTransitionSelection()
    @State private var selectedTab: Tab = .home
    @State private var searchIsPresented = false
    @State private var searchFocusRequest = 0
    @State private var searchReturnToRootRequest = 0
    @State private var searchIsShowingDetails = false
    @State private var isHomeReady = false
    @State private var pendingAutomaticUpdate: GitHubRelease?
    @State private var automaticUpdateRelease: GitHubRelease?
    @AppStorage("updates.skippedReleaseTag") private var skippedUpdateTag = ""

    var body: some View {
        ZStack {
            AppScreenBackground()

            TabView(selection: Binding(
                get: { selectedTab },
                set: { tab in
                    selectedTab = tab
                    searchIsPresented = tab == .search
                }
            )) {
                NavigationStack { HomeView(onInitialLoadCompleted: showHome) }
                    .environment(\.titleTransitionNamespace, homeTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, homeTitleTransitionSelection)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)

                NavigationStack { CatalogView(kind: .movie) }
                    .environment(\.titleTransitionNamespace, movieTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, movieTitleTransitionSelection)
                    .tabItem { Label("Movies", systemImage: "film.fill") }
                    .tag(Tab.movies)

                NavigationStack { CatalogView(kind: .series) }
                    .environment(\.titleTransitionNamespace, seriesTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, seriesTitleTransitionSelection)
                    .tabItem { Label("Series", systemImage: "tv.fill") }
                    .tag(Tab.series)

                NavigationStack { LibraryView() }
                    .environment(\.titleTransitionNamespace, libraryTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, libraryTitleTransitionSelection)
                    .tabItem { Label("Library", systemImage: "bookmark.fill") }
                    .tag(Tab.library)

                NavigationStack {
                    SearchView(
                        isSearchPresented: $searchIsPresented,
                        isShowingDetails: $searchIsShowingDetails,
                        focusRequest: searchFocusRequest,
                        returnToRootRequest: searchReturnToRootRequest
                    )
                }
                .environment(\.titleTransitionNamespace, searchTitleTransitionNamespace)
                .environment(\.titleTransitionSelection, searchTitleTransitionSelection)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(Tab.settings)
            }
            .tint(environment.theme.accent)
            .background {
                TabBarTapObserver(tabIndex: 4) {
                    guard selectedTab == .search else { return }
                    if searchIsShowingDetails {
                        searchReturnToRootRequest += 1
                    } else {
                        searchFocusRequest += 1
                    }
                }
            }
            .overlay(alignment: .top) {
                SourceLookupStatusOverlay()
                    .safeAreaPadding(.top, 8)
                    .zIndex(100)
            }

            if !isHomeReady {
                SplashScreen()
                    .transition(.opacity)
                    .zIndex(200)
            }
        }
        .task { await environment.refreshContinueWatchingForNewEpisodes() }
        .task(id: isHomeReady) {
            guard isHomeReady else { return }
            await environment.preloadPrimaryNavigationArtwork()
        }
        .task { await checkForUpdatesAtLaunch() }
        .task {
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            showHome()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await environment.refreshContinueWatchingForNewEpisodes() }
        }
        .onChange(of: isHomeReady) { _, isReady in
            guard isReady, let release = pendingAutomaticUpdate else { return }
            pendingAutomaticUpdate = nil
            automaticUpdateRelease = release
        }
        .sheet(item: $automaticUpdateRelease) { release in
            UpdateCheckSheet(
                result: .updateAvailable(release),
                onSkipUpdate: {
                    skippedUpdateTag = release.tagName
                    automaticUpdateRelease = nil
                },
                onRemindLater: {
                    automaticUpdateRelease = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func showHome() {
        guard !isHomeReady else { return }
        withAnimation(reduceMotion ? nil : DesignTokens.Motion.entrance) {
            isHomeReady = true
        }
    }

    private func checkForUpdatesAtLaunch() async {
        // Only auto-prompt when the Releases API is reachable without auth.
        // On a private app repo this quietly no-ops; Settings still offers a
        // Releases CTA that never needs a PAT in the app.
        do {
            let release = try await GitHubReleaseClient().latestRelease()
            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0"
            guard UpdateCheckService.shouldOfferUpdate(
                tagName: release.tagName,
                currentVersion: currentVersion,
                skippedTagName: skippedUpdateTag
            ) else { return }

            if isHomeReady {
                automaticUpdateRelease = release
            } else {
                pendingAutomaticUpdate = release
            }
        } catch {
            // Launch continues normally when Releases cannot be queried.
        }
    }
}
