import UIKit
import WebKit
import AuthenticationServices

/// The shell's single screen: a full-bleed WKWebView pointed at the web app.
final class WebViewController: UIViewController {

    private let bridge = Bridge()
    private var webView: WKWebView!
    /// Kept alive while the system sign-in sheet is up — releasing it cancels the session.
    private var authSession: ASWebAuthenticationSession?
    private var backgroundedAt: Date?
    private var didRecoverFromCrash = false
    private var didRetryInitialLoad = false

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
        loadClearingStaleCacheIfUpgraded()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentLockIfNeeded()
    }

    /// Setup on first run, unlock afterwards. No lock at all would leave the
    /// encrypted cache readable by anyone holding the device.
    private func presentLockIfNeeded() {
        guard presentedViewController == nil else { return }
        let mode: LockViewController.Mode = AppLock.shared.hasPin ? .unlock : .setup
        if mode == .unlock && PageCache.shared.isUnlocked { return }
        let lock = LockViewController(mode: mode) { [weak self] in
            self?.dismiss(animated: true) {
                self?.webView.reload()
            }
        }
        present(lock, animated: false)
    }

    @objc private func appDidBackground() {
        backgroundedAt = Date()
    }

    @objc private func appWillForeground() {
        defer { backgroundedAt = nil }
        guard AppLock.shared.hasPin, let at = backgroundedAt else { return }
        guard Date().timeIntervalSince(at) >= AppLock.backgroundLockAfter else { return }
        AppLock.shared.lock()
        DispatchQueue.main.async { [weak self] in self?.presentLockIfNeeded() }
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
        cacheCurrentPage()
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
        // In-app sign-in (2026-10-07): start social sign-ins in the SYSTEM auth
        // session. Google blocks OAuth inside embedded webviews entirely, and
        // even where it didn't, the system browser's session cookies would
        // never reach this webview. The callback returns via the
        // `streetfoodos://` scheme and we trade a one-time token for session
        // cookies inside the webview (/auth/app-session).
        if AppConfig.isAppHost(url.host ?? ""), isAuthInitiation(url) {
            decisionHandler(.cancel)
            startAppAuthSession(startingAt: url)
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

    /// Save what the WebView actually rendered, encrypted, for offline use.
    /// Auth screens are never cached — and hitting one wipes the cache.
    private func cacheCurrentPage() {
        guard let url = webView.url else { return }
        let path = url.path
        if path == "/login" || path == "/logout" {
            PageCache.shared.wipe()
            return
        }
        guard PageCache.isCacheable(path) else { return }
        guard PageCache.shared.isUnlocked else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            guard let html = result as? String, html.count > 200 else { return }
            DispatchQueue.global(qos: .utility).async {
                try? PageCache.shared.save(path: path, html: html)
            }
        }
    }

    /// Serve the saved copy with a banner naming when it was taken.
    @discardableResult
    private func serveCachedPage(_ webView: WKWebView, path: String) -> Bool {
        guard PageCache.isCacheable(path) else { return false }
        let loadedEntry = (try? PageCache.shared.load(path: path)) ?? nil
        guard let entry = loadedEntry else { return false }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        let stamp = fmt.string(from: entry.savedAt)
        let banner = "<div style=\"position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#facc15;color:#111;font:500 13px -apple-system,sans-serif;padding:8px 12px;text-align:center\">Offline — showing the copy saved \(stamp)</div>"
        let html: String
        if let bodyRange = entry.html.range(of: "<body", options: .caseInsensitive) {
            html = entry.html.replacingOccurrences(of: "<body", with: "<body>" + banner, options: .caseInsensitive, range: bodyRange)
        } else {
            html = banner + entry.html
        }
        webView.loadHTMLString(html, baseURL: AppConfig.defaultURL.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst())))
        return true
    }

    /// The web content process was killed (memory pressure / WebKit crash).
    /// Standard recovery: one reload. If it recurs, say so plainly instead of
    /// showing a connectivity lie.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !didRecoverFromCrash {
            didRecoverFromCrash = true
            webView.reload()
            return
        }
        let alert = UIAlertController(
            title: "StreetFoodOS needs a restart",
            message: "The page engine stopped responding twice. Close the app and open it again — nothing has been lost.",
            preferredStyle: .alert
        )
        present(alert, animated: true)
    }

    /// WebKit can wedge on a stale cached response — after the caching
    /// changes shipped, an upgraded build showed a blank page with
    /// WebKitErrorDomain 300 until the website data was cleared. Clear the
    /// CACHE (never cookies/localStorage, so the session survives) once per
    /// build, and again if a navigation fails.
    private var cacheClearedForFailure = false
    private static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    private func clearWebCache(_ done: @escaping () -> Void) {
        WKWebsiteDataStore.default().removeData(ofTypes: Self.cacheTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async { done() }
        }
    }

    private func loadClearingStaleCacheIfUpgraded() {
        let key = "sfos.lastLoadedBuild"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        let last = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(build, forKey: key)
        if last == build {
            webView.load(URLRequest(url: AppConfig.launchURL))
            return
        }
        clearWebCache { [weak self] in
            self?.webView.load(URLRequest(url: AppConfig.launchURL))
        }
    }

    private func presentDiagnostics(error: Error, ns: NSError) {
        let target = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? AppConfig.launchURL
        let panel = DiagnosticViewController(
            url: target,
            webKitError: "\(ns.domain) \(ns.code) — \(error.localizedDescription)",
            onRetry: { [weak self] in self?.webView.load(URLRequest(url: target)) },
            onReset: { [weak self] in self?.webView.load(URLRequest(url: AppConfig.launchURL)) }
        )
        present(panel, animated: false)
    }

    private func showLoadError(_ error: Error) {
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        // WebKit "frame load interrupted" (101/102) = our OWN deliberate
        // decisionHandler(.cancel) on external hand-offs (auth redirects,
        // Safari links). Never dressed up as a connectivity failure — the
        // scary "Can't reach StreetFoodOS" alert was entirely self-inflicted.
        if ns.domain == "WebKitErrorDomain" && (ns.code == 101 || ns.code == 102) { return }
        // 300 = PlugInWillHandleLoad: WebKit handed the load to a handler
        // (custom scheme / plugin) and interrupted the navigation. Not a
        // connectivity failure — and if the view is left blank, reload once.
        if ns.domain == "WebKitErrorDomain" && ns.code == 300 {
            let blank = (webView.url == nil) || (webView.url?.absoluteString == "about:blank")
            if blank && !didRetryInitialLoad {
                didRetryInitialLoad = true
                webView.load(URLRequest(url: AppConfig.launchURL))
            }
            if !didRetryInitialLoad {
                presentDiagnostics(error: error, ns: ns)
            }
            return
        }
        // Offline: serve the encrypted copy this device saved for that page.
        // The failing URL comes from the error — on a provisional failure
        // webView.url is still the page we were already showing.
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if let path = failing?.path, serveCachedPage(webView, path: path) { return }
        if !cacheClearedForFailure {
            cacheClearedForFailure = true
            clearWebCache { [weak self] in
                self?.webView.load(URLRequest(url: AppConfig.launchURL))
            }
            return
        }
        let target = failing ?? AppConfig.launchURL
        let report = "\(ns.domain) \(ns.code) — \(error.localizedDescription)"
        let panel = DiagnosticViewController(
            url: target,
            webKitError: report,
            onRetry: { [weak self] in self?.webView.load(URLRequest(url: target)) },
            onReset: { [weak self] in self?.webView.load(URLRequest(url: AppConfig.launchURL)) }
        )
        present(panel, animated: false)
    }
}

