import SwiftUI

struct StremioCatalogHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @StateObject private var model = StremioCatalogHubModel()
    @State private var selectedItem: MediaItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageTitleHeader(title: "Addons", ignoresTopSafeArea: true)

                introCard
                    .padding(.horizontal, 20)

                if store.catalogAddons.isEmpty {
                    emptyState
                        .padding(.horizontal, 20)
                } else {
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
        .task(id: store.addons.map(\.id)) {
            await model.load(store: store, client: HTTPClient())
        }
        .refreshable {
            await model.load(store: store, client: HTTPClient(), force: true)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stremio ecosystem")
                .font(DesignTokens.Typography.shelfTitle)
            Text("Browse catalogs from your installed addons. Streams resolve through the same native player as language providers.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                StremioAddonsSettingsView()
            } label: {
                Label("Manage addons", systemImage: "slider.horizontal.3")
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No catalog addons yet")
                .font(.headline.weight(.semibold))
            Text("Install Cinemeta or another catalog addon to fill this space with Stremio shelves.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                StremioAddonsSettingsView()
            } label: {
                Text("Open addon settings")
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
}

@MainActor
final class StremioCatalogHubModel: ObservableObject {
    struct Shelf: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [MediaItem]
    }

    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    func load(store: StremioAddonStore, client: any HTTPClientProtocol, force: Bool = false) async {
        guard !isLoading || force else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }

        var built: [Shelf] = []
        for addon in store.catalogAddons {
            let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
            let catalogs = addon.catalogs
                .filter { $0.type == "movie" || $0.type == "series" }
                .prefix(4)
            for catalog in catalogs {
                do {
                    let metas = try await addonClient.catalog(type: catalog.type, id: catalog.id)
                    let items = metas.prefix(24).map {
                        $0.asMediaItem(providerID: "stremio:\(addon.id)")
                    }
                    guard !items.isEmpty else { continue }
                    let title = "\(addon.name) · \(catalog.displayName)"
                    built.append(Shelf(id: "\(addon.id):\(catalog.stableID)", title: title, items: Array(items)))
                } catch {
                    continue
                }
            }
        }
        shelves = built
        if built.isEmpty {
            message = store.catalogAddons.isEmpty
                ? nil
                : "Catalogs didn’t return items. Check addon health in Settings."
        }
    }
}

/// Home shelves pulled from enabled Stremio catalog addons.
struct StremioHomeShelvesView: View {
    @ObservedObject private var store = StremioAddonStore.shared
    @StateObject private var model = StremioCatalogHubModel()
    var onDetails: (MediaItem) -> Void

    var body: some View {
        Group {
            if !model.shelves.isEmpty {
                ForEach(model.shelves.prefix(3)) { shelf in
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
