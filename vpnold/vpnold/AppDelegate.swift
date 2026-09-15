import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // First thing, so a crash during setup is still recorded.
        CrashReport.beginSession()

        window = UIWindow(frame: UIScreen.main.bounds)
        // Navigation controller so Settings can be pushed off the VPN screen.
        let nav = UINavigationController(rootViewController: VPNViewController())
        nav.navigationBar.barStyle = .black
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        CrashReport.stage("window-visible")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        CrashReport.endSession()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        CrashReport.resumeSession()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        CrashReport.endSession()
    }
}
