import Foundation

/// Native page cache — P2 placeholder. Design constraints are binding (see the
/// sfos-ios-app skill + the 2026-09-13 stale-auth incident — do not relitigate):
///   - WKWebView does not reliably run service workers → this is a native
///     feature; it must not be built on sw.js.
///   - Session-scoped only; flushed on logout.
///   - NEVER cache /login, /logout, /auth/*, /api/*.
///   - Offline boot without a session shows the offline screen only — never a
///     cached authenticated page.
///
/// P2: store the last-known HTML + its version-stamped assets per page and
/// serve them into the WebView when offline, with the "no internet connection
/// — data is not live" banner injected by the cache layer.
enum PageCache {

    /// Not wired yet — lands in P2.
    static let isAvailable = false
}
