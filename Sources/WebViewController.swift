import UIKit
import WebKit

/// The shell's single screen: a full-bleed WKWebView pointed at the web app.
final class WebViewController: UIViewController {

    private let bridge = Bridge()
    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let webView = makeWebView()
        self.webView = webView
        bridge.attach(to: webView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        // Live INSIDE the safe area: the page viewport then equals the visible
        // screen exactly (no scroll range hiding under the notch / home bar,
        // which made 100vh pages scroll their inset amount and feel "springy").
        // The notch + home strips show the view's background colour.
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: AppConfig.launchURL))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent store — till logins must survive app restarts.
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "StreetFoodOS-iOS/\(AppConfig.version)"
        config.userContentController.add(bridge, name: Bridge.handlerName)
        config.userContentController.addUserScript(bridge.makeUserScript())
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        // Kill the rubber-band "spring" (Kit feedback 06/10; parity with the
        // Android container's OVER_SCROLL_NEVER) — pages must feel pinned.
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        // The webview already sits inside the safe area — do NOT let WebKit
        // also inset the page itself; that double-count made every 100vh page
        // taller than its visible area.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // P0 bridge self-test — proves the native round-trip on every load
        // (visible via Safari's Web Inspector on a real device).
        webView.evaluateJavaScript(
            "window.IOSBridge && window.IOSBridge.call('ping').then(function (r) { console.log('SFOS IOSBridge ping:', JSON.stringify(r)); })",
            completionHandler: nil
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.targetFrame == nil {
            // target=_blank (receipts, external docs) — never silently drop.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if let host = url.host, !AppConfig.isAppHost(host) {
            // External link — hand to the system browser.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    private func showLoadError(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        // WebKit "frame load interrupted" (101/102) = our OWN deliberate
        // decisionHandler(.cancel) on external hand-offs (auth redirects,
        // Safari links). Never dressed up as a connectivity failure — the
        // scary "Can't reach StreetFoodOS" alert was entirely self-inflicted.
        if ns.domain == "WebKitErrorDomain" && (ns.code == 101 || ns.code == 102) { return }
        // P2 replaces this with the branded offline screen + native page cache.
        let alert = UIAlertController(
            title: "Can't reach StreetFoodOS",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.webView.reload()
        })
        present(alert, animated: true)
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
