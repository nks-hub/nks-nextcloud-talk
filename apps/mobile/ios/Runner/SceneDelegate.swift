import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private var deepLinks: AppleDeepLinkDelivery? {
    (UIApplication.shared.delegate as? AppDelegate)?.deepLinks
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    for context in connectionOptions.urlContexts {
      _ = deepLinks?.open(context.url)
    }
    for activity in connectionOptions.userActivities {
      _ = deepLinks?.open(activity)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      _ = deepLinks?.open(context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    _ = deepLinks?.open(userActivity)
    super.scene(scene, continue: userActivity)
  }
}
