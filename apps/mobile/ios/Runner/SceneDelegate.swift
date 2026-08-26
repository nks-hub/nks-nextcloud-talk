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
      if let url = activity.webpageURL {
        _ = deepLinks?.open(url)
      }
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
    if let url = userActivity.webpageURL {
      _ = deepLinks?.open(url)
    }
    super.scene(scene, continue: userActivity)
  }
}
