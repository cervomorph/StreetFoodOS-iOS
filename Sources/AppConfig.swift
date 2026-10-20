import Foundation

/// Static shell configuration.
enum AppConfig {

    /// Marketing version, e.g. "0.1.0" (CFBundleShortVersionString).
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Prod landing — mirrors the Android container default: opens the dashboard.
    static let defaultURL = URL(string: "https://app.streetfoodos.com/dashboard")!

    /// Dev override: launch argument `-SFOSURL https://dev.streetfoodos.com/...`
    /// (set in the scheme; shipped builds never pass it). Mirrors the Android
    /// container's `sfos_url` extra.
    static var launchURL: URL {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-SFOSURL"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            return url
        }
        return defaultURL
    }

    /// Simulator/CI only: skip the PIN lock so automated runs can reach the
    /// web view. Never used by a shipped build.
    static var skipLock: Bool { ProcessInfo.processInfo.arguments.contains("-SFOSSkipLock") }

    /// Simulator/CI only: exercise cache-first navigation and log the result.
    static var navTest: Bool { ProcessInfo.processInfo.arguments.contains("-SFOSNavTest") }
    static var testUser: String? { value(after: "-SFOSUser") }
    static var testPass: String? { value(after: "-SFOSPass") }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// URL scheme registered by the app shell for auth callbacks (Info.plist
    /// CFBundleURLTypes) — the server returns sign-ins here, never to
    /// arbitrary URLs.
    static let authCallbackScheme = "streetfoodos"

    /// Hosts that stay inside the app; anything else opens in the system browser.
    static func isAppHost(_ host: String) -> Bool {
        host == "app.streetfoodos.com"
            || host == "dev.streetfoodos.com"
            || host.hasSuffix(".streetfoodos.com")
            || host == "localhost"
    }
}
