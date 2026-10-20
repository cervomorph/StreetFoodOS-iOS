import Foundation
import WebKit

/// The `window.IOSBridge` native side — the iOS counterpart of the Android
/// container's `window.AndroidBridge`. Thin native layer; the web app decides
/// when to call across (mirrors `sfos-android-container`).
///
/// JS surface injected at document start:
///   window.IOSBridge.platform            -> "ios"
///   window.IOSBridge.isNative()          -> true
///   window.IOSBridge.version             -> e.g. "0.1.0"
///   window.IOSBridge.call(method, args)  -> Promise<{ ok: true, ... } | { ok: false, error }>
///
/// P0 ships the round-trip plumbing plus `ping` (the shell self-tests it on
/// every page load). Hardware methods (receipt print, cash drawer via
/// StarXpand) land in P3 and keep the same `call()` shape so the web layer
/// needs no re-plumbing.
final class Bridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "sfosBridge"

    private weak var webView: WKWebView?

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    /// The `window.IOSBridge` shim, injected before any page script runs.
    func makeUserScript() -> WKUserScript {
        let js = """
        (function () {
          if (window.IOSBridge) { return; }
          var pending = {};
          var seq = 0;
          window.__sfosBridgeResolve = function (id, payload) {
            var p = pending[id];
            if (!p) { return; }
            delete pending[id];
            if (payload && payload.ok === false) { p.reject(payload); } else { p.resolve(payload); }
          };
          window.IOSBridge = {
            platform: 'ios',
            isNative: function () { return true; },
            version: '\(AppConfig.version)',
            call: function (method, args) {
              return new Promise(function (resolve, reject) {
                var id = 'sfos-' + (++seq);
                pending[id] = { resolve: resolve, reject: reject };
                window.webkit.messageHandlers.\(Self.handlerName).postMessage({ id: id, method: method, args: args || {} });
              });
            }
          };
          // Link navigation lives here, not in page JS: a page served from the
          // cache may not load nav.js, and WebKit silently drops JS-initiated
          // navigation to a custom scheme, which left links dead.
          document.addEventListener('click', function (e) {
            var el = e.target;
            while (el && el.tagName !== 'A') { el = el.parentElement; }
            if (!el) { return; }
            var href = el.getAttribute('href');
            if (!href || href.charAt(0) !== '/' || href.charAt(1) === '/' || href.indexOf('#') === 0) { return; }
            var seg = href.split('?')[0].split('/')[1] || '';
            if (['auth','oauth','login','logout','signin','signup','sso'].indexOf(seg) !== -1) { return; }
            if (el.target === '_blank' || el.hasAttribute('download')) { return; }
            e.preventDefault();
            try {
              window.IOSBridge.call('nav.open', { path: href }).catch(function () { window.location.assign(href); });
            } catch (err) { window.location.assign(href); }
          }, true);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let method = body["method"] as? String
        else { return }
        let args = body["args"] as? [String: Any] ?? [:]
        handle(method: method, args: args) { [weak self] result in
            self?.respond(id: id, payload: result)
        }
    }

    private func handle(method: String, args: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        switch method {
        case "ping":
            completion(["ok": true, "platform": "ios", "version": AppConfig.version])

        case "cache.save":
            guard let path = args["path"] as? String, let html = args["html"] as? String else {
                completion(["ok": false, "error": "bad args"]); return
            }
            DispatchQueue.global(qos: .utility).async {
                do {
                    try PageCache.shared.save(path: path, html: html)
                    completion(["ok": true])
                } catch {
                    completion(["ok": false, "error": "\(error)"])
                }
            }

        case "nav.open":
            guard let path = args["path"] as? String, path.hasPrefix("/") else {
                completion(["ok": false, "error": "bad path"]); return
            }
            DispatchQueue.main.async {
                // Load the real origin, not the offline scheme: pages served
                // through the scheme came back without their JS bindings, so
                // the nav, burger and cog menus stopped responding. Offline
                // still works — the failed load falls back to the cached copy.
                let base = AppConfig.launchURL
                var comps = URLComponents()
                comps.scheme = base.scheme
                comps.host = base.host
                comps.port = base.port
                let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                comps.path = String(parts[0])
                if parts.count > 1 { comps.query = String(parts[1]) }
                if let url = comps.url {
                    self.webView?.load(URLRequest(url: url))
                    completion(["ok": true])
                } else {
                    completion(["ok": false, "error": "bad url"])
                }
            }

        case "cache.stats":
            let stats = PageCache.shared.stats()
            completion(["ok": true, "pages": stats.pages, "bytes": stats.bytes,
                        "unlocked": PageCache.shared.isUnlocked, "locked": AppLock.shared.hasPin])

        case "cache.wipe":
            PageCache.shared.wipe()
            completion(["ok": true])

        case "cache.has":
            guard let path = args["path"] as? String else { completion(["ok": false]); return }
            let entry = (try? PageCache.shared.load(path: path)) ?? nil
            completion(["ok": true, "cached": entry != nil,
                        "savedAt": entry.map { $0.savedAt.timeIntervalSince1970 } ?? 0])
        default:
            // Unknown methods fail soft — the web layer feature-detects via
            // isNative() and degrades (never a dead button).
            completion(["ok": false, "error": "unimplemented", "method": method])
        }
    }

    private func respond(id: String, payload: [String: Any]) {
        guard let payloadJSON = Self.jsonString(payload), let idJSON = Self.jsonString(id) else { return }
        let js = "window.__sfosBridgeResolve && window.__sfosBridgeResolve(\(idJSON), \(payloadJSON));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private static func jsonString(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
