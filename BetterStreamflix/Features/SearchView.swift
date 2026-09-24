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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageTitleHeader(title: "Search", ignoresTopSafeArea: true)

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
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 20)

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
            .padding(.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background { AppScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
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
