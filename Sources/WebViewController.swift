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
    private var cacheClearedForFailure = false
    private var hasStartedInitialLoad = false
    private var didRunCacheSelfTest = false
    private let statusLabel = UILabel()
    private var lastCacheError = "none"
    private let launchStart = Date()
    private var timeline: [String] = []

    private func mark(_ label: String) {
        timeline.append(String(format: "%@=%.1fs", label, Date().timeIntervalSince(launchStart)))
        if timeline.count > 9 { timeline.removeFirst() }
    }
    private let loadingOverlay = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    fileprivate static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeServiceWorkerRegistrations,
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let webView = makeWebView()
        self.webView = webView
        bridge.attach(to: webView)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.067, green: 0.086, blue: 0.114, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
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
        // The load starts in viewDidAppear — AFTER the lock is dismissed.
        // Loading under a full-screen lock presentation made WebKit abort the
        // navigation (WebKitErrorDomain 300) and left a blank page.

        makeLoadingOverlay()
        // The count must be live: the sweep saves pages while the user sits on
        // one screen, so a label drawn at didFinish never showed progress.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshCacheStatus()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

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
        startInitialLoadIfNeeded()
    }

    /// First real load happens only when no lock is presented.
    private func startInitialLoadIfNeeded() {
        guard !hasStartedInitialLoad, presentedViewController == nil else { return }
        hasStartedInitialLoad = true
        loadClearingStaleCacheIfUpgraded()
    }

    /// Setup on first run, unlock afterwards. No lock at all would leave the
    /// encrypted cache readable by anyone holding the device.
    private func presentLockIfNeeded() {
        if AppConfig.skipLock {
            do {
                try PageCache.shared.unlockWithKeychain()
            } catch {
                NSLog("SFOS_LOCK keychain unlock failed: %@", String(describing: error))
                let ephemeral = CacheCrypto.makeDeviceKey()
                try? PageCache.shared.unlock(withDeviceKey: ephemeral)
                NSLog("SFOS_LOCK falling back to an in-memory key")
            }
            NSLog("SFOS_LOCK skipped (debug flag), cache unlocked=%d", PageCache.shared.isUnlocked ? 1 : 0)
            return
        }
        guard presentedViewController == nil else { return }
        let mode: LockViewController.Mode = AppLock.shared.hasPin ? .unlock : .setup
        if mode == .unlock && PageCache.shared.isUnlocked { return }
        let lock = LockViewController(mode: mode) { [weak self] in
            guard let self else { return }
            self.mark("unlocked")
            self.dismiss(animated: true) {
                self.hasStartedInitialLoad = true
                self.mark("loadStart")
                self.webView.load(URLRequest(url: AppConfig.launchURL))
            }
        }
        mark("lockShown")
        logEnvironment()
        warmConnection()
        present(lock, animated: false)
    }

    @objc private func appDidBecomeActive() { refreshCacheStatus() }

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

    /// Wake DNS/TLS while the user types the PIN — the first navigation was
    /// waiting ~14s for a cold connection.
    private func warmConnection() {
        var request = URLRequest(url: AppConfig.launchURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let seconds = Date().timeIntervalSince(start)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("SFOS_WARM warm=%.2fs code=%d err=%@", seconds, code, String(describing: error))
            DispatchQueue.main.async {
                self?.mark(String(format: "warm=%.1fs", seconds))
                self?.refreshCacheStatus()
            }
        }.resume()
    }

    /// Device facts that differ between the fast iPhone and the slow iPad.
    private func logEnvironment() {
        let os = UIDevice.current.systemVersion
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        NSLog("SFOS_ENV iOS=%@ lowPower=%d", os, lowPower ? 1 : 0)
        mark("lowPwr=\(lowPower ? 1 : 0)")
        probeWithThrowawayWebView()
    }

    /// A second, independent WKWebView loading the same URL. If it is fast the
    /// stall is in OUR instance; if it is slow it is WebKit on this device.
    private func probeWithThrowawayWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let probe = WKWebView(frame: .zero, configuration: config)
        let start = Date()
        probe.load(URLRequest(url: AppConfig.launchURL))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            let elapsed = Date().timeIntervalSince(start)
            NSLog("SFOS_PROBE throwaway progress=%.0f%% after %.1fs", probe.estimatedProgress * 100, elapsed)
            self.mark(String(format: "probe=%.1fs", elapsed))
            self.refreshCacheStatus()
        }
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
        // Boot WebKit's content process NOW (behind the lock screen). The first
        // real navigation was waiting ~14s between the provisional load and
        // commit, while the same URL answered in 41ms — that is process
        // start-up, not network. A throwaway local page pays the cost early.
        webView.loadHTMLString(
            "<html><body style=\"margin:0;background:#11161d\"></body></html>",
            baseURL: nil
        )
        return webView
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        mark("prov")
    }

    /// Content has started arriving: the page is about to paint, so drop the
    /// overlay now. didFinish waits for every subresource and was holding the
    /// spinner for ~14s after the page was already visible.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        mark("commit")
        setLoading(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        mark("loaded")
        webView.evaluateJavaScript("""
        (function () {
          try {
            var n = performance.getEntriesByType('navigation')[0];
            if (!n) { return 'no-nav-timing'; }
            return 'ttfb=' + Math.round(n.responseStart - n.requestStart) +
                   'ms dns=' + Math.round(n.domainLookupEnd - n.domainLookupStart) +
                   'ms tls=' + Math.round(n.connectEnd - n.connectStart) +
                   'ms total=' + Math.round(n.duration) + 'ms';
          } catch (e) { return 'timing-error'; }
        })();
        """) { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            self.mark(text.replacingOccurrences(of: " ", with: " "))
            self.refreshCacheStatus()
        }
        setLoading(false)
        if !didRunCacheSelfTest { didRunCacheSelfTest = true; runCacheSelfTest() }
        refreshCacheStatus()
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
        if navigationAction.targetFrame?.isMainFrame == true { mark("policy") }
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
        guard let url = webView.url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let path = url.path
        // Only a deliberate sign-out wipes. Rendering /login must NOT drop the
        // device key: a fresh install (or any expired session) lands on /login
        // before the user signs in, and wiping there destroyed the key seconds
        // after unlock, leaving the cache locked for the rest of the session.
        if path == "/logout" {
            PageCache.shared.wipe()
            return
        }
        if path == "/login" { return }
        guard PageCache.isCacheable(path) else { NSLog("SFOS_CACHE skip %@ (not cacheable)", path); return }
        guard PageCache.shared.isUnlocked else { NSLog("SFOS_CACHE skip %@ (locked)", path); return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let error { NSLog("SFOS_CACHE JS error for %@: %@", path, String(describing: error)) }
            guard let html = result as? String, html.count > 200 else {
                NSLog("SFOS_CACHE skip %@ (html type=%@ len=%d)", path, String(describing: type(of: result)), (result as? String)?.count ?? -1)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    try PageCache.shared.save(path: path, html: html)
                    NSLog("SFOS_CACHE saved %@ (%d bytes), total=%d", path, html.count, PageCache.shared.stats().pages)
                } catch {
                    self.lastCacheError = String(describing: error)
                    NSLog("SFOS_CACHE save FAILED %@: %@", path, String(describing: error))
                    DispatchQueue.main.async { self.refreshCacheStatus() }
                }
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
        // Load IMMEDIATELY. WebKit's removeData() takes 10-15s on a populated
        // store, and every new build number counted as an "upgrade", so the
        // purge gated the first load on every install.
        setLoading(true)
        webView.load(URLRequest(url: AppConfig.launchURL))
        guard last != build else { return }
        // Cheap migration for older builds: drop any service-worker
        // registration left behind (a stuck SW was wedging navigation).
        webView.evaluateJavaScript("navigator.serviceWorker && navigator.serviceWorker.getRegistrations().then(function(rs){rs.forEach(function(r){r.unregister();});}).catch(function(){});", completionHandler: nil)
    }

    /// A branded loading state — the bare web view showed a white canvas for
    /// several seconds on first load after an upgrade.
    /// Write-and-read a probe entry so a broken cache is visible immediately
    /// instead of only as "0 screens saved" hours later.
    private func runCacheSelfTest() {
        let cache = PageCache.shared
        let probe = "/__selftest"
        do {
            try cache.save(path: probe, html: "<html><body>selftest</body></html>")
            let readBack = try cache.load(path: probe)
            let ok = readBack?.html.contains("selftest") == true
            cache.remove(path: probe)
            if !ok { showCacheBanner("Offline cache self-test failed: write succeeded but read-back was empty") }
        } catch {
            showCacheBanner("Offline cache unavailable: \(error)")
        }
    }

    private func showCacheBanner(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func makeLoadingOverlay() {
        loadingOverlay.backgroundColor = UIColor(red: 0.067, green: 0.086, blue: 0.114, alpha: 1)
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = "StreetFood OS"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.font = UIFont(name: "AvenirNext-DemiBold", size: 15) ?? label.font
        label.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = UIColor(white: 0.7, alpha: 1)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(spinner)
        loadingOverlay.addSubview(label)
        view.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
            label.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
        ])
        spinner.startAnimating()
        mark("ui")

        // Ground-truth status line (temporary, P3 debugging): shows whether the
        // cache is unlocked and how many pages it holds, on the device itself.
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = UIColor(white: 1, alpha: 0.55)
        statusLabel.numberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
    }

    private func refreshCacheStatus() {
        let cache = PageCache.shared
        let stats = cache.stats()
        let time = timeline.isEmpty ? "" : "\n" + timeline.joined(separator: " ")
        statusLabel.text = "cache: \(cache.isUnlocked ? "unlocked" : "LOCKED") · pages=\(stats.pages) · pin=\(AppLock.shared.hasPin ? "yes" : "no") · err=\(lastCacheError)" + time
        view.bringSubviewToFront(statusLabel)
    }

    private func setLoading(_ loading: Bool) {
        loadingOverlay.isHidden = !loading
        view.bringSubviewToFront(loadingOverlay)
    }

    private func isOnline() -> Bool {
        var reachable = false
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(url: URL(string: "https://app.streetfoodos.com/health")!)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return reachable
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
        // Offline: the probe panel is meaningless. Say what we actually know.
        let stats = PageCache.shared.stats()
        if !isOnline() {
            let alert = UIAlertController(
                title: "You're offline",
                message: "No saved copy of this screen.\n\n\(stats.pages) screen\(stats.pages == 1 ? "" : "s") saved on this device — open one of those, or reconnect.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
                self?.webView.load(URLRequest(url: AppConfig.launchURL))
            })
            present(alert, animated: true)
            return
        }
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
            webKitError: report + "\nCache: \(PageCache.shared.stats().pages) page(s) saved",
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
