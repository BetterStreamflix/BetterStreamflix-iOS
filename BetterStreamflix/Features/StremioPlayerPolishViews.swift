import SwiftUI
import UIKit

/// Empty-state actions when Stremio only returned torrents / external / YouTube links.
struct StremioPlayerEmptyActionsView: View {
    let diagnostics: StremioResolveDiagnostics
    var onOpenFilters: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            if !diagnostics.perAddon.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(diagnostics.perAddon) { row in
                            Text(row.chipTitle)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
            if diagnostics.skippedUnsupportedFormat > 0, diagnostics.playableHTTP == 0 {
                Text("Addons returned MKV/Remux-only links iOS can’t play directly — try cached filters or another addon.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let onOpenFilters {
                    Button(action: onOpenFilters) {
                        Label("Open source filters", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 10) {
                if let url = diagnostics.primaryExternalURL {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let yt = diagnostics.primaryYouTubeURL {
                    Button {
                        UIApplication.shared.open(yt)
                    } label: {
                        Label("YouTube", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                if diagnostics.skippedTorrent > 0 {
                    Text(
                        diagnostics.debridConfigured
                            ? "Validate Debrid in More → Stremio"
                            : "Add Debrid in More → Stremio"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Live per-addon resolve HUD shown while discovery is still running.
struct StremioResolveHUDView: View {
    let diagnostics: StremioResolveDiagnostics
    let isSearching: Bool

    var body: some View {
        if isSearching, !diagnostics.perAddon.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(diagnostics.perAddon) { row in
                        Text(row.chipTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 6)
        }
    }
}

/// Source command-center filters for Stremio-enriched playable streams.
struct StremioSourceFilterSheet: View {
    @Binding var cachedOnly: Bool
    @Binding var minQualityHeight: Int
    @Binding var selectedAddonID: String?
    @Binding var sortMode: StremioSourceSortMode
    let addonNames: [(id: String, name: String)]
    var matchCount: Int = 0
    var totalCount: Int = 0
    var onReset: () -> Void = {}
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Cached debrid only", isOn: $cachedOnly)
                    Picker("Minimum quality", selection: $minQualityHeight) {
                        Text("Any").tag(0)
                        Text("720p+").tag(720)
                        Text("1080p+").tag(1080)
                        Text("4K").tag(2160)
                    }
                    Picker("Sort", selection: $sortMode) {
                        ForEach(StremioSourceSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text("Filters")
                } footer: {
                    Text("Showing \(matchCount) of \(totalCount) sources")
                }

                if !addonNames.isEmpty {
                    Section("Addon") {
                        Button("All addons") { selectedAddonID = nil }
                        ForEach(addonNames, id: \.id) { pair in
                            Button {
                                selectedAddonID = pair.id
                            } label: {
                                HStack {
                                    Text(pair.name)
                                    Spacer()
                                    if selectedAddonID == pair.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Reset filters", role: .destructive, action: onReset)
                }
            }
            .navigationTitle("Source filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onApply() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Top player chrome: toast + resolve HUD + filters chip.
struct StremioPlayerTopChromeView: View {
    let toast: String?
    let diagnostics: StremioResolveDiagnostics
    let isSearching: Bool
    let showFiltersChip: Bool
    let filtersActive: Bool
    let bingeGroup: String?
    var onOpenFilters: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, ScreenMetrics.topSafeAreaInset + 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            StremioResolveHUDView(diagnostics: diagnostics, isSearching: isSearching)
                .padding(.top, toast == nil ? ScreenMetrics.topSafeAreaInset + 56 : 0)
            if showFiltersChip {
                HStack(spacing: 8) {
                    if let bingeGroup {
                        Text("Continuing \(bingeGroup)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Button(action: onOpenFilters) {
                        Label(
                            filtersActive ? "Filters · on" : "Filters",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
        }
    }
}

/// Bottom player chrome: empty-state actions or empty-filter reset.
struct StremioPlayerBottomChromeView: View {
    let showEmptyActions: Bool
    let showEmptyFilters: Bool
    let diagnostics: StremioResolveDiagnostics
    var onOpenFilters: () -> Void
    var onResetFilters: () -> Void

    var body: some View {
        Group {
            if showEmptyActions {
                StremioPlayerEmptyActionsView(
                    diagnostics: diagnostics,
                    onOpenFilters: onOpenFilters
                )
                .padding(.horizontal, 20)
                .padding(.bottom, ScreenMetrics.bottomSafeAreaInset + 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if showEmptyFilters {
                VStack(spacing: 8) {
                    Text("No sources match these filters")
                        .font(.caption.weight(.semibold))
                    Button(action: onResetFilters) {
                        Label("Reset filters", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, ScreenMetrics.bottomSafeAreaInset + 28)
            }
        }
    }
}
