internal import Expo
import React
import ReactAppDependencyProvider

@main
class AppDelegate: ExpoAppDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ExpoReactNativeFactoryDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  public override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let delegate = ReactNativeDelegate()
    let factory = ExpoReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory
    _ = FlowEngine.shared

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Linking API
  public override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options) || RCTLinkingManager.application(app, open: url, options: options)
  }

  // Universal Links
  public override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    let result = RCTLinkingManager.application(application, continue: userActivity, restorationHandler: restorationHandler)
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler) || result
  }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var flowRequested = false

  private func noteFlow(_ url: URL) {
    if url.scheme == "scribe", url.host == "flow" { flowRequested = true }
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    let window = UIWindow(windowScene: windowScene)
    self.window = window
    appDelegate.window = window
    appDelegate.reactNativeFactory?.startReactNative(withModuleName: "main", in: window, launchOptions: nil)

    if let url = connectionOptions.urlContexts.first?.url {
      noteFlow(url)
      RCTLinkingManager.application(UIApplication.shared, open: url, options: [:])
    }
    if let activity = connectionOptions.userActivities.first {
      RCTLinkingManager.application(UIApplication.shared, continue: activity) { _ in }
    }
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      noteFlow(context.url)
      RCTLinkingManager.application(UIApplication.shared, open: context.url, options: [:])
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    guard flowRequested else { return }
    flowRequested = false
    let request = FlowShared.takeRequest(FlowShared.start, within: 15)
    Task {
      if let request {
        try? await FlowEngine.shared.begin(.keyboard, request: request)
      } else {
        try? await FlowEngine.shared.prepare()
      }
    }
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    RCTLinkingManager.application(UIApplication.shared, continue: userActivity) { _ in }
  }
}

class ReactNativeDelegate: ExpoReactNativeFactoryDelegate {
  // Extension point for config-plugins

  override func sourceURL(for bridge: RCTBridge) -> URL? {
    // needed to return the correct URL for expo-dev-client.
    bridge.bundleURL ?? bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: ".expo/.virtual-metro-entry")
#else
    return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
