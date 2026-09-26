import SwiftUI

/// Lightweight community addon browser (P6) — curated catalogs beyond presets.
struct StremioAddonStoreBrowserView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @State private var banner: String?

    private var community: [StremioCuratedAddon] {
        StremioCuratedCatalog.allPresets
    }

    var body: some View {
        List {
            Section {
                Text("Browse curated Stremio community addons. Prefer Install with Debrid for torrent indexes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(AppTheme.elevatedSurface)

            Section("Catalog") {
                ForEach(community.filter { $0.kind == .catalog || $0.kind == .mixed }) { item in
                    row(item)
                }
            }
            .listRowBackground(AppTheme.surface)

            Section("Stream") {
                ForEach(community.filter { $0.kind == .stream }) { item in
                    row(item)
                }
            }
            .listRowBackground(AppTheme.surface)

            Section("Subtitles") {
                ForEach(community.filter { $0.kind == .subtitles }) { item in
                    row(item)
                }
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
    }

    private func row(_ curated: StremioCuratedAddon) -> some View {
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
}
