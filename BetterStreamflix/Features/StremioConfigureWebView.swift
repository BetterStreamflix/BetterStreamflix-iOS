import SwiftUI
import WebKit

/// In-app Stremio addon configure page with automatic manifest / deep-link capture.
struct StremioConfigureWebView: View {
    let startURL: URL
    var onInstalled: ((InstalledStremioAddon) -> Void)?
    var onCancel: (() -> Void)?

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @State private var banner: String?
    @State private var isInstalling = false
    @State private var capturedURL: String?
    @State private var draftPaste = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConfigureWebRepresentable(
                    url: startURL,
                    onCapture: { raw in
                        Task { await installCaptured(raw) }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Finish configuration in the page above. When the addon shows a manifest link or redirects to stremio://, we install automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let banner {
                        Text(banner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(environment.theme.accentBright)
                    }
                    HStack(spacing: 8) {
                        TextField("Or paste finished manifest URL", text: $draftPaste)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote)
                        Button("Install") {
                            Task { await installCaptured(draftPaste) }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(draftPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInstalling)
                    }
                }
                .padding(16)
                .background(AppTheme.elevatedSurface)
            }
            .background { AppScreenBackground() }
            .navigationTitle("Configure addon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onCancel?() }
                }
            }
            .overlay {
                if isInstalling {
                    ProgressView("Installing…")
                        .padding(20)
                        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func installCaptured(_ raw: String) async {
        guard let parsed = StremioManifestURL.parse(raw) else {
            banner = "That doesn’t look like a Stremio manifest URL yet."
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let addon = try await store.install(from: parsed.absoluteString, curated: false)
            capturedURL = parsed.absoluteString
            banner = "Installed \(addon.name)"
            DesignTokens.Haptics.primaryAction()
            onInstalled?(addon)
        } catch {
            banner = error.localizedDescription
        }
    }
}

private struct ConfigureWebRepresentable: UIViewRepresentable {
    let url: URL
    let onCapture: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCapture: (String) -> Void
        private var lastCaptured: String?

        init(onCapture: @escaping (String) -> Void) {
            self.onCapture = onCapture
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                if captureIfNeeded(url) {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                _ = captureIfNeeded(url)
            }
        }

        @discardableResult
        private func captureIfNeeded(_ url: URL) -> Bool {
            let absolute = url.absoluteString
            if absolute == lastCaptured { return false }
            if url.scheme?.lowercased() == "stremio" {
                lastCaptured = absolute
                onCapture(absolute)
                return true
            }
            if absolute.lowercased().contains("manifest.json") {
                lastCaptured = absolute
                onCapture(absolute)
                return true
            }
            if let parsed = StremioManifestURL.parse(absolute),
               parsed.path.lowercased().hasSuffix("manifest.json") {
                lastCaptured = absolute
                onCapture(parsed.absoluteString)
                return true
            }
            return false
        }
    }
}
