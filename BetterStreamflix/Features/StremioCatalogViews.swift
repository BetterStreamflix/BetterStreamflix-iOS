import SwiftUI

struct StremioCatalogHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @ObservedObject private var debrid = StremioDebridStore.shared
    @StateObject private var model = StremioCatalogHubModel()
    @State private var selectedItem: MediaItem?
    @State private var searchDraft = ""
    @State private var isSearching = false
    @State private var typeFilter: String? = nil
    @FocusState private var searchFocused: Bool

    private let typeTabs = ["movie", "series", "anime", "channel"]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageTitleHeader(title: "Stremio", ignoresTopSafeArea: true)

                introCard
                    .padding(.horizontal, 20)

                searchCard
                    .padding(.horizontal, 20)

                typePicker
                    .padding(.horizontal, 20)

                if !model.searchResults.isEmpty {
                    MediaShelfView(
                        title: "Search results",
                        items: model.searchResults,
                        onDetails: { selectedItem = $0 }
                    )
                }

                if store.catalogAddons.isEmpty {
                    emptyState
                        .padding(.horizontal, 20)
                } else {
                    addonPicker
                        .padding(.horizontal, 20)

                    if !model.genreOptions.isEmpty {
                        genrePicker
                            .padding(.horizontal, 20)
                    }

                    ForEach(filteredShelves) { shelf in
                        VStack(alignment: .leading, spacing: 8) {
                            MediaShelfView(
                                title: shelf.title,
                                items: shelf.items,
                                onDetails: { selectedItem = $0 }
                            )
                            if shelf.canPaginate {
                                Button {
                                    Task {
                                        await model.loadMore(
                                            shelfID: shelf.id,
                                            store: store,
                                            client: HTTPClient()
                                        )
                                    }
                                } label: {
                                    Text(shelf.isLoadingMore ? "Loading…" : "Show more")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 20)
                                }
                                .disabled(shelf.isLoadingMore)
                            }
                            if let error = shelf.errorMessage {
                                HStack {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(Color(hex: 0xFF6B6B))
                                    Button("Retry") {
                                        Task {
                                            await model.load(
                                                store: store,
                                                client: HTTPClient(),
                                                force: true,
                                                adultOK: debrid.adultCatalogsOptIn
                                            )
                                        }
                                    }
                                    .font(.caption2.weight(.semibold))
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }

                    if let message = model.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .padding(.bottom, 28)
            .background {
                AppScreenBackground()
                    .padding(.vertical, -400)
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .background { AppScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedItem) { item in
            DetailsView(item: item)
        }
        .task(id: store.addons.map(\.id) + [model.selectedAddonID ?? "", model.selectedGenre ?? "", typeFilter ?? ""]) {
            await model.load(store: store, client: HTTPClient(), adultOK: debrid.adultCatalogsOptIn)
        }
        .refreshable {
            await model.load(store: store, client: HTTPClient(), force: true, adultOK: debrid.adultCatalogsOptIn)
        }
    }

    private var filteredShelves: [StremioCatalogHubModel.Shelf] {
        guard let typeFilter else { return model.shelves }
        return model.shelves.filter { shelf in
            shelf.catalogType.lowercased() == typeFilter
                || shelf.title.lowercased().contains(typeFilter)
        }
    }

    private var typePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                typeChip(nil, title: "All")
                ForEach(typeTabs, id: \.self) { type in
                    typeChip(type, title: type.capitalized)
                }
            }
        }
    }

    private func typeChip(_ type: String?, title: String) -> some View {
        let selected = typeFilter == type
        return Button {
            typeFilter = type
            DesignTokens.Haptics.selection()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? .white : AppTheme.primaryText)
                .background {
                    Capsule()
                        .fill(selected ? environment.theme.accent : AppTheme.elevatedSurface)
                }
        }
        .buttonStyle(.plain)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Addon catalogs")
                .font(DesignTokens.Typography.shelfTitle)
            Text("Browse remote Stremio catalogs. Play still goes through NativePlayer with your language providers and enabled stream addons (Debrid for torrent indexes).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                StremioAddonsSettingsView()
            } label: {
                Label("Manage plugins", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(environment.theme.accentBright)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(environment.theme.accentBright)
                TextField("Search addon catalogs", text: $searchDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch() } }
                if isSearching {
                    ProgressView()
                } else if !searchDraft.isEmpty {
                    Button {
                        Task { await runSearch() }
                    } label: {
                        Text("Go")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(environment.theme.accentBright)
                }
            }
            if !model.searchResults.isEmpty {
                Button("Clear search") {
                    searchDraft = ""
                    model.clearSearch()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var addonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(id: nil, title: "All addons")
                ForEach(store.catalogAddons.filter { debrid.adultCatalogsOptIn || !$0.isAdult }) { addon in
                    filterChip(id: addon.id, title: addon.name)
                }
            }
        }
    }

    private var genrePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                genreChip(nil, title: "All genres")
                ForEach(model.genreOptions, id: \.self) { genre in
                    genreChip(genre, title: genre)
                }
            }
        }
    }

    private func filterChip(id: String?, title: String) -> some View {
        let selected = model.selectedAddonID == id
        return Button {
            model.selectedAddonID = id
            DesignTokens.Haptics.selection()
            Task {
                await model.load(
                    store: store,
                    client: HTTPClient(),
                    force: true,
                    adultOK: debrid.adultCatalogsOptIn
                )
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffectWithFallback(in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    selected ? environment.theme.accentBright.opacity(0.95) : Color.clear,
                    lineWidth: 1.2
                )
        }
    }

    private func genreChip(_ genre: String?, title: String) -> some View {
        let selected = model.selectedGenre == genre
        return Button {
            model.selectedGenre = genre
            DesignTokens.Haptics.selection()
            Task {
                await model.load(
                    store: store,
                    client: HTTPClient(),
                    force: true,
                    adultOK: debrid.adultCatalogsOptIn
                )
            }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffectWithFallback(in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    selected ? environment.theme.accentBright.opacity(0.95) : Color.clear,
                    lineWidth: 1.2
                )
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No catalog plugins yet")
                .font(.headline.weight(.semibold))
            Text("Install Cinemeta or another remote catalog addon to fill this hub with Stremio shelves.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                StremioAddonsSettingsView()
            } label: {
                Text("Open plugin settings")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .glassEffectWithFallback(in: Capsule())
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func runSearch() async {
        let query = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            model.clearSearch()
            return
        }
        isSearching = true
        defer { isSearching = false }
        await model.search(query: query, store: store, client: HTTPClient())
        DesignTokens.Haptics.selection()
    }
}

@MainActor
final class StremioCatalogHubModel: ObservableObject {
    struct Shelf: Identifiable, Hashable {
        let id: String
        let title: String
        var items: [MediaItem]
        var skip: Int
        var canPaginate: Bool
        var isLoadingMore: Bool
        var errorMessage: String?
        let addonID: String
        let catalogType: String
        let catalogID: String
    }

    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var searchResults: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var genreOptions: [String] = []
    @Published var selectedAddonID: String?
    @Published var selectedGenre: String?

    private let pageSize = 40
    private let maxCatalogsPerAddon = 12

    func clearSearch() {
        searchResults = []
    }

    func load(
        store: StremioAddonStore,
        client: any HTTPClientProtocol,
        force: Bool = false,
        adultOK: Bool = false,
        typeFilter: String? = nil,
        maxShelves: Int? = nil
    ) async {
        guard !isLoading || force else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }

        let addons = store.catalogAddons.filter { addon in
            if !adultOK && addon.isAdult { return false }
            guard let selectedAddonID else { return true }
            return addon.id == selectedAddonID
        }

        var options = Set<String>()
        for addon in addons {
            for catalog in addon.catalogs where catalog.supportsGenre {
                options.formUnion(catalog.genreOptions)
            }
        }
        genreOptions = options.sorted()

        // Parallel catalog fetches (F1).
        let genre = selectedGenre
        let pageSize = self.pageSize
        let results: [(Shelf, String?)] = await withTaskGroup(
            of: (Shelf, String?).self,
            returning: [(Shelf, String?)].self
        ) { group in
            for addon in addons {
                let catalogs = addon.catalogs
                    .filter { catalog in
                        if let typeFilter {
                            return catalog.type == typeFilter
                        }
                        return ["movie", "series", "anime", "channel"].contains(catalog.type)
                    }
                    .prefix(maxCatalogsPerAddon)
                for catalog in catalogs {
                    group.addTask {
                        let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
                        var extras: [String: String] = [:]
                        if let genre, catalog.supportsGenre {
                            extras["genre"] = genre
                        }
                        do {
                            let metas = try await addonClient.catalog(
                                type: catalog.type,
                                id: catalog.id,
                                extras: extras
                            )
                            let items = metas.prefix(pageSize).map {
                                $0.asMediaItem(providerID: "stremio:\(addon.id)")
                            }
                            let shelf = Shelf(
                                id: "\(addon.id):\(catalog.stableID)",
                                title: "\(addon.name) · \(catalog.displayName)",
                                items: Array(items),
                                skip: items.count,
                                canPaginate: catalog.supportsSkip && metas.count >= pageSize,
                                isLoadingMore: false,
                                errorMessage: nil,
                                addonID: addon.id,
                                catalogType: catalog.type,
                                catalogID: catalog.id
                            )
                            return (shelf, nil as String?)
                        } catch {
                            let empty = Shelf(
                                id: "\(addon.id):\(catalog.stableID)",
                                title: "\(addon.name) · \(catalog.displayName)",
                                items: [],
                                skip: 0,
                                canPaginate: false,
                                isLoadingMore: false,
                                errorMessage: error.localizedDescription,
                                addonID: addon.id,
                                catalogType: catalog.type,
                                catalogID: catalog.id
                            )
                            return (empty, error.localizedDescription)
                        }
                    }
                }
            }
            var collected: [(Shelf, String?)] = []
            for await pair in group {
                collected.append(pair)
            }
            return collected
        }

        var built = results.map(\.0).filter { !$0.items.isEmpty || $0.errorMessage != nil }
        if let maxShelves {
            built = Array(built.prefix(maxShelves))
        }
        shelves = built
        let errors = results.compactMap(\.1)
        if built.filter({ !$0.items.isEmpty }).isEmpty {
            message = store.catalogAddons.isEmpty
                ? nil
                : (errors.first.map { "Catalog error: \($0)" }
                    ?? "Catalogs didn’t return items. Check plugin health in Manage plugins.")
        }
    }

    func loadMore(shelfID: String, store: StremioAddonStore, client: any HTTPClientProtocol) async {
        guard let index = shelves.firstIndex(where: { $0.id == shelfID }) else { return }
        guard shelves[index].canPaginate, !shelves[index].isLoadingMore else { return }
        shelves[index].isLoadingMore = true
        let shelf = shelves[index]
        guard let addon = store.catalogAddons.first(where: { $0.id == shelf.addonID }) else {
            shelves[index].isLoadingMore = false
            return
        }
        do {
            let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
            var extras: [String: String] = ["skip": "\(shelf.skip)"]
            if let genre = selectedGenre { extras["genre"] = genre }
            let metas = try await addonClient.catalog(
                type: shelf.catalogType,
                id: shelf.catalogID,
                extras: extras
            )
            let items = metas.prefix(pageSize).map {
                $0.asMediaItem(providerID: "stremio:\(addon.id)")
            }
            shelves[index].items.append(contentsOf: items)
            shelves[index].skip += items.count
            shelves[index].canPaginate = items.count >= pageSize
            shelves[index].errorMessage = nil
        } catch {
            shelves[index].errorMessage = error.localizedDescription
        }
        shelves[index].isLoadingMore = false
    }

    func search(query: String, store: StremioAddonStore, client: any HTTPClientProtocol) async {
        var results: [MediaItem] = []
        var seen = Set<String>()
        await withTaskGroup(of: [MediaItem].self) { group in
            for addon in store.catalogAddons {
                let searchable = addon.catalogs.filter(\.supportsSearch)
                let targets = searchable.isEmpty
                    ? Array(addon.catalogs.prefix(2))
                    : Array(searchable.prefix(4))
                group.addTask {
                    let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
                    var local: [MediaItem] = []
                    for catalog in targets {
                        do {
                            let metas = try await addonClient.catalog(
                                type: catalog.type,
                                id: catalog.id,
                                extras: ["search": query]
                            )
                            local.append(contentsOf: metas.prefix(24).map {
                                $0.asMediaItem(providerID: "stremio:\(addon.id)")
                            })
                        } catch {
                            continue
                        }
                    }
                    return local
                }
            }
            for await batch in group {
                for item in batch where seen.insert(item.id).inserted {
                    results.append(item)
                }
            }
        }
        searchResults = results
        if results.isEmpty {
            message = "No catalog matches for “\(query)”."
        }
    }
}

struct StremioHomeShelvesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @ObservedObject private var debrid = StremioDebridStore.shared
    @StateObject private var model = StremioCatalogHubModel()
    @State private var ready = false
    var onDetails: (MediaItem) -> Void
    var typeFilter: String? = nil
    var maxShelves: Int = 4

    private var orderedShelves: [StremioCatalogHubModel.Shelf] {
        let favorites = StremioFavoriteCatalogsStore.favorites
        let filled = model.shelves.filter { !$0.items.isEmpty }
        let pinned = filled.filter { favorites.contains($0.id) }
        let rest = filled.filter { !favorites.contains($0.id) }
        return Array((pinned + rest).prefix(maxShelves))
    }

    var body: some View {
        Group {
            if ready, !orderedShelves.isEmpty {
                HStack {
                    Text("Stremio")
                        .font(DesignTokens.Typography.shelfTitle)
                    Spacer()
                    NavigationLink {
                        StremioCatalogHubView()
                    } label: {
                        Text("See all")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(environment.theme.accentBright)
                    }
                }
                .padding(.horizontal, 20)

                ForEach(orderedShelves) { shelf in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                StremioFavoriteCatalogsStore.toggle(shelf.id)
                                DesignTokens.Haptics.selection()
                            } label: {
                                Image(systemName: StremioFavoriteCatalogsStore.isFavorite(shelf.id) ? "star.fill" : "star")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(environment.theme.accentBright)
                                    .padding(.trailing, 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                StremioFavoriteCatalogsStore.isFavorite(shelf.id) ? "Unpin catalog" : "Pin catalog"
                            )
                        }
                        MediaShelfView(
                            title: shelf.title,
                            items: shelf.items,
                            onDetails: onDetails
                        )
                    }
                }
            }
        }
        .task(id: store.enabledAddons.map(\.id)) {
            try? await Task.sleep(for: .milliseconds(350))
            await model.load(
                store: store,
                client: HTTPClient(),
                adultOK: debrid.adultCatalogsOptIn,
                typeFilter: typeFilter,
                maxShelves: maxShelves + 4
            )
            ready = true
        }
    }
}

/// Movies / Series tab Stremio shelves.
struct StremioCatalogKindShelvesView: View {
    let kind: MediaKind
    var onDetails: (MediaItem) -> Void

    var body: some View {
        StremioHomeShelvesView(
            onDetails: onDetails,
            typeFilter: kind == .movie ? "movie" : "series",
            maxShelves: 6
        )
    }
}
