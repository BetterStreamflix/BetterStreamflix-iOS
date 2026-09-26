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
    @State private var pendingConfirmURL: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConfigureWebRepresentable(
                    url: startURL,
                    onCapture: { raw, autoInstall in
                        if autoInstall {
                            Task { await installCaptured(raw) }
                        } else {
                            pendingConfirmURL = raw
                            banner = "Manifest ready — tap Install captured URL below."
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Finish configuration in the page above. When the addon opens a stremio:// install link we install automatically. HTTPS manifests need a confirm tap so the configure page can finish loading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let banner {
                        Text(banner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(environment.theme.accentBright)
                    }
                    if let pendingConfirmURL {
                        Button {
                            Task { await installCaptured(pendingConfirmURL) }
                        } label: {
                            Text("Install captured URL")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(environment.theme.accent)
                        .disabled(isInstalling)
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
        // Refuse to install a bare /configure route as a manifest.
        if parsed.lastPathComponent.lowercased() == "configure"
            || parsed.path.lowercased().hasSuffix("/configure") {
            banner = "Finish the configure page first, then install the manifest link."
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let addon = try await store.install(from: parsed.absoluteString, curated: false)
            capturedURL = parsed.absoluteString
            pendingConfirmURL = nil
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
    /// `autoInstall` is true for `stremio://` redirects; false for HTTPS manifests (confirm in UI).
    let onCapture: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(startURL: url, onCapture: onCapture)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let startURL: URL
        let onCapture: (String, Bool) -> Void
        private var lastCaptured: String?

        init(startURL: URL, onCapture: @escaping (String, Bool) -> Void) {
            self.startURL = startURL
            self.onCapture = onCapture
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "stremio" || scheme == "betterstreamflix" {
                    if captureIfNeeded(url, autoInstall: true) {
                        decisionHandler(.cancel)
                        return
                    }
                }
                // Never cancel HTTPS navigations — configure SPAs must finish loading.
                // Surface configured HTTPS manifests for a confirm tap only.
                if ["http", "https"].contains(scheme) {
                    _ = captureIfNeeded(url, autoInstall: false)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                _ = captureIfNeeded(url, autoInstall: false)
            }
        }

        @discardableResult
        private func captureIfNeeded(_ url: URL, autoInstall: Bool) -> Bool {
            let absolute = url.absoluteString
            if absolute == lastCaptured { return false }
            if absolute == startURL.absoluteString { return false }

            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "stremio" || scheme == "betterstreamflix" {
                lastCaptured = absolute
                onCapture(absolute, true)
                return true
            }

            guard ["http", "https"].contains(scheme) else { return false }
            let path = url.path.lowercased()
            guard path.hasSuffix("manifest.json") || path.contains("/manifest.json") else {
                return false
            }
            // Ignore the bare unconfigured origin manifest while the user is still on configure.
            if !StremioDebridURLBuilder.looksConfigured(url) {
                let bare = StremioDebridURLBuilder.bareManifestURL(from: startURL)
                if url.absoluteString.lowercased() == bare.absoluteString.lowercased()
                    || url.deletingLastPathComponent().absoluteString.lowercased()
                        == startURL.deletingLastPathComponent().absoluteString.lowercased() {
                    return false
                }
                // Still offer confirm for any other HTTPS manifest (user may paste-less finish).
            }
            lastCaptured = absolute
            onCapture(absolute, autoInstall && StremioDebridURLBuilder.looksConfigured(url))
            return false
        }
    }
}
