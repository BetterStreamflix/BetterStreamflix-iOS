import SwiftUI

struct StremioAddonsSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @State private var installDraft = ""
    @State private var isInstalling = false
    @State private var banner: String?
    @State private var confirmRemove: InstalledStremioAddon?
    @State private var isRefreshingHealth = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: playbackBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use addons for playback")
                        Text("Resolves HTTP streams from enabled stream addons into the native player. Works alongside your playback language providers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(environment.theme.accent)

                LabeledContent("Installed") {
                    Text("\(store.addons.count)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Stream addons") {
                    Text("\(store.streamAddons.count) active")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Playback language still selects German / English / … scrapers. Stremio addons are protocol sources — enable them here without turning on every Core anime resolver.")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                TextField("https://…/manifest.json", text: $installDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button {
                    Task { await installFromDraft() }
                } label: {
                    if isInstalling {
                        ProgressView()
                    } else {
                        Label("Install addon", systemImage: "plus.circle.fill")
                    }
                }
                .disabled(isInstalling || installDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let banner {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(bannerHasError ? Color.red : environment.theme.accentBright)
                }
            } header: {
                Text("Install")
            } footer: {
                Text("Paste a Stremio manifest URL or stremio:// link. Community addons are third-party services — BetterStreamflix does not host media.")
            }
            .listRowBackground(AppTheme.surface)

            if !store.addons.isEmpty {
                Section {
                    ForEach(store.addons) { addon in
                        addonRow(addon)
                    }
                    .onMove(perform: store.move)
                    .onDelete { indexSet in
                        for index in indexSet {
                            store.remove(store.addons[index])
                        }
                    }
                } header: {
                    HStack {
                        Text("Installed addons")
                        Spacer()
                        EditButton()
                            .font(.caption.weight(.semibold))
                    }
                } footer: {
                    Text("Drag to reorder discovery priority. Disable to keep an addon installed without querying it.")
                }
                .listRowBackground(AppTheme.surface)

                Section {
                    Button {
                        Task { await refreshHealth() }
                    } label: {
                        if isRefreshingHealth {
                            ProgressView()
                        } else {
                            Label("Check addon health", systemImage: "heart.text.square")
                        }
                    }
                    .disabled(isRefreshingHealth)
                }
                .listRowBackground(AppTheme.surface)
            }

            Section {
                ForEach(StremioCuratedCatalog.defaults) { curated in
                    curatedRow(curated)
                }
            } header: {
                Text("Curated defaults")
            } footer: {
                Text("These manifests are known to respond over HTTPS. Install any that aren’t already present.")
            }
            .listRowBackground(AppTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("Stremio Addons")
        .navigationBarTitleDisplayMode(.inline)
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
        return banner.localizedCaseInsensitiveContains("couldn’t")
            || banner.localizedCaseInsensitiveContains("couldn't")
            || banner.localizedCaseInsensitiveContains("invalid")
            || banner.localizedCaseInsensitiveContains("failed")
    }

    @ViewBuilder
    private func addonRow(_ addon: InstalledStremioAddon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                addonGlyph(addon.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(addon.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(capabilityLine(for: addon))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        healthChip(addon.health)
                        if let version = addon.version {
                            Text("v\(version)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if addon.isCurated {
                            Text("Curated")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(environment.theme.accentBright)
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
                    .lineLimit(3)
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

    private func curatedRow(_ curated: StremioCuratedAddon) -> some View {
        let installed = store.isInstalled(manifestURL: curated.manifestURL)
        return HStack(alignment: .top, spacing: 12) {
            addonGlyph(curated.name)
            VStack(alignment: .leading, spacing: 4) {
                Text(curated.name)
                    .font(.subheadline.weight(.semibold))
                Text(curated.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(curated.capabilities)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(environment.theme.accentBright)
            }
            Spacer(minLength: 0)
            if installed {
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button("Install") {
                    Task {
                        do {
                            try await store.installCurated(curated)
                            banner = "Installed \(curated.name)"
                            DesignTokens.Haptics.primaryAction()
                        } catch {
                            banner = "Couldn’t install \(curated.name)"
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(environment.theme.accent)
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
    }

    private func addonGlyph(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.headline.weight(.bold))
            .foregroundStyle(Color(hex: 0x11141C))
            .frame(width: 40, height: 40)
            .background(
                LinearGradient(
                    colors: [environment.theme.accentBright, environment.theme.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
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

    private func capabilityLine(for addon: InstalledStremioAddon) -> String {
        var parts: [String] = []
        if addon.supportsCatalog { parts.append("Catalog") }
        if addon.supportsMeta { parts.append("Meta") }
        if addon.supportsStream { parts.append("Stream") }
        if addon.supportsSubtitles { parts.append("Subtitles") }
        return parts.isEmpty ? "No resources declared" : parts.joined(separator: " · ")
    }

    private func installFromDraft() async {
        let raw = installDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let addon = try await store.install(from: raw)
            installDraft = ""
            banner = "Installed \(addon.name)"
            DesignTokens.Haptics.primaryAction()
        } catch {
            banner = "Couldn’t install addon — check the manifest URL"
        }
    }

    private func refreshHealth() async {
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }
        await store.refreshAllHealth()
        banner = "Health check finished"
        DesignTokens.Haptics.selection()
    }
}

/// Compact entry used from Settings form.
struct StremioAddonsSettingsLink: View {
    @ObservedObject private var store = StremioAddonStore.shared

    var body: some View {
        NavigationLink {
            StremioAddonsSettingsView()
        } label: {
            HStack {
                Label("Stremio Addons", systemImage: "puzzlepiece.extension.fill")
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let count = store.addons.count
        if count == 0 { return "None" }
        let active = store.enabledAddons.count
        return "\(active)/\(count)"
    }
}
