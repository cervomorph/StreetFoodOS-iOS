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
