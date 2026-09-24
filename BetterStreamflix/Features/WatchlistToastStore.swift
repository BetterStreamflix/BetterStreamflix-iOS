import SwiftUI
import UIKit

@MainActor
final class WatchlistToastStore: ObservableObject {
    @Published private(set) var toast: WatchlistFeedback.Toast?
    private var clearTask: Task<Void, Never>?

    func present(_ toast: WatchlistFeedback.Toast) {
        clearTask?.cancel()
        withAnimation(DesignTokens.Motion.toast) {
            self.toast = toast
        }
        clearTask = Task {
            try? await Task.sleep(for: .seconds(1.65))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(DesignTokens.Motion.toast) {
                    if self.toast == toast {
                        self.toast = nil
                    }
                }
            }
        }
    }

    func clear() {
        clearTask?.cancel()
        withAnimation(DesignTokens.Motion.toast) {
            toast = nil
        }
    }
}
