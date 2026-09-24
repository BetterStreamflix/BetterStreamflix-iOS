import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SearchView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @Environment(\.titleTransitionSelection) private var transitionSelection
    @StateObject private var model = SearchViewModel()
    @StateObject private var discovery = TMDBCollectionsViewModel(
        collections: [.trending(.series), .trending(.movie)]
    )
    @State private var selectedDetails: ResolvedMediaItem?
    @FocusState private var searchFieldIsFocused: Bool
    @Binding var isSearchPresented: Bool
    @Binding var isShowingDetails: Bool
    let focusRequest: Int
    let returnToRootRequest: Int
    /// When true, Search is a standalone destination with system Back chrome
    /// (not nested under the More tab large-title treatment).
    var showsNavigationChrome: Bool = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if !showsNavigationChrome {
                    PageTitleHeader(title: "Search", ignoresTopSafeArea: true)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Movies and series", text: $model.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFieldIsFocused)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 20)
                .padding(.top, showsNavigationChrome ? 8 : 0)

                if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !model.recentSearches.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Recent")
                                    .font(DesignTokens.Typography.shelfTitle)
                                Spacer()
                                Button("Clear") {
                                    model.clearRecentSearches()
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.recentSearches, id: \.self) { recent in
                                        Button {
                                            model.applyRecentSearch(recent)
                                            model.search(environment: environment)
                                        } label: {
                                            Text(recent)
                                                .font(.subheadline.weight(.medium))
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .glassEffectWithFallback(in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    Text("Discover")
                        .font(DesignTokens.Typography.shelfTitle)
                        .padding(.horizontal, 20)
                    ForEach(discovery.collections) { collection in
                        if let titles = discovery.titles[collection], !titles.isEmpty {
                            TMDBShelfView(
                                collection: collection,
                                titles: titles,
                                resolvingKeys: sourceLookup.activeKeys,
                                onSelect: open
                            )
                        }
                    }
                } else if model.results.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try another title, or clear the search to browse Discover.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                } else {
                    LazyVGrid(
                        columns: MediaArtworkLayout.gridColumns,
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(model.results) { item in
                            Button { open(item) } label: {
                                PosterGridCard(item: item)
                                    .titleTransitionSource(
                                        id: item.artworkIdentityKey,
                                        sourceID: transitionSourceID(for: item)
                                    )
                                    .contextMenu {
                                        MediaTitlePosterActions(item: item) {
                                            open(item)
                                        }
                                    }
                            }
                            .pressablePoster()
                        }
                    }
                    .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
                }
            }
            .padding(.bottom, 28)
            // Stretch the themed fill into the bounce region so overscroll
            // never flashes a black gap above the content.
            .background {
                AppScreenBackground()
                    .padding(.vertical, -400)
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background { AppScreenBackground().ignoresSafeArea() }
        .modifier(SearchChromeModifier(showsNavigationChrome: showsNavigationChrome))
        .onChange(of: model.query) { _, _ in model.search(environment: environment) }
        .onChange(of: isSearchPresented) { _, presented in
            if !presented { searchFieldIsFocused = false }
        }
        .onChange(of: focusRequest) { _, _ in
            searchFieldIsFocused = true
        }
        .onChange(of: returnToRootRequest) { _, _ in
            searchFieldIsFocused = false
            selectedDetails = nil
        }
        .onChange(of: selectedDetails) { _, details in
            isShowingDetails = details != nil
            if details == nil { searchFieldIsFocused = false }
        }
        .overlay {
            if model.isLoading || (
                model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && discovery.isLoading
                    && discovery.titles.isEmpty
            ) {
                ProgressView()
            }
        }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task {
            await discovery.load(environment: environment)
        }
        .task(id: focusRequest) {
            try? await Task.sleep(for: .milliseconds(280))
            searchFieldIsFocused = true
        }
        .errorAlert($model.errorMessage)
        .errorAlert($discovery.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        searchFieldIsFocused = false
        selectedDetails = ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }

    private func open(_ item: MediaItem) {
        searchFieldIsFocused = false
        transitionSelection?.select(
            titleID: item.artworkIdentityKey,
            sourceID: transitionSourceID(for: item)
        )
        selectedDetails = ResolvedMediaItem(media: item, tmdbMetadata: nil)
    }

    private func transitionSourceID(for item: MediaItem) -> String {
        "\(item.artworkIdentityKey):search-grid"
    }
}

private struct SearchChromeModifier: ViewModifier {
    let showsNavigationChrome: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsNavigationChrome {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbar(.visible, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
        } else {
            content
                .ignoresSafeArea(edges: .top)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.visible, for: .tabBar)
        }
    }
}

/// Standalone Search destination presented above the tab bar so Movies/Series
/// shortcuts never leave the More tab highlighted underneath.
struct SearchPresentationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isSearchPresented = true
    @State private var isShowingDetails = false
    @State private var focusRequest = 1
    @Namespace private var searchTitleTransitionNamespace
    @StateObject private var searchTitleTransitionSelection = TitleTransitionSelection()

    var body: some View {
        NavigationStack {
            SearchView(
                isSearchPresented: $isSearchPresented,
                isShowingDetails: $isShowingDetails,
                focusRequest: focusRequest,
                returnToRootRequest: 0,
                showsNavigationChrome: true
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text("Back")
                        }
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .environment(\.titleTransitionNamespace, searchTitleTransitionNamespace)
        .environment(\.titleTransitionSelection, searchTitleTransitionSelection)
    }
}
