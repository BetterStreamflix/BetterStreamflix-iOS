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
    @State private var isSearchPresented = false
    @State private var isHomeReady = false
    @State private var hasCompletedSetup = AppSetupStore.isCompleted
    @State private var pendingAutomaticUpdate: AppUpdateInfo?
    @State private var automaticUpdateRelease: AppUpdateInfo?
    @State private var pendingStremioInstallURL: String?
    @State private var shortcutResumePlayback: PlaybackRequest?
    @AppStorage("updates.skippedReleaseTag") private var skippedUpdateTag = ""

    var body: some View {
        ZStack {
            AppScreenBackground()

            if hasCompletedSetup {
                mainTabs
            } else {
                FirstLaunchSetupView {
                    withAnimation(reduceMotion ? nil : DesignTokens.Motion.entrance) {
                        hasCompletedSetup = true
                    }
                }
                .transition(.opacity)
                .zIndex(50)
            }

            if hasCompletedSetup, !isHomeReady {
                SplashScreen()
                    .transition(.opacity)
                    .zIndex(200)
            }
        }
        .fullScreenCover(isPresented: $isSearchPresented) {
            SearchPresentationView()
        }
        .task(id: hasCompletedSetup) {
            guard hasCompletedSetup else { return }
            await environment.refreshContinueWatchingForNewEpisodes()
        }
        .task(id: isHomeReady) {
            guard isHomeReady else { return }
            await environment.preloadPrimaryNavigationArtwork()
        }
        .task(id: hasCompletedSetup) {
            guard hasCompletedSetup else { return }
            await checkForUpdatesAtLaunch()
        }
        .task(id: hasCompletedSetup) {
            guard hasCompletedSetup else { return }
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            showHome()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, hasCompletedSetup else { return }
            Task { await environment.refreshContinueWatchingForNewEpisodes() }
            Task { await StremioForegroundHealthSweep.runIfNeeded() }
        }
        .onChange(of: isHomeReady) { _, isReady in
            guard isReady, let release = pendingAutomaticUpdate else { return }
            pendingAutomaticUpdate = nil
            automaticUpdateRelease = release
        }
        .onReceive(NotificationCenter.default.publisher(for: StremioInstallDeepLink.didReceiveNotification)) { note in
            if let raw = note.object as? String {
                pendingStremioInstallURL = raw
            } else if let pending = StremioInstallDeepLink.peekPending() {
                pendingStremioInstallURL = pending
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: StremioShortcutBridge.didReceiveNotification)) { note in
            handleShortcut(routeRaw: note.object as? String)
        }
        .onAppear {
            if pendingStremioInstallURL == nil,
               let pending = StremioInstallDeepLink.peekPending() {
                pendingStremioInstallURL = pending
            }
            if let pending = StremioShortcutBridge.consumePending() {
                handleShortcut(routeRaw: pending.rawValue)
            }
        }
        .fullScreenCover(item: $shortcutResumePlayback) { request in
            PlayerScreen(request: request, nextRequest: nil)
                .environmentObject(environment)
                .environmentObject(environment.library)
        }
        .sheet(item: $automaticUpdateRelease) { info in
            UpdateCheckSheet(
                result: .updateAvailable(info),
                onSkipUpdate: {
                    skippedUpdateTag = info.tagName
                    automaticUpdateRelease = nil
                },
                onRemindLater: {
                    automaticUpdateRelease = nil
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
        }
        .sheet(isPresented: Binding(
            get: { pendingStremioInstallURL != nil },
            set: { if !$0 { pendingStremioInstallURL = nil } }
        )) {
            if let pendingStremioInstallURL {
                StremioInstallPromptSheet(
                    rawURL: pendingStremioInstallURL,
                    onDismiss: {
                        _ = StremioInstallDeepLink.consumePending()
                        self.pendingStremioInstallURL = nil
                    },
                    onInstalled: {
                        selectedTab = .more
                    }
                )
                .environmentObject(environment)
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView(onInitialLoadCompleted: showHome) }
                .environment(\.titleTransitionNamespace, homeTitleTransitionNamespace)
                .environment(\.titleTransitionSelection, homeTitleTransitionSelection)
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            NavigationStack {
                CatalogView(
                    kind: .movie,
                    onOpenSearch: { isSearchPresented = true }
                )
            }
            .environment(\.titleTransitionNamespace, movieTitleTransitionNamespace)
            .environment(\.titleTransitionSelection, movieTitleTransitionSelection)
            .tabItem { Label("Movies", systemImage: "film.fill") }
            .tag(Tab.movies)

            NavigationStack {
                CatalogView(
                    kind: .series,
                    onOpenSearch: { isSearchPresented = true }
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

            MoreView(onOpenSearch: { isSearchPresented = true })
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
        .overlay(alignment: .bottom) {
            WatchlistToastBanner(toast: watchlistToast.toast)
                .padding(.horizontal, 20)
                .safeAreaPadding(.bottom, 10)
                .padding(.bottom, 56)
                .animation(DesignTokens.Motion.toast, value: watchlistToast.toast)
                .zIndex(110)
        }
    }

    private func showHome() {
        guard !isHomeReady else { return }
        withAnimation(reduceMotion ? nil : DesignTokens.Motion.entrance) {
            isHomeReady = true
        }
    }

    private func handleShortcut(routeRaw: String?) {
        guard let raw = routeRaw,
              let route = StremioShortcutBridge.Route(rawValue: raw) else { return }
        switch route {
        case .resume:
            if let progress = environment.library.continueWatching.first {
                shortcutResumePlayback = PlaybackRequest(
                    media: progress.media,
                    episode: progress.episode
                )
            } else {
                selectedTab = .library
            }
        case .hub, .debrid, .addons:
            selectedTab = .more
            UserDefaults.standard.set(raw, forKey: "stremio.shortcut.moreRoute.v1")
            NotificationCenter.default.post(
                name: Notification.Name("stremio.shortcut.moreRoute"),
                object: raw
            )
        }
    }

    private func checkForUpdatesAtLaunch() async {
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        do {
            let info = try await PublicUpdateFeedClient().latest()
            guard UpdateCheckService.shouldOfferUpdate(
                info: info,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                skippedTagName: skippedUpdateTag
            ) else { return }

            if isHomeReady {
                automaticUpdateRelease = info
            } else {
                pendingAutomaticUpdate = info
            }
        } catch {
            // Launch continues normally when the public feed cannot be queried.
        }
    }
}
