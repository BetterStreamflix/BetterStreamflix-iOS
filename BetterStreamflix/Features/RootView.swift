import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case home, movies, series, library, more
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var watchlistToast: WatchlistToastStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var homeTitleTransitionNamespace
    @Namespace private var movieTitleTransitionNamespace
    @Namespace private var seriesTitleTransitionNamespace
    @Namespace private var libraryTitleTransitionNamespace
    @Namespace private var moreTitleTransitionNamespace
    @StateObject private var homeTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var movieTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var seriesTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var libraryTitleTransitionSelection = TitleTransitionSelection()
    @StateObject private var moreTitleTransitionSelection = TitleTransitionSelection()
    @State private var selectedTab: Tab = .home
    @State private var catalogSearchRequest = 0
    @State private var isHomeReady = false
    @State private var pendingAutomaticUpdate: GitHubRelease?
    @State private var automaticUpdateRelease: GitHubRelease?
    @AppStorage("updates.skippedReleaseTag") private var skippedUpdateTag = ""

    var body: some View {
        ZStack {
            AppScreenBackground()

            TabView(selection: $selectedTab) {
                NavigationStack { HomeView(onInitialLoadCompleted: showHome) }
                    .environment(\.titleTransitionNamespace, homeTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, homeTitleTransitionSelection)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(Tab.home)

                NavigationStack {
                    CatalogView(
                        kind: .movie,
                        onOpenSearch: { selectedTab = .more; catalogSearchRequest += 1 }
                    )
                }
                .environment(\.titleTransitionNamespace, movieTitleTransitionNamespace)
                .environment(\.titleTransitionSelection, movieTitleTransitionSelection)
                .tabItem { Label("Movies", systemImage: "film.fill") }
                .tag(Tab.movies)

                NavigationStack {
                    CatalogView(
                        kind: .series,
                        onOpenSearch: { selectedTab = .more; catalogSearchRequest += 1 }
                    )
                }
                .environment(\.titleTransitionNamespace, seriesTitleTransitionNamespace)
                .environment(\.titleTransitionSelection, seriesTitleTransitionSelection)
                .tabItem { Label("Series", systemImage: "tv.fill") }
                .tag(Tab.series)

                NavigationStack { LibraryView() }
                    .environment(\.titleTransitionNamespace, libraryTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, libraryTitleTransitionSelection)
                    .tabItem { Label("Library", systemImage: "bookmark.fill") }
                    .tag(Tab.library)

                MoreView(openSearchRequest: catalogSearchRequest)
                    .environment(\.titleTransitionNamespace, moreTitleTransitionNamespace)
                    .environment(\.titleTransitionSelection, moreTitleTransitionSelection)
                    .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                    .tag(Tab.more)
            }
            .tint(environment.theme.accent)
            .toolbar(.visible, for: .tabBar)
            .overlay(alignment: .top) {
                SourceLookupStatusOverlay()
                    .safeAreaPadding(.top, 8)
                    .zIndex(100)
            }
            .overlay(alignment: .top) {
                WatchlistToastBanner(toast: watchlistToast.toast)
                    .safeAreaPadding(.top, 8)
                    .animation(DesignTokens.Motion.toast, value: watchlistToast.toast)
                    .zIndex(110)
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
