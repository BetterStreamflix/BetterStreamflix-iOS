import SwiftUI

struct StremioCatalogHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @StateObject private var model = StremioCatalogHubModel()
    @State private var selectedItem: MediaItem?
    @State private var searchDraft = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageTitleHeader(title: "Stremio", ignoresTopSafeArea: true)

                introCard
                    .padding(.horizontal, 20)

                searchCard
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

                    ForEach(model.shelves) { shelf in
                        MediaShelfView(
                            title: shelf.title,
                            items: shelf.items,
                            onDetails: { selectedItem = $0 }
                        )
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
        .task(id: store.addons.map(\.id) + [model.selectedAddonID ?? ""]) {
            await model.load(store: store, client: HTTPClient())
        }
        .refreshable {
            await model.load(store: store, client: HTTPClient(), force: true)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Addon catalogs")
                .font(DesignTokens.Typography.shelfTitle)
            Text("Browse remote Stremio catalogs. Play still goes through NativePlayer with your language providers and enabled stream addons.")
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
                ForEach(store.catalogAddons) { addon in
                    filterChip(id: addon.id, title: addon.name)
                }
            }
        }
    }

    private func filterChip(id: String?, title: String) -> some View {
        let selected = model.selectedAddonID == id
        return Button {
            model.selectedAddonID = id
            DesignTokens.Haptics.selection()
            Task { await model.load(store: store, client: HTTPClient(), force: true) }
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
        let items: [MediaItem]
    }

    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var searchResults: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published var selectedAddonID: String?

    func clearSearch() {
        searchResults = []
    }

    func load(store: StremioAddonStore, client: any HTTPClientProtocol, force: Bool = false) async {
        guard !isLoading || force else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }

        let addons = store.catalogAddons.filter { addon in
            guard let selectedAddonID else { return true }
            return addon.id == selectedAddonID
        }

        var built: [Shelf] = []
        for addon in addons {
            let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
            let catalogs = addon.catalogs
                .filter { ["movie", "series", "anime", "channel"].contains($0.type) }
                .prefix(6)
            for catalog in catalogs {
                do {
                    let metas = try await addonClient.catalog(type: catalog.type, id: catalog.id)
                    let items = metas.prefix(24).map {
                        $0.asMediaItem(providerID: "stremio:\(addon.id)")
                    }
                    guard !items.isEmpty else { continue }
                    let title = "\(addon.name) · \(catalog.displayName)"
                    built.append(
                        Shelf(id: "\(addon.id):\(catalog.stableID)", title: title, items: Array(items))
                    )
                } catch {
                    continue
                }
            }
        }
        shelves = built
        if built.isEmpty {
            message = store.catalogAddons.isEmpty
                ? nil
                : "Catalogs didn’t return items. Check plugin health in Manage plugins."
        }
    }

    func search(query: String, store: StremioAddonStore, client: any HTTPClientProtocol) async {
        var results: [MediaItem] = []
        var seen = Set<String>()
        for addon in store.catalogAddons {
            let searchable = addon.catalogs.filter(\.supportsSearch)
            let targets = searchable.isEmpty
                ? Array(addon.catalogs.prefix(2))
                : Array(searchable.prefix(3))
            let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
            for catalog in targets {
                do {
                    let metas = try await addonClient.catalog(
                        type: catalog.type,
                        id: catalog.id,
                        extras: ["search": query]
                    )
                    for meta in metas.prefix(20) {
                        let item = meta.asMediaItem(providerID: "stremio:\(addon.id)")
                        if seen.insert(item.id).inserted {
                            results.append(item)
                        }
                    }
                } catch {
                    continue
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
    @ObservedObject private var store = StremioAddonStore.shared
    @StateObject private var model = StremioCatalogHubModel()
    var onDetails: (MediaItem) -> Void

    var body: some View {
        Group {
            if !model.shelves.isEmpty {
                ForEach(model.shelves.prefix(4)) { shelf in
                    MediaShelfView(
                        title: shelf.title,
                        items: shelf.items,
                        onDetails: onDetails
                    )
                }
            }
        }
        .task(id: store.enabledAddons.map(\.id)) {
            await model.load(store: store, client: HTTPClient())
        }
    }
}
