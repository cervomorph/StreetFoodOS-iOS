import Foundation
import WebKit
import CryptoKit

/// Offline asset store (P3 option 1).
///
/// WHY: WKWebView cannot run service workers, so nothing intercepts asset
/// requests. Serving a saved page with `loadHTMLString` gave a styled-but-dead
/// snapshot. Instead the shell registers a custom scheme (`sfos-offline://`) and
/// serves every cached page AND its CSS/JS/images from disk, so the app runs —
/// and links navigate — with no network.
final class OfflineAssetStore {

    static let shared = OfflineAssetStore()

    struct Asset {
        let data: Data
        let contentType: String
    }

    private let dir: URL
    private let queue = DispatchQueue(label: "com.cervomorph.streetfoodos.assets", qos: .utility)

    init(directory: URL? = nil) {
        if let directory {
            dir = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent("OfflineAssets", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func key(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func store(path: String, data: Data, contentType: String) {
        let file = dir.appendingPathComponent(key(path))
        let typeFile = file.appendingPathExtension("type")
        queue.sync {
            try? data.write(to: file, options: [.atomic])
            try? Data(contentType.utf8).write(to: typeFile, options: [.atomic])
        }
    }

    func load(path: String) -> Asset? {
        let file = dir.appendingPathComponent(key(path))
        let typeFile = file.appendingPathExtension("type")
        guard let data = try? Data(contentsOf: file) else { return nil }
        let type = (try? String(contentsOf: typeFile, encoding: .utf8)) ?? "application/octet-stream"
        return Asset(data: data, contentType: type)
    }

    func wipe() {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    func stats() -> (assets: Int, bytes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var bytes = 0
        var count = 0
        for f in files where f.pathExtension != "type" {
            count += 1
            bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return (count, bytes)
    }
}

/// Serves `sfos-offline://app/<path>` from the caches. Pages first, then assets.
final class OfflineSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "sfos-offline"
    static let host = "app"

    private func respond(_ task: WKURLSchemeTask, data: Data, mime: String, status: Int = 200) {
        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var path = url.path
        if path.isEmpty { path = "/" }

        // A page?
        if let entry = (try? PageCache.shared.load(path: path)) ?? nil {
            respond(urlSchemeTask, data: Data(entry.html.utf8), mime: "text/html; charset=utf-8")
            return
        }
        // An asset?
        if let asset = OfflineAssetStore.shared.load(path: path) {
            respond(urlSchemeTask, data: asset.data, mime: asset.contentType)
            return
        }
        // Neither: a tiny, navigable fallback so the user is never stuck.
        let html = """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{background:#0b0f14;color:#e6e6e6;font:16px -apple-system,system-ui;padding:28px;margin:0}
        a{color:#4cc38a;text-decoration:none;font-weight:600}</style></head><body>
        <p>This screen was not saved for offline use.</p>
        <p><a href="/dashboard">Go to the dashboard</a></p>
        </body></html>
        """
        respond(urlSchemeTask, data: Data(html.utf8), mime: "text/html; charset=utf-8", status: 404)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing in flight to cancel.
    }
}
