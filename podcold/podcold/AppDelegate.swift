import UIKit
import MediaPlayer

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let nav = UINavigationController(rootViewController: HomeVC())
        nav.navigationBar.barStyle = .black
        nav.navigationBar.tintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()

        let barH: CGFloat = 60
        let barY = UIScreen.main.bounds.height - barH
        let miniBar = MiniPlayerBar(frame: CGRect(x: 0, y: barY, width: UIScreen.main.bounds.width, height: barH))
        miniBar.isHidden = true
        window?.addSubview(miniBar)

        return true
    }

    // MARK: - Remote control events (lock screen / headphone controls, iOS 6+)

    override var canBecomeFirstResponder: Bool { return true }

    func applicationDidBecomeActive(_ application: UIApplication) {
        becomeFirstResponder()
        application.beginReceivingRemoteControlEvents()
    }

    override func remoteControlReceived(with event: UIEvent?) {
        guard let event = event, event.type == .remoteControl else { return }
        let ap = AudioPlayer.shared
        switch event.subtype {
        case .remoteControlPlay:
            ap.resume()
        case .remoteControlPause:
            ap.pause()
        case .remoteControlTogglePlayPause:
            ap.isPlaying ? ap.pause() : ap.resume()
        default:
            break
        }
    }
}
