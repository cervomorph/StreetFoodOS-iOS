import UIKit

/// App entry point. The app is a thin WKWebView shell around the StreetFoodOS
/// web app (same model as the Android container); no scene manifest — the
/// classic window lifecycle keeps the shell minimal.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Till behaviour — mirror the Android container's FLAG_KEEP_SCREEN_ON.
        application.isIdleTimerDisabled = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
