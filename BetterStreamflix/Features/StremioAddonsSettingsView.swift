import SwiftUI
import UniformTypeIdentifiers

struct StremioAddonsSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @State private var installDraft = ""
    @State private var isInstalling = false
    @State private var banner: String?
    @State private var confirmRemove: InstalledStremioAddon?
    @State private var isRefreshingHealth = false
    @State private var presetFilter: StremioAddonKind? = nil
    @FocusState private var installFocused: Bool

    var body: some View {
        List {
            heroSection
            playbackSection
            installSection
            if !store.addons.isEmpty {
                installedSection
                healthSection
            }
            seedSection
            popularSection
        }
        .scrollContentBackground(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("Stremio")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.probePopularPresets()
        }
        .confirmationDialog(
            "Remove addon?",
            isPresented: Binding(
                get: { confirmRemove != nil },
                set: { if !$0 { confirmRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let addon = confirmRemove {
                Button("Remove \(addon.name)", role: .destructive) {
                    store.remove(addon)
                    confirmRemove = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        }
    }

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Community addons")
                    .font(DesignTokens.Typography.shelfTitle)
                    .foregroundStyle(AppTheme.primaryText)
                Text("Install real remote Stremio manifests — catalogs, streams, and subtitles — the same protocol Stremio uses. App-bundled scrapers stay out of this list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    metricChip(title: "Installed", value: "\(store.addons.count)")
                    metricChip(title: "Streams", value: "\(store.streamAddons.count)")
                    metricChip(title: "Catalogs", value: "\(store.catalogAddons.count)")
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
            )
        }
    }

    private var playbackSection: some View {
        Section {
            Toggle(isOn: playbackBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use addons for playback")
                    Text("Query enabled stream addons and feed HTTP results into the native player alongside your language providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(environment.theme.accent)
        } header: {
            Text("Playback")
        } footer: {
            Text("Playback language still gates German / English / … scrapers. Stremio addons are protocol sources and can run without Core anime resolvers.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var installSection: some View {
        Section {
            TextField("https://…/manifest.json or stremio://…", text: $installDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($installFocused)
                .submitLabel(.go)
                .onSubmit { Task { await installFromDraft() } }

            Button {
                Task { await installFromDraft() }
            } label: {
                HStack {
                    if isInstalling {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text(isInstalling ? "Installing…" : "Install from URL")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .disabled(isInstalling || installDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .tint(environment.theme.accent)

            if let banner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(bannerHasError ? Color.red : environment.theme.accentBright)
            }
        } header: {
            Text("Install")
        } footer: {
            Text("Paste a manifest URL, stremio:// link, or a shared installer string. Only remote community addons appear here.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var installedSection: some View {
        Section {
            ForEach(store.addons) { addon in
                addonRow(addon)
            }
            .onMove(perform: store.move)
            .onDelete { indexSet in
                for index in indexSet.sorted(by: >) {
                    store.remove(store.addons[index])
                }
            }
        } header: {
            HStack {
                Text("Installed plugins")
                Spacer()
                EditButton()
                    .font(.caption.weight(.semibold))
            }
        } footer: {
            Text("Drag to set discovery priority. Disable to keep an addon without querying it.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var healthSection: some View {
        Section {
            Button {
                Task { await refreshHealth() }
            } label: {
                Label(
                    isRefreshingHealth ? "Checking…" : "Check all addon health",
                    systemImage: "heart.text.square"
                )
            }
            .disabled(isRefreshingHealth)
        }
        .listRowBackground(AppTheme.surface)
    }

    private var seedSection: some View {
        Section {
            ForEach(StremioCuratedCatalog.seedDefaults) { curated in
                curatedRow(curated, emphasize: true)
            }
        } header: {
            Text("Recommended")
        } footer: {
            Text("Trusted remote manifests that respond over HTTPS. Seeded on first launch.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var popularSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(nil, title: "All")
                    ForEach([StremioAddonKind.stream, .catalog, .subtitles, .mixed], id: \.self) { kind in
                        filterChip(kind, title: kind.title)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

            ForEach(filteredPopular) { curated in
                curatedRow(curated, emphasize: false)
            }
        } header: {
            Text("Popular presets")
        } footer: {
            Text("Torrentio and mirrors can be blocked on some networks — install still works when the host is reachable, otherwise paste a working URL.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var filteredPopular: [StremioCuratedAddon] {
        guard let presetFilter else { return StremioCuratedCatalog.popularPresets }
        return StremioCuratedCatalog.popularPresets.filter { $0.kind == presetFilter }
    }

    private var playbackBinding: Binding<Bool> {
        Binding(
            get: { store.isPlaybackEnabled },
            set: {
                store.isPlaybackEnabled = $0
                DesignTokens.Haptics.selection()
            }
        )
    }

    private var bannerHasError: Bool {
        guard let banner else { return false }
        let lower = banner.lowercased()
        return lower.contains("couldn’t") || lower.contains("couldn't")
            || lower.contains("invalid") || lower.contains("failed")
            || lower.contains("blocked") || lower.contains("unreachable")
            || lower.contains("not a stremio")
    }

    @ViewBuilder
    private func addonRow(_ addon: InstalledStremioAddon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                addonGlyph(addon.name, kind: addon.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(addon.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(addon.capabilitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        healthChip(addon.health)
                        if let ms = addon.latencyMS {
                            Text("\(ms) ms")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let version = addon.version {
                            Text("v\(version)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { addon.isEnabled },
                    set: { store.setEnabled(addon, enabled: $0) }
                ))
                .labelsHidden()
                .tint(environment.theme.accent)
            }
            if let detail = addon.detail?.nilIfEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Button("Health") {
                    Task { await store.refreshHealth(for: addon) }
                }
                .font(.caption.weight(.semibold))
                Spacer()
                Button("Remove", role: .destructive) {
                    confirmRemove = addon
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private func curatedRow(_ curated: StremioCuratedAddon, emphasize: Bool) -> some View {
        let installed = store.isInstalled(curated: curated)
        let reachability = store.presetReachability[curated.id]
        return HStack(alignment: .top, spacing: 12) {
            addonGlyph(curated.name, kind: curated.kind)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(curated.name)
                        .font(.subheadline.weight(.semibold))
                    if curated.isPopularOptional, let reachability {
                        healthChip(reachability)
                    }
                }
                Text(curated.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(curated.capabilities)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(environment.theme.accentBright)
                if let note = curated.networkNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if installed {
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button(emphasize ? "Install" : "Add") {
                    Task { await installCurated(curated) }
                }
                .buttonStyle(.borderedProminent)
                .tint(environment.theme.accent)
                .font(.caption.weight(.semibold))
                .disabled(reachability == .unreachable && curated.isPopularOptional)
            }
        }
        .padding(.vertical, 2)
        .opacity(reachability == .unreachable && !installed && curated.isPopularOptional ? 0.72 : 1)
    }

    private func filterChip(_ kind: StremioAddonKind?, title: String) -> some View {
        let selected = presetFilter == kind
        return Button {
            presetFilter = kind
            DesignTokens.Haptics.selection()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffectWithFallback(in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    selected ? environment.theme.accentBright.opacity(0.9) : Color.clear,
                    lineWidth: 1.2
                )
        }
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(AppTheme.primaryText)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func addonGlyph(_ name: String, kind: StremioAddonKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [environment.theme.accentBright, environment.theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(String(name.prefix(1)).uppercased())
                .font(.headline.weight(.bold))
                .foregroundStyle(Color(hex: 0x11141C))
        }
        .frame(width: 40, height: 40)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: kindIcon(kind))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .padding(3)
                .background(AppTheme.surface, in: Circle())
                .offset(x: 4, y: 4)
        }
    }

    private func kindIcon(_ kind: StremioAddonKind) -> String {
        switch kind {
        case .catalog: "square.stack.3d.up"
        case .stream: "play.circle"
        case .subtitles: "captions.bubble"
        case .mixed: "puzzlepiece.extension"
        }
    }

    private func healthChip(_ health: StremioAddonHealth) -> some View {
        Text(health.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(healthColor(health).opacity(0.18), in: Capsule())
            .foregroundStyle(healthColor(health))
    }

    private func healthColor(_ health: StremioAddonHealth) -> Color {
        switch health {
        case .healthy: Color(hex: 0x3DDC97)
        case .degraded: Color(hex: 0xF0C24B)
        case .unreachable: Color(hex: 0xFF6B6B)
        case .unknown: Color.secondary
        }
    }

    private func installFromDraft() async {
        let raw = installDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let addon = try await store.install(from: raw)
            installDraft = ""
            installFocused = false
            banner = "Installed \(addon.name)"
            DesignTokens.Haptics.primaryAction()
        } catch {
            banner = error.localizedDescription.nilIfEmpty
                ?? "Couldn’t install addon — check the manifest URL"
        }
    }

    private func installCurated(_ curated: StremioCuratedAddon) async {
        do {
            try await store.installCurated(curated)
            banner = "Installed \(curated.name)"
            DesignTokens.Haptics.primaryAction()
        } catch {
            if curated.isPopularOptional {
                banner = "\(curated.name) unreachable on this network — paste a working mirror URL"
            } else {
                banner = "Couldn’t install \(curated.name)"
            }
        }
    }

    private func refreshHealth() async {
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }
        await store.refreshAllHealth()
        await store.probePopularPresets()
        banner = "Health check finished"
        DesignTokens.Haptics.selection()
    }
}

struct StremioAddonsSettingsLink: View {
    @ObservedObject private var store = StremioAddonStore.shared

    var body: some View {
        NavigationLink {
            StremioAddonsSettingsView()
        } label: {
            HStack {
                Label("Stremio", systemImage: "puzzlepiece.extension.fill")
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let count = store.addons.count
        if count == 0 { return "Install plugins" }
        let active = store.enabledAddons.count
        return "\(active)/\(count) plugins"
    }
}
