import SwiftUI
import UIKit

@main
struct OffloadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var card = CardStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(card)
                .environment(Uploader.shared)
                .onOpenURL { settings.handle($0) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Reconnect to the background session straight away, so uploads that
        // finished while Offload was closed are delivered.
        Uploader.shared.restore()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Uploader.shared.backgroundEventsDone = completionHandler
        Uploader.shared.restore()
    }
}
