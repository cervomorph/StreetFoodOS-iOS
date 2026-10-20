import UIKit
import WebKit
import SystemConfiguration
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
    private var didRunNavTest = false
    private let statusLabel = UILabel()
    private let offlineScheme = OfflineSchemeHandler()
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
                self.loadInitialSmart()
            }
        }
        mark("lockShown")
        // A REAL network load, hidden behind the lock. WebKit creates its
        // NetworkProcess on demand and blocks the first navigation for ~12s
        // waiting for it (policy -> prov gap, then a 315ms page). Paying that
        // here, while the PIN is being typed, moves the cost off the user's
        // first page.
        mark("preload")
        webView.load(URLRequest(url: AppConfig.launchURL))
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
        config.setURLSchemeHandler(offlineScheme, forURLScheme: OfflineSchemeHandler.scheme)
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
        setLoading(false)
        if webView.url?.scheme == OfflineSchemeHandler.scheme {
            let p = webView.url?.path ?? "/"
            let saved = (try? PageCache.shared.load(path: p)) ?? nil
            if !isOnline() { injectOfflineBanner(savedAt: saved?.savedAt) }
            return
        }
        if !didRunCacheSelfTest { didRunCacheSelfTest = true; runCacheSelfTest() }
        if AppConfig.navTest, !didRunNavTest {
            didRunNavTest = true
            runNavigationTest(step: 0)
        }
        enforceOwner()
        cacheCurrentPage()
    }

    /// Snapshot the finished page into the encrypted cache and keep its assets.
    private func cacheCurrentPage() {
        guard let url = webView.url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let path = url.path
        if path == "/logout" { PageCache.shared.wipe(); return }
        if path == "/login" { return }
        guard PageCache.isCacheable(path) else { return }
        guard PageCache.shared.isUnlocked else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
            guard let self else { return }
            if let error { NSLog("SFOS_CACHE JS error for %@: %@", path, String(describing: error)) }
            guard let html = result as? String, html.count > 200 else { return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    try PageCache.shared.save(path: path, html: html)
                    self.harvestAssets(html: html)
                    NSLog("SFOS_CACHE saved %@ (%d bytes), total=%d", path, html.count, PageCache.shared.stats().pages)
                } catch {
                    NSLog("SFOS_CACHE save FAILED %@: %@", path, String(describing: error))
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
        return  // debug banner retired (20/10)
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

    /// Best-effort connectivity check. A wrong "offline" only costs a cached
    /// paint; a wrong "online" would serve stale bytes as if they were live.
    private func isOnline() -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard let reach = SCNetworkReachabilityCreateWithAddress(nil, &address) else { return true }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return true }
        let reachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return reachable && !needsConnection
    }

    /// Instant launch: if a fresh copy of the landing screen exists, paint it
    /// from disk (no network, no WebKit NetworkProcess wait) and let the next
    /// navigation fetch live. Falls back to the network path when there is no
    /// usable copy.
    private func loadInitialSmart() {
        // Online is always live: the cache is a fallback, never a substitute.
        // Serving a cached page while online made the app look offline and left
        // links stranded on the scheme origin.
        if isOnline() {
            loadClearingStaleCacheIfUpgraded()
            return
        }
        let path = AppConfig.launchURL.path
        let entry = (try? PageCache.shared.load(path: path)) ?? nil
        let fresh = entry.map { Date().timeIntervalSince($0.savedAt) < 600 } ?? false
        if let entry, fresh, PageCache.shared.isUnlocked,
           let url = URL(string: "\(OfflineSchemeHandler.scheme)://\(OfflineSchemeHandler.host)\(path)") {
            setLoading(false)
            webView.load(URLRequest(url: url))
            NSLog("SFOS_LAUNCH served %@ from cache (age %.0fs)", path, Date().timeIntervalSince(entry.savedAt))
            return
        }
        loadClearingStaleCacheIfUpgraded()
    }

    /// A different signed-in user on this device must never see the previous
    /// user's cached pages.
    private func enforceOwner() {
        webView.evaluateJavaScript("window.userLogin || ''") { [weak self] result, _ in
            guard let self, let who = result as? String, !who.isEmpty else { return }
            let key = "sfos.cacheOwner"
            let previous = UserDefaults.standard.string(forKey: key)
            if let previous, previous != who {
                PageCache.shared.wipe()
                OfflineAssetStore.shared.wipe()
                NSLog("SFOS_CACHE owner changed %@ -> %@, cache wiped", previous, who)
            }
            UserDefaults.standard.set(who, forKey: key)
        }
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

    /// Pull every local stylesheet/script/image/font the page referenced and
    /// keep a copy on disk, so the page runs offline from the scheme handler.
    private func harvestAssets(html: String) {
        let pattern = #"(?:src|href)\s*=\s*[\"'](/[^\"'\s]+\.(?:css|js|mjs|png|jpe?g|svg|webp|gif|woff2?|ttf|ico))[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let ns = html as NSString
        var seen = Set<String>()
        var paths: [String] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            let p = ns.substring(with: m.range(at: 1))
            if seen.insert(p).inserted { paths.append(p) }
        }
        guard !paths.isEmpty else { return }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            for path in paths {
                guard let url = URL(string: path, relativeTo: AppConfig.defaultURL)?.absoluteURL else { continue }
                if OfflineAssetStore.shared.load(path: path) != nil { continue }
                var request = URLRequest(url: url)
                request.setValue(header, forHTTPHeaderField: "Cookie")
                request.timeoutInterval = 20
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    guard let data, !data.isEmpty,
                          let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                    let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                    OfflineAssetStore.shared.store(path: path, data: data, contentType: mime)
                }.resume()
            }
        }
    }

    /// The yellow "showing the copy saved …" strip, injected into offline pages.
    private func injectOfflineBanner(savedAt: Date?) {
        let stamp: String
        if let savedAt {
            let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
            stamp = fmt.string(from: savedAt)
        } else { stamp = "earlier" }
        let js = """
        (function () {
          if (document.getElementById('sfos-offline-banner')) { return; }
          var d = document.createElement('div');
          d.id = 'sfos-offline-banner';
          d.textContent = 'Offline — showing the copy saved \(stamp)';
          d.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;background:#facc15;color:#111;font:500 13px -apple-system,sans-serif;padding:8px 12px;text-align:center';
          document.body.appendChild(d);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// CI probe: sign in if needed, load a page from the cache, click a nav
    /// link, and report whether the navigation actually happened.
    private func runNavigationTest(step: Int) {
        switch step {
        case 0:
            webView.evaluateJavaScript("location.pathname") { [weak self] result, _ in
                guard let self else { return }
                let path = (result as? String) ?? "/"
                NSLog("SFOS_NAVTEST step0 path=%@", path)
                if path.hasPrefix("/login"), let user = AppConfig.testUser, let pass = AppConfig.testPass {
                    let js = """
                    (function(){var t=document.getElementById('pfCredToggle'); if(t){t.click();}
                    var u=document.querySelector('input[name="username"]'), p=document.querySelector('input[name="password"]');
                    if(u&&p){u.value='\(user)';p.value='\(pass)';
                    var f=u.closest('form'); if(f){f.querySelector('button[type="submit"]').click();}}})();
                    """
                    self.webView.evaluateJavaScript(js, completionHandler: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.runNavigationTest(step: 1) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runNavigationTest(step: 1) }
                }
            }
        case 1:
            let path = webView.url?.path ?? "/dashboard"
            NSLog("SFOS_NAVTEST step1 load cached path=%@", path)
            if let url = URL(string: "\(OfflineSchemeHandler.scheme)://\(OfflineSchemeHandler.host)\(path)") {
                webView.load(URLRequest(url: url))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.runNavigationTest(step: 2) }
        case 2:
            webView.evaluateJavaScript("location.href") { [weak self] result, _ in
                NSLog("SFOS_NAVTEST step2 href=%@", (result as? String) ?? "nil")
                let js = """
                (function(){
                  var now=location.pathname;
                  var as=document.querySelectorAll('a[href^="/"]:not([href^="//"])');
                  var alt=null;
                  for(var i=0;i<as.length;i++){var h=as[i].getAttribute('href');
                    if(h && h!==now && h.indexOf('#')===-1){alt=h;break;}}
                  var target=alt||'/terminal';
                  try { window.IOSBridge.call('nav.open', {path: target}); return 'bridge:'+target; }
                  catch(e) { return 'bridge-failed:'+e; }
                })();
                """
                self?.webView.evaluateJavaScript(js) { res, _ in
                    NSLog("SFOS_NAVTEST step2 clicked=%@", (res as? String) ?? "nil")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.runNavigationTest(step: 3) }
        case 3:
            webView.evaluateJavaScript("location.href") { result, _ in
                NSLog("SFOS_NAVTEST step3 after-click href=%@", (result as? String) ?? "nil")
            }
        default: break
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
