import Flutter
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Pont Apple Pencil de Sursaut iPad.
///
/// Observe le Pencil sans jamais gêner Flutter : les touches continuent
/// d'arriver à Flutter, ce code ne fait que les lire (roulis, survol,
/// serrage, double appui) et les transmettre à Dart.
public class PencilBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler, UIPencilInteractionDelegate {
  private var sink: FlutterEventSink?
  private weak var hostView: UIView?
  private var probe: PencilTouchProbe?
  private var hover: UIHoverGestureRecognizer?
  private var interaction: UIPencilInteraction?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PencilBridgePlugin()
    let events = FlutterEventChannel(
      name: "sursaut/pencil/events",
      binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    let methods = FlutterMethodChannel(
      name: "sursaut/pencil/methods",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    CameraBridge.register(with: registrar)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result(capabilities())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Flux d'événements

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    DispatchQueue.main.async { [weak self] in
      self?.attach(retries: 20)
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    DispatchQueue.main.async { [weak self] in
      self?.detach()
    }
    return nil
  }

  private func send(_ payload: [String: Any]) {
    guard let target = sink else { return }
    if Thread.isMainThread {
      target(payload)
    } else {
      DispatchQueue.main.async { target(payload) }
    }
  }

  // MARK: - Attache à la vue Flutter

  private func findFlutterView() -> UIView? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        if let controller = window.rootViewController as? FlutterViewController {
          return controller.view
        }
      }
    }
    return nil
  }

  private func attach(retries: Int) {
    if hostView != nil { return }
    guard let view = findFlutterView() else {
      if retries > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.attach(retries: retries - 1)
        }
      } else {
        send(["type": "info", "message": "Vue Flutter introuvable : pont non attaché."])
      }
      return
    }
    hostView = view

    let touchProbe = PencilTouchProbe(target: nil, action: nil)
    touchProbe.emit = { [weak self] payload in self?.send(payload) }
    view.addGestureRecognizer(touchProbe)
    probe = touchProbe

    let hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
    view.addGestureRecognizer(hoverRecognizer)
    hover = hoverRecognizer

    var parts: [String] = ["contact", "survol"]
    if #available(iOS 17.5, *) {
      let pencilInteraction = UIPencilInteraction()
      pencilInteraction.delegate = self
      view.addInteraction(pencilInteraction)
      interaction = pencilInteraction
      parts.append("serrage")
      parts.append("double appui")
    }
    send(["type": "info", "message": "Pont attaché : " + parts.joined(separator: ", ")])
  }

  private func detach() {
    if let view = hostView {
      if let touchProbe = probe { view.removeGestureRecognizer(touchProbe) }
      if let hoverRecognizer = hover { view.removeGestureRecognizer(hoverRecognizer) }
      if let pencilInteraction = interaction { view.removeInteraction(pencilInteraction) }
    }
    probe = nil
    hover = nil
    interaction = nil
    hostView = nil
  }

  // MARK: - Survol

  @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
    guard let view = hostView else { return }
    let point = recognizer.location(in: view)
    var payload: [String: Any] = [
      "type": "hover",
      "phase": String(describing: recognizer.state),
      "x": Double(point.x),
      "y": Double(point.y),
    ]
    if #available(iOS 16.1, *) {
      payload["zOffset"] = Double(recognizer.zOffset)
    }
    if #available(iOS 16.4, *) {
      payload["altitude"] = Double(recognizer.altitudeAngle)
      payload["azimuth"] = Double(recognizer.azimuthAngle(in: view))
    }
    if #available(iOS 17.5, *) {
      payload["roll"] = Double(recognizer.rollAngle)
    }
    send(payload)
  }

  // MARK: - Double appui et serrage (iPadOS 17.5 et plus)

  @available(iOS 17.5, *)
  public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
    send(["type": "tap"])
  }

  @available(iOS 17.5, *)
  public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
    var payload: [String: Any] = [
      "type": "squeeze",
      "phase": String(describing: squeeze.phase),
    ]
    if let pose = squeeze.hoverPose {
      payload["hasPose"] = true
      payload["x"] = Double(pose.location.x)
      payload["y"] = Double(pose.location.y)
      payload["zOffset"] = Double(pose.zOffset)
      payload["altitude"] = Double(pose.altitudeAngle)
      payload["azimuth"] = Double(pose.azimuthAngle)
      payload["roll"] = Double(pose.rollAngle)
    } else {
      payload["hasPose"] = false
    }
    send(payload)
  }

  // MARK: - Ce que l'iPad dit de lui-même

  private func machineIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }

  private func capabilities() -> [String: Any] {
    let device = UIDevice.current
    var result: [String: Any] = [
      "machine": machineIdentifier(),
      "systemName": device.systemName,
      "systemVersion": device.systemVersion,
      "idiom": device.userInterfaceIdiom == .pad ? "iPad" : "autre",
      "bridgeAttached": hostView != nil,
      "preferredTapAction": String(describing: UIPencilInteraction.preferredTapAction),
    ]
    if #available(iOS 17.5, *) {
      result["squeezeApi"] = true
      result["preferredSqueezeAction"] = String(describing: UIPencilInteraction.preferredSqueezeAction)
    } else {
      result["squeezeApi"] = false
    }
    return result
  }
}

/// Lecteur passif des touches du Pencil : ne bloque rien, ne reconnaît rien.
final class PencilTouchProbe: UIGestureRecognizer {
  var emit: (([String: Any]) -> Void)?

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
    return false
  }

  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
    return false
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    report("began", touches, event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    report("moved", touches, event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    report("ended", touches, event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    report("cancelled", touches, event)
  }

  private func report(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent) {
    guard let host = view else { return }
    for touch in touches where touch.type == .pencil {
      let samples = event.coalescedTouches(for: touch)?.count ?? 1
      let point = touch.location(in: host)
      var payload: [String: Any] = [
        "type": "touch",
        "phase": phase,
        "x": Double(point.x),
        "y": Double(point.y),
        "force": Double(touch.force),
        "maxForce": Double(touch.maximumPossibleForce),
        "altitude": Double(touch.altitudeAngle),
        "azimuth": Double(touch.azimuthAngle(in: host)),
        "samples": samples,
      ]
      if #available(iOS 17.5, *) {
        payload["roll"] = Double(touch.rollAngle)
        payload["rollApi"] = true
      } else {
        payload["rollApi"] = false
      }
      emit?(payload)
    }
  }
}
