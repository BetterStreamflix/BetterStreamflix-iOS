import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Full Stremio plugin manager — Liquid Glass, Debrid-aware presets, logos, config flow.
struct StremioAddonsSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @ObservedObject private var debrid = StremioDebridStore.shared
    @State private var installDraft = ""
    @State private var isInstalling = false
    @State private var banner: String?
    @State private var confirmRemove: InstalledStremioAddon?
    @State private var isRefreshingHealth = false
    @State private var presetFilter: StremioAddonKind? = nil
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showProfileImporter = false
    @State private var exportDocument: StremioAddonListDocument?
    @State private var exportFilename = "betterstreamflix-stremio-addons.json"
    @State private var configureURL: URL?
    @FocusState private var installFocused: Bool

    var body: some View {
        List {
            heroSection
            onboardingSection
            debridSection
            catalogPrefsSection
            playbackSection
            installSection
            if !store.addons.isEmpty {
                installedSection
                healthSection
                toolsSection
            }
            if !store.lastSeedFailures.isEmpty {
                Section {
                    ForEach(store.lastSeedFailures, id: \.self) { failure in
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0xF0C24B))
                    }
                    Button("Retry recommended seeds") {
                        Task {
                            await store.seedCuratedDefaults()
                            banner = store.lastSeedFailures.isEmpty
                                ? "Recommended addons installed"
                                : "Some seeds still failed — check network"
                        }
                    }
                    .font(.caption.weight(.semibold))
                } header: {
                    Text("Seed warnings")
                }
                .listRowBackground(AppTheme.surface)
            }
            seedSection
            popularSection
            mirrorSection
            storeSection
        }
        .scrollContentBackground(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("Stremio")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.probePopularPresets()
            if let pending = StremioInstallDeepLink.peekPending() {
                installDraft = pending
                banner = "Ready to install from link"
            }
        }
        .fullScreenCover(item: Binding(
            get: { configureURL.map(IdentifiableURL.init) },
            set: { configureURL = $0?.url }
        )) { item in
            StremioConfigureWebView(
                startURL: item.url,
                onInstalled: { addon in
                    configureURL = nil
                    banner = "Configured \(addon.name)"
                },
                onCancel: { configureURL = nil }
            )
            .environmentObject(environment)
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
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { _ in }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            Task { await importList(result) }
        }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.json]) { result in
            Task { await importProfile(result) }
        }
    }

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Community addons")
                    .font(DesignTokens.Typography.shelfTitle)
                    .foregroundStyle(AppTheme.primaryText)
                Text("Install real remote Stremio manifests — catalogs, streams, and subtitles. App-bundled HTTP stays under Core, never in this list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    metricChip(title: "Installed", value: "\(store.addons.count)")
                    metricChip(title: "Streams", value: "\(store.streamAddons.count)")
                    metricChip(title: "Catalogs", value: "\(store.catalogAddons.count)")
                }
                if debrid.hasAnyToken {
                    Text("Debrid ready · \(debrid.preferredProfile?.service.shortTitle ?? "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(environment.theme.accentBright)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
            )
        }
    }

    private var onboardingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                labeledHint(
                    title: "Stremio plugins",
                    text: "Remote manifests you install here (Cinemeta, Torrentio+Debrid, OpenSubtitles v3…)."
                )
                labeledHint(
                    title: "Language scrapers",
                    text: "German / English / … sites gated by the playback language picker."
                )
                labeledHint(
                    title: "Built-in HTTP",
                    text: "App-bundled Core source — not a Stremio plugin."
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("How sources differ")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var debridSection: some View {
        Section {
            NavigationLink {
                StremioDebridSettingsView()
            } label: {
                HStack {
                    Label("Debrid & performance", systemImage: "key.horizontal.fill")
                    Spacer()
                    Text(debrid.hasAnyToken ? "Configured" : "Add token")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Torrentio, Comet, MediaFusion, and AIOStreams need a debrid token for in-app playback. Torrents alone never play on iOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !store.addonsWithUpdates.isEmpty {
                Text("\(store.addonsWithUpdates.count) addon update\(store.addonsWithUpdates.count == 1 ? "" : "s") available")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(environment.theme.accentBright)
            }
        } header: {
            Text("Debrid")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var catalogPrefsSection: some View {
        Section {
            Toggle("Show adult catalogs", isOn: Binding(
                get: { debrid.adultCatalogsOptIn },
                set: { debrid.adultCatalogsOptIn = $0 }
            ))
        } header: {
            Text("Catalog")
        } footer: {
            Text("Adult-marked addons stay hidden from shelves until you opt in.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var playbackSection: some View {
        Section {
            Toggle(isOn: playbackBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use addons for playback")
                    Text("Query enabled Stremio stream addons and feed HTTP results into NativePlayer alongside language providers.")
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
            Text("Paste a manifest URL, stremio:// link, betterstreamflix://install?url=…, or a shared installer string. Configurable addons: open Configure in-app to finish setup and auto-capture the manifest.")
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

    private var toolsSection: some View {
        Section {
            Button {
                if let data = try? store.exportAddonListJSON() {
                    exportFilename = "betterstreamflix-stremio-addons.json"
                    exportDocument = StremioAddonListDocument(data: data)
                    showExporter = true
                }
            } label: {
                Label("Export addon list", systemImage: "square.and.arrow.up")
            }
            Button {
                if let data = try? StremioProfileExport.exportJSON(debrid: debrid, store: store) {
                    exportFilename = "betterstreamflix-stremio-profile.json"
                    exportDocument = StremioAddonListDocument(data: data)
                    showExporter = true
                }
            } label: {
                Label("Export Stremio profile (no tokens)", systemImage: "person.crop.circle.badge.checkmark")
            }
            Button {
                showImporter = true
            } label: {
                Label("Import addon list", systemImage: "square.and.arrow.down")
            }
            Button {
                showProfileImporter = true
            } label: {
                Label("Import Stremio profile", systemImage: "square.and.arrow.down.on.square")
            }
            if let first = store.streamAddons.first {
                ShareLink(
                    item: first.manifestURL.absoluteString,
                    subject: Text("Stremio addon"),
                    message: Text("Install \(first.name) in BetterStreamflix")
                ) {
                    Label("Share a stream addon URL", systemImage: "square.and.arrow.up.on.square")
                }
            }
            Button("Clear catalog cache") {
                Task {
                    await StremioAddonCache.shared.clear()
                    await StremioStreamSessionCache.shared.clear()
                    banner = "Caches cleared"
                }
            }
            Button("Copy last resolve diagnostics") {
                let diag = StremioResolveDiagnosticsStore.current()
                let text = """
                playable=\(diag.playableHTTP) torrents=\(diag.skippedTorrent) external=\(diag.skippedExternal) youtube=\(diag.skippedYouTube) failed=\(diag.failedAddons) queried=\(diag.queriedAddons) debrid=\(diag.debridConfigured)
                \(diag.userFacingSummary)
                \(diag.perAddon.map(\.chipTitle).joined(separator: " · "))
                """
                UIPasteboard.general.string = text
                banner = "Diagnostics copied"
            }
        } header: {
            Text("Backup & share")
        } footer: {
            Text("Addon lists and profiles never include Debrid tokens. Profiles carry ranking prefs, filters, favorites, and manifest URLs.")
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
            Text("Stream presets that index torrents need Debrid for playback. WatchHub opens external store links. Mirror paste works when Cloudflare blocks the primary host.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var mirrorSection: some View {
        Section {
            ForEach(StremioCuratedCatalog.torrentioMirrorHosts, id: \.self) { host in
                Button {
                    installDraft = "https://\(host)/manifest.json"
                    banner = "Mirror pasted — tap Install (or Install with Debrid after saving a token)"
                } label: {
                    Label(host, systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Torrentio mirrors")
        } footer: {
            Text("Documented fallback hosts when torrentio.strem.fun is unreachable.")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var storeSection: some View {
        Section {
            NavigationLink {
                StremioAddonStoreBrowserView()
            } label: {
                Label("Browse addon store", systemImage: "storefront")
            }
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
            || lower.contains("not a stremio") || lower.contains("add a debrid")
    }

    @ViewBuilder
    private func addonRow(_ addon: InstalledStremioAddon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                addonArtwork(url: addon.logoURL, name: addon.name, kind: addon.kind)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(addon.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        if addon.updateAvailable {
                            badge("Update", color: environment.theme.accentBright)
                        }
                        if addon.isAdult {
                            badge("18+", color: Color(hex: 0xFF6B6B))
                        }
                        if addon.isP2P {
                            badge("P2P", color: Color(hex: 0xF0C24B))
                        }
                        if let bound = StremioDebridURLBuilder.boundService(in: addon.manifestURL) {
                            badge(bound.shortTitle, color: environment.theme.accent)
                        }
                    }
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
                        if let smoke = addon.streamSmokeOK {
                            Text(smoke ? "Stream OK" : "Stream fail")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(smoke ? Color(hex: 0x3DDC97) : Color(hex: 0xFF6B6B))
                        }
                    }
                    if addon.needsConfigurationWarning {
                        Text("Configuration required — open Configure in-app to finish setup.")
                            .font(.caption2)
                            .foregroundStyle(Color(hex: 0xF0C24B))
                    }
                    if addon.updateAvailable, let remote = addon.remoteVersion {
                        Text("Update available: v\(remote)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(environment.theme.accentBright)
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
                if addon.supportsStream {
                    Button("Smoke") {
                        Task { await store.smokeTestStream(for: addon) }
                    }
                    .font(.caption.weight(.semibold))
                }
                if addon.updateAvailable {
                    Button("Update") {
                        Task {
                            do {
                                try await store.applyPendingUpdate(for: addon)
                                banner = "Updated \(addon.name)"
                            } catch {
                                banner = error.localizedDescription
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                if let configure = addon.configurePageURL {
                    Button("Configure") {
                        configureURL = configure
                    }
                    .font(.caption.weight(.semibold))
                }
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
        let needsDebrid = StremioCuratedCatalog.isDebridStreamPreset(curated)
        return HStack(alignment: .top, spacing: 12) {
            addonArtwork(url: nil, name: curated.name, kind: curated.kind)
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
                VStack(spacing: 6) {
                    if needsDebrid {
                        Button("With Debrid") {
                            Task { await installCuratedWithDebrid(curated) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(environment.theme.accent)
                        .font(.caption.weight(.semibold))
                        .disabled(!debrid.hasAnyToken || (reachability == .unreachable && curated.isPopularOptional))
                        Button("Configure") {
                            configureURL = StremioDebridURLBuilder.configurePageURL(from: curated.manifestURL)
                        }
                        .buttonStyle(.bordered)
                        .tint(environment.theme.accent)
                        .font(.caption.weight(.semibold))
                    }
                    Button(emphasize ? "Install" : (needsDebrid ? "Bare" : "Add")) {
                        Task { await installCurated(curated) }
                    }
                    .buttonStyle(.bordered)
                    .tint(environment.theme.accent)
                    .font(.caption.weight(.semibold))
                    .disabled(reachability == .unreachable && curated.isPopularOptional)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(reachability == .unreachable && !installed && curated.isPopularOptional ? 0.72 : 1)
    }

    private func labeledHint(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

    private func addonArtwork(url: URL?, name: String, kind: StremioAddonKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [environment.theme.accentBright, environment.theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Text(String(name.prefix(1)).uppercased())
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Color(hex: 0x11141C))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(hex: 0x11141C))
            }
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
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

    private func installCuratedWithDebrid(_ curated: StremioCuratedAddon) async {
        do {
            try await store.installCuratedWithDebrid(curated, debrid: debrid)
            banner = "Installed \(curated.name) with \(debrid.preferredProfile?.service.shortTitle ?? "Debrid")"
            DesignTokens.Haptics.primaryAction()
        } catch {
            // Fall back to in-app Configure when one-tap URL isn’t available (MediaFusion, etc.).
            configureURL = StremioDebridURLBuilder.configurePageURL(from: curated.manifestURL)
            banner = error.localizedDescription.nilIfEmpty
                ?? "Open Configure to finish \(curated.name)"
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

    private func importList(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                banner = "Couldn’t access import file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            let count = try await store.importAddonListJSON(data)
            banner = "Imported \(count) addon\(count == 1 ? "" : "s")"
        } catch {
            banner = "Import failed"
        }
    }

    private func importProfile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else {
                banner = "Couldn’t access import file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            let count = try await StremioProfileExport.importJSON(data, debrid: debrid, store: store)
            banner = "Profile imported · \(count) addon\(count == 1 ? "" : "s")"
        } catch {
            banner = "Profile import failed"
        }
    }
}

struct StremioAddonListDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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

/// Holds a pending install URL from `betterstreamflix://` / `stremio://` deep links.
enum StremioInstallDeepLink {
    private static let key = "stremio.install.pendingURL"
    static let didReceiveNotification = Notification.Name("stremio.install.didReceive")

    static func peekPending() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func queue(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: key)
        NotificationCenter.default.post(name: didReceiveNotification, object: raw)
    }

    static func consumePending() -> String? {
        let value = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }

    static func handle(url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "stremio" {
            if let parsed = StremioManifestURL.parse(url.absoluteString) {
                queue(parsed.absoluteString)
                return true
            }
        }
        if scheme == "betterstreamflix" {
            if url.host?.lowercased() == "install" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let raw = components?.queryItems?.first(where: { $0.name == "url" })?.value,
                   let parsed = StremioManifestURL.parse(raw) {
                    queue(parsed.absoluteString)
                    return true
                }
            }
            if url.path.contains("install"),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
               let parsed = StremioManifestURL.parse(raw) {
                queue(parsed.absoluteString)
                return true
            }
        }
        return false
    }
}

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
