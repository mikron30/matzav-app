import CallKit
import Flutter
import UIKit

private final class MatzavAutomaticStatusMonitor: NSObject, CXCallObserverDelegate {
  private let callObserver = CXCallObserver()
  private weak var channel: FlutterMethodChannel?

  private var callsEnabled = false
  private var sleepEnabled = false
  private var derivedSleepActive = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func start(callsEnabled: Bool, sleepEnabled: Bool) {
    self.callsEnabled = callsEnabled
    self.sleepEnabled = sleepEnabled

    if callsEnabled {
      callObserver.setDelegate(self, queue: .main)
    } else {
      callObserver.setDelegate(nil, queue: nil)
    }

    if !sleepEnabled {
      derivedSleepActive = false
    }

    emitCurrentOverride()
  }

  func stop() {
    callsEnabled = false
    sleepEnabled = false
    derivedSleepActive = false
    callObserver.setDelegate(nil, queue: nil)
    emitOverride("none")
  }

  func setDerivedSleepActive(_ active: Bool) {
    derivedSleepActive = sleepEnabled && active
    emitCurrentOverride()
  }

  func currentOverride() -> String {
    if callsEnabled {
      // Match Android behavior: only an established conversation counts as
      // "onCall". Ringing/dialing alone does not change the user's status.
      let activeConnectedCall = callObserver.calls.contains {
        $0.hasConnected && !$0.hasEnded
      }
      if activeConnectedCall {
        return "onCall"
      }
    }

    if sleepEnabled && derivedSleepActive {
      return "sleeping"
    }

    return "none"
  }

  func diagnostics() -> [String: Any] {
    let calls = callObserver.calls
    return [
      "platform": "ios",
      "callsEnabled": callsEnabled,
      "sleepEnabled": sleepEnabled,
      "derivedSleepActive": derivedSleepActive,
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
  private var automaticStatusMonitor: MatzavAutomaticStatusMonitor?

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

    let monitor = MatzavAutomaticStatusMonitor(channel: channel)
    automaticStatusMonitor = monitor

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
        let sleepEnabled = args?["sleepEnabled"] as? Bool ?? true
        self.automaticStatusMonitor?.start(
          callsEnabled: callsEnabled,
          sleepEnabled: sleepEnabled
        )
        result(nil)

      case "stopMonitoring":
        self.automaticStatusMonitor?.stop()
        result(nil)

      case "getCurrentOverride":
        result(self.automaticStatusMonitor?.currentOverride() ?? "none")

      case "getCallDiagnostics":
        result(self.automaticStatusMonitor?.diagnostics() ?? [
          "platform": "ios",
          "callsEnabled": false,
          "sleepEnabled": false,
          "derivedSleepActive": false,
          "currentOverride": "none",
        ])

      case "setDerivedSleepActive":
        let args = call.arguments as? [String: Any]
        let active = args?["active"] as? Bool ?? false
        self.automaticStatusMonitor?.setDerivedSleepActive(active)
        result(self.automaticStatusMonitor?.currentOverride() ?? "none")

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
