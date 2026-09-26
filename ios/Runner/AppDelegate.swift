import CallKit
import Flutter
import UIKit

private final class MatzavCallMonitor: NSObject, CXCallObserverDelegate {
  private let observer = CXCallObserver()
  private weak var channel: FlutterMethodChannel?
  private var enabled = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func start() {
    enabled = true
    observer.setDelegate(self, queue: .main)
    emitCurrentOverride()
  }

  func stop() {
    enabled = false
    observer.setDelegate(nil, queue: nil)
    emitOverride("none")
  }

  func currentOverride() -> String {
    guard enabled else { return "none" }

    // Match Android behavior: only an established conversation counts as
    // "onCall". Ringing/dialing alone does not change the user's status.
    let activeConnectedCall = observer.calls.contains {
      $0.hasConnected && !$0.hasEnded
    }
    return activeConnectedCall ? "onCall" : "none"
  }

  func diagnostics() -> [String: Any] {
    let calls = observer.calls
    return [
      "platform": "ios",
      "enabled": enabled,
      "observedCallCount": calls.count,
      "connectedCallCount": calls.filter { $0.hasConnected && !$0.hasEnded }.count,
      "currentOverride": currentOverride(),
    ]
  }

  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    emitCurrentOverride()
  }

  private func emitCurrentOverride() {
    emitOverride(currentOverride())
  }

  private func emitOverride(_ value: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(
        "statusOverrideChanged",
        arguments: ["activity": value]
      )
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var automaticStatusChannel: FlutterMethodChannel?
  private var callMonitor: MatzavCallMonitor?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "com.mikron30.matzav/automatic_status",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    automaticStatusChannel = channel

    let monitor = MatzavCallMonitor(channel: channel)
    callMonitor = monitor

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "IOS_MONITOR_UNAVAILABLE",
            message: "Automatic status monitor is unavailable.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "startMonitoring":
        let args = call.arguments as? [String: Any]
        let callsEnabled = args?["callsEnabled"] as? Bool ?? true
        if callsEnabled {
          self.callMonitor?.start()
        } else {
          self.callMonitor?.stop()
        }
        result(nil)

      case "stopMonitoring":
        self.callMonitor?.stop()
        result(nil)

      case "getCurrentOverride":
        result(self.callMonitor?.currentOverride() ?? "none")

      case "getCallDiagnostics":
        result(self.callMonitor?.diagnostics() ?? [
          "platform": "ios",
          "enabled": false,
          "currentOverride": "none",
        ])

      // Driving is handled by the Flutter/Core Location automation on iOS.
      case "isDrivingActive":
        result(false)

      case "drivingReturnActivity":
        result(nil)

      case "forceDrivingInactive":
        result(false)

      case "syncDrivingStatus":
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
