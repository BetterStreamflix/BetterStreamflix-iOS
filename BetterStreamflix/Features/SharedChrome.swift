import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DestructiveTrashLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage(systemName: "trash")?.withTintColor(
                .systemRed,
                renderingMode: .alwaysOriginal
            ) {
                Image(uiImage: image)
            }
        }
    }
}

struct MediaTitlePosterActions: View {
    let item: MediaItem
    let onDetails: () -> Void

    var body: some View {
        Button(action: onDetails) {
            Label("Details", systemImage: "info.circle")
        }
        MediaTitleWatchlistAction(item: item)
    }
}

struct MediaTitleWatchlistAction: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem

    private var existingWatchlistItem: MediaItem? {
        if let tmdbID = item.tmdbID,
           let match = library.watchlist.first(where: {
               $0.kind == item.kind && $0.tmdbID == tmdbID
           }) {
            return match
        }
        return library.watchlist.first {
            $0.id == item.id && $0.providerID == item.providerID
        }
    }

    var body: some View {
        Button {
            WatchlistFeedback.toggle(
                existingWatchlistItem ?? item,
                in: library,
                reduceMotion: reduceMotion
            )
        } label: {
            Label(
                existingWatchlistItem == nil ? "Add to Watchlist" : "Remove from Watchlist",
                systemImage: existingWatchlistItem == nil ? "bookmark" : "bookmark.slash"
            )
        }
    }
}

struct TMDBTitlePosterActions: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: TrendingTitle
    let onDetails: () -> Void

    private var existingWatchlistItem: MediaItem? {
        library.watchlist.first {
            $0.kind == title.kind && $0.tmdbID == title.id
        }
    }

    var body: some View {
        Button(action: onDetails) {
            Label("Details", systemImage: "info.circle")
        }
        Button {
            WatchlistFeedback.toggleTrending(
                title,
                in: library,
                reduceMotion: reduceMotion
            )
        } label: {
            Label(
                existingWatchlistItem == nil ? "Add to Watchlist" : "Remove from Watchlist",
                systemImage: existingWatchlistItem == nil ? "bookmark" : "bookmark.slash"
            )
        }
    }
}
