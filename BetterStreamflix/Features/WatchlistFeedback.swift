import SwiftUI

@MainActor
enum WatchlistFeedback {
    struct Toast: Equatable {
        let message: String
        let isAdded: Bool
    }

    /// Toggles watchlist membership and returns whether the item is now saved.
    @discardableResult
    static func toggle(
        _ item: MediaItem,
        in library: LibraryStore,
        reduceMotion: Bool = false,
        toastStore: WatchlistToastStore? = nil,
        onToast: ((Toast) -> Void)? = nil
    ) -> Bool {
        let wasSaved = library.isInWatchlist(item)
        withAnimation(reduceMotion ? nil : DesignTokens.Motion.watchlistBounce) {
            library.toggleWatchlist(item)
        }
        let isSaved = !wasSaved
        let toast: Toast
        if isSaved {
            DesignTokens.Haptics.watchlistAdded()
            toast = Toast(message: "Added to Library", isAdded: true)
        } else {
            DesignTokens.Haptics.watchlistRemoved()
            toast = Toast(message: "Removed from Library", isAdded: false)
        }
        toastStore?.present(toast)
        onToast?(toast)
        return isSaved
    }

    static func toggleTrending(
        _ title: TrendingTitle,
        in library: LibraryStore,
        reduceMotion: Bool = false,
        toastStore: WatchlistToastStore? = nil,
        onToast: ((Toast) -> Void)? = nil
    ) -> Bool {
        if let existing = library.watchlist.first(where: {
            $0.kind == title.kind && $0.tmdbID == title.id
        }) {
            return toggle(
                existing,
                in: library,
                reduceMotion: reduceMotion,
                toastStore: toastStore,
                onToast: onToast
            )
        }
        return toggle(
            .tmdbCatalogItem(from: title),
            in: library,
            reduceMotion: reduceMotion,
            toastStore: toastStore,
            onToast: onToast
        )
    }
}

struct WatchlistToggleButton: View {
    let isInWatchlist: Bool
    let action: () -> Void
    var size: CGFloat = 36
    var glass: Bool = true

    @State private var bounce = false

    var body: some View {
        Button {
            bounce.toggle()
            action()
        } label: {
            Image(systemName: isInWatchlist ? "checkmark" : "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(bounce ? 1.12 : 1)
                .animation(DesignTokens.Motion.watchlistBounce, value: isInWatchlist)
                .animation(DesignTokens.Motion.watchlistBounce, value: bounce)
        }
        .buttonStyle(.plain)
        .modifier(WatchlistGlassBackground(enabled: glass))
        .accessibilityLabel(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist")
        // Haptics fire only from WatchlistFeedback.toggle on explicit user action —
        // never from sensoryFeedback on isInWatchlist (that re-triggers on carousel change).
    }
}

private struct WatchlistGlassBackground: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassEffectWithFallback(in: Circle())
        } else {
            content
                .background(.white.opacity(0.18), in: Circle())
        }
    }
}

struct WatchlistToastBanner: View {
    let toast: WatchlistFeedback.Toast?

    var body: some View {
        if let toast {
            Label(toast.message, systemImage: toast.isAdded ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffectWithFallback(in: Capsule())
                .foregroundStyle(AppTheme.primaryText)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }
}