// MARK: - In-app sign-in (ASWebAuthenticationSession)

extension WebViewController: ASWebAuthenticationPresentationContextProviding {

    /// True for the INITIATION legs only — /auth/google|apple|facebook.
    /// Callbacks and /auth/app-session are never intercepted.
    private func isAuthInitiation(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return comps.path == "/auth/google" || comps.path == "/auth/apple" || comps.path == "/auth/facebook"
    }

    private func startAppAuthSession(startingAt url: URL) {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let nonce = UUID().uuidString
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "app" || $0.name == "n" }
        items.append(URLQueryItem(name: "app", value: "ios"))
        items.append(URLQueryItem(name: "n", value: nonce))
        comps.queryItems = items
        guard let startURL = comps.url else { return }

        let session = ASWebAuthenticationSession(
            url: startURL,
            callbackURLScheme: AppConfig.authCallbackScheme
        ) { [weak self] callbackURL, error in
            self?.authSession = nil
            guard let callbackURL = callbackURL, error == nil else { return } // dismissed — stay put
            self?.completeAppAuth(callbackURL: callbackURL, nonce: nonce, origin: url)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    /// streetfoodos://auth?t=<token> → open /auth/app-session in the webview.
    private func completeAppAuth(callbackURL: URL, nonce: String, origin: URL) {
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let token = comps.queryItems?.first(where: { $0.name == "t" })?.value,
              !token.isEmpty else { return }
        var target = URLComponents()
        target.scheme = origin.scheme
        target.host = origin.host
        target.port = origin.port
        target.path = "/auth/app-session"
        target.queryItems = [
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "n", value: nonce)
        ]
        if let targetURL = target.url {
            webView.load(URLRequest(url: targetURL))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
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
