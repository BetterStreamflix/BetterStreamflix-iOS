import SwiftUI

/// Community addon browser — editor’s picks plus remote community catalog endpoints.
struct StremioAddonStoreBrowserView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @ObservedObject private var debrid = StremioDebridStore.shared
    @State private var banner: String?
    @State private var remoteEntries: [RemoteAddonEntry] = []
    @State private var isLoadingRemote = false
    @State private var remoteError: String?
    @State private var searchDraft = ""

    private var editorsPicks: [StremioCuratedAddon] {
        StremioCuratedCatalog.allPresets
    }

    private var filteredRemote: [RemoteAddonEntry] {
        let query = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return remoteEntries }
        return remoteEntries.filter {
            $0.name.lowercased().contains(query)
                || ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        List {
            Section {
                Text("Editor’s picks stay curated for reliability. Community catalogs load from public Stremio addon lists when reachable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(environment.theme.accentBright)
                    TextField("Search community", text: $searchDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .listRowBackground(AppTheme.elevatedSurface)

            Section("Editor’s picks") {
                ForEach(editorsPicks) { item in
                    curatedRow(item)
                }
            }
            .listRowBackground(AppTheme.surface)

            Section {
                if isLoadingRemote {
                    ProgressView("Loading community catalogs…")
                } else if let remoteError {
                    Text(remoteError)
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0xFF6B6B))
                    Button("Retry") { Task { await loadRemote() } }
                        .font(.caption.weight(.semibold))
                } else if filteredRemote.isEmpty {
                    Text("No community entries loaded. Editor’s picks above still work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRemote) { entry in
                        remoteRow(entry)
                    }
                }
            } header: {
                Text("Community")
            }
            .listRowBackground(AppTheme.surface)

            if let banner {
                Section {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(environment.theme.accentBright)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("Addon Store")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRemote() }
        .refreshable { await loadRemote() }
    }

    private func curatedRow(_ curated: StremioCuratedAddon) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(curated.name)
                    .font(.subheadline.weight(.semibold))
                Text(curated.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isInstalled(curated: curated) {
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if StremioCuratedCatalog.isDebridStreamPreset(curated), debrid.hasAnyToken {
                Button("Debrid") {
                    Task {
                        do {
                            try await store.installCuratedWithDebrid(curated)
                            banner = "Installed \(curated.name) with Debrid"
                        } catch {
                            banner = "Couldn’t install \(curated.name)"
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(environment.theme.accent)
            } else {
                Button("Add") {
                    Task {
                        do {
                            try await store.installCurated(curated)
                            banner = "Installed \(curated.name)"
                        } catch {
                            banner = "Couldn’t install \(curated.name)"
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(environment.theme.accent)
            }
        }
    }

    private func remoteRow(_ entry: RemoteAddonEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.subheadline.weight(.semibold))
                if let description = entry.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(entry.manifestURL.host ?? entry.manifestURL.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if store.isInstalled(manifestURL: entry.manifestURL) {
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    Task {
                        do {
                            _ = try await store.install(from: entry.manifestURL.absoluteString, curated: false)
                            banner = "Installed \(entry.name)"
                        } catch {
                            banner = "Couldn’t install \(entry.name)"
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(environment.theme.accent)
            }
        }
    }

    private func loadRemote() async {
        isLoadingRemote = true
        remoteError = nil
        defer { isLoadingRemote = false }
        // Public community lists used by Stremio ecosystem browsers.
        let endpoints = [
            "https://api.strem.io/addonscollection.json",
            "https://stremio-addons.com/catalog.json",
        ]
        var collected: [RemoteAddonEntry] = []
        var seen = Set<String>()
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let response = try await HTTPClient().data(for: URLRequest(url: url))
                let entries = RemoteAddonEntry.parse(from: response.data)
                for entry in entries where seen.insert(entry.id).inserted {
                    collected.append(entry)
                }
            } catch {
                continue
            }
        }
        if collected.isEmpty {
            remoteError = "Community catalogs unreachable right now."
        }
        remoteEntries = collected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct RemoteAddonEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let manifestURL: URL

    static func parse(from data: Data) -> [RemoteAddonEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows: [[String: Any]] = []
        if let array = json as? [[String: Any]] {
            rows = array
        } else if let dict = json as? [String: Any] {
            if let addons = dict["addons"] as? [[String: Any]] {
                rows = addons
            } else if let results = dict["results"] as? [[String: Any]] {
                rows = results
            }
        }
        return rows.compactMap { row in
            let manifestRaw = (row["manifestUrl"] as? String)
                ?? (row["transportUrl"] as? String)
                ?? (row["url"] as? String)
                ?? ((row["manifest"] as? [String: Any])?["url"] as? String)
            guard let manifestRaw,
                  let manifestURL = StremioManifestURL.parse(manifestRaw) else { return nil }
            let manifest = row["manifest"] as? [String: Any]
            let name = (row["name"] as? String)
                ?? (manifest?["name"] as? String)
                ?? manifestURL.host
                ?? "Addon"
            let detail = (row["description"] as? String) ?? (manifest?["description"] as? String)
            let id = (row["id"] as? String)
                ?? (manifest?["id"] as? String)
                ?? manifestURL.absoluteString
            return RemoteAddonEntry(id: id, name: name, description: detail, manifestURL: manifestURL)
        }
    }
}
