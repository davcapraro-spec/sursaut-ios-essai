import Flutter
import UIKit
import ImageCaptureCore

/// Pont « appareil photo » de Sursaut iPad (essai S2).
///
/// Cherche un appareil branché en USB-C (ImageCaptureCore), ouvre une
/// session, lit ce qu'il déclare, interroge le protocole PTP, télécharge
/// un fichier, et raconte tout ligne par ligne à l'écran de diagnostic.
public class CameraBridge: NSObject, FlutterStreamHandler, ICDeviceBrowserDelegate, ICCameraDeviceDownloadDelegate {
  private static var shared: CameraBridge?

  private var sink: FlutterEventSink?
  private var browser: ICDeviceBrowser?
  private var camera: ICCameraDevice?
  private var downloadStart: Date?
  private var downloadDir: URL?
  private var batches = 0

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CameraBridge()
    shared = instance
    let events = FlutterEventChannel(
      name: "sursaut/camera/events",
      binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    let methods = FlutterMethodChannel(
      name: "sursaut/camera/methods",
      binaryMessenger: registrar.messenger())
    methods.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start": start()
    case "openSession": openSession()
    case "ptpInfo": ptpInfo()
    case "takePicture": takePicture()
    case "downloadLatest": downloadLatest()
    case "state": state()
    case "stop": stop()
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    result(nil)
  }

  // MARK: - Flux de messages

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func log(_ text: String) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(["line": text])
    }
  }

  private func kv(_ object: NSObject, _ key: String) -> String {
    guard object.responds(to: NSSelectorFromString(key)) else { return "absent" }
    return String(describing: object.value(forKey: key) ?? "nil")
  }

  private func hex(_ value: Int) -> String {
    return "0x" + String(value, radix: 16, uppercase: true)
  }

  // MARK: - 1. Chercher l'appareil

  private func start() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.browser?.stop()
      let b = ICDeviceBrowser()
      b.delegate = self
      // 0x01 = appareils photo, 0x100 = branchés à cet appareil (USB).
      b.setValue(0x101, forKey: "browsedDeviceTypeMask")
      self.browser = b
      self.log("Navigateur créé. Autorisation contenu : \(self.kv(b, "contentsAuthorizationStatus")) · contrôle : \(self.kv(b, "controlAuthorizationStatus")) (0 = pas décidé, 1 = restreint, 2 = refusé, 3 = autorisé)")
      self.requestAuthorization(b, "requestContentsAuthorizationWithCompletion:", "contenu")
      self.requestAuthorization(b, "requestControlAuthorizationWithCompletion:", "contrôle")
      b.start()
      self.log("Recherche lancée (branchez l'appareil, mode USB « Pdv à distance »).")
    }
  }

  private func requestAuthorization(_ b: ICDeviceBrowser, _ selectorName: String, _ label: String) {
    let selector = NSSelectorFromString(selectorName)
    guard b.responds(to: selector) else {
      log("Demande d'autorisation \(label) : méthode absente sur cet iPadOS")
      return
    }
    let block: @convention(block) (Int) -> Void = { [weak self] status in
      self?.log("Autorisation \(label) → \(status)")
    }
    _ = b.perform(selector, with: unsafeBitCast(block, to: AnyObject.self))
  }

  public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    log("APPAREIL TROUVÉ : \(device.name ?? "sans nom") · \(device.productKind ?? "?") · transport \(device.transportType ?? "?") · USB \(hex(Int(device.usbVendorID))):\(hex(Int(device.usbProductID)))")
    log("Capacités déclarées : \(device.capabilities.joined(separator: ", "))")
    if let cam = device as? ICCameraDevice {
      camera = cam
      cam.setValue(self, forKey: "delegate")
    }
  }

  public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    log("Appareil retiré : \(device.name ?? "?")")
    if device == camera { camera = nil }
  }

  // MARK: - 2. Ouvrir la session

  private func openSession() {
    guard let cam = camera else {
      log("Aucun appareil : faites d'abord « 1. Chercher ».")
      return
    }
    cam.setValue(self, forKey: "delegate")
    log("Ouverture de session demandée…")
    cam.requestOpenSession()
  }

  @objc(device:didOpenSessionWithError:) public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    if let error = error {
      log("SESSION : ÉCHEC → \((error as NSError).domain) \((error as NSError).code) · \(error.localizedDescription)")
    } else {
      log("SESSION OUVERTE. Lecture du catalogue en cours…")
    }
  }

  @objc(device:didCloseSessionWithError:) public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    log("Session fermée" + (error.map { " (erreur : \($0.localizedDescription))" } ?? ""))
  }

  @objc(didRemoveDevice:) public func didRemove(_ device: ICDevice) {
    log("Appareil débranché.")
    if device == camera { camera = nil }
  }

  @objc(deviceDidBecomeReady:) public func deviceDidBecomeReady(_ device: ICDevice) {
    log("Appareil prêt à recevoir des demandes.")
  }

  @objc(device:didEncounterError:) public func device(_ device: ICDevice, didEncounterError error: Error?) {
    log("Erreur de l'appareil : \(error?.localizedDescription ?? "?")")
  }

  @objc(cameraDeviceDidChangeCapability:) public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
    log("Capacités modifiées : \(camera.capabilities.joined(separator: ", "))")
  }

  @objc(cameraDeviceDidEnableAccessRestriction:) public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
    log("Accès restreint par l'appareil.")
  }

  @objc(cameraDeviceDidRemoveAccessRestriction:) public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
    log("Accès restreint levé.")
  }

  // MARK: - Catalogue des fichiers

  @objc(cameraDevice:didAddItems:) public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
    batches += 1
    if batches <= 3 {
      let names = items.prefix(3).map { "\($0.name ?? "?") [\($0.uti ?? "?")]" }.joined(separator: " ; ")
      log("Fichiers annoncés : +\(items.count) (ex. \(names))")
    }
  }

  @objc(cameraDevice:didRemoveItems:) public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
    log("Fichiers retirés : \(items.count)")
  }

  @objc(cameraDevice:didRenameItems:) public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

  @objc(deviceDidBecomeReadyWithCompleteContentCatalog:) public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
    summarizeCatalog(device)
  }

  private func summarizeCatalog(_ cam: ICCameraDevice) {
    let files = cam.mediaFiles ?? []
    var arw = 0, jpeg = 0, other = 0
    for f in files {
      let n = (f.name ?? "").lowercased()
      if n.hasSuffix(".arw") { arw += 1 }
      else if n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") || n.hasSuffix(".hif") || n.hasSuffix(".heif") { jpeg += 1 }
      else { other += 1 }
    }
    log("CATALOGUE COMPLET : \(files.count) fichiers · ARW (RAW Sony) : \(arw) · JPEG/HEIF : \(jpeg) · autres : \(other)")
    if let last = files.last as? ICCameraFile {
      log("Dernier fichier : \(last.name ?? "?") · \(last.fileSize / 1_000_000) Mo · \(last.uti ?? "?")")
    }
  }

  // MARK: - 3. Informations PTP

  private func ptpInfo() {
    sendPTP(opcode: 0x1001, params: [], label: "GetDeviceInfo (0x1001)") { [weak self] data in
      self?.describeDeviceInfo(data)
    }
  }

  private func takePicture() {
    log("Déclenchement PTP standard (InitiateCapture 0x100E)… (peut prendre une photo)")
    sendPTP(opcode: 0x100E, params: [0, 0], label: "InitiateCapture (0x100E)", handler: nil)
  }

  private func le16(_ v: UInt16) -> Data {
    return Data([UInt8(v & 0xFF), UInt8(v >> 8)])
  }

  private func le32(_ v: UInt32) -> Data {
    return Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
  }

  private func sendPTP(opcode: UInt16, params: [UInt32], label: String, handler: ((Data) -> Void)?) {
    guard let cam = camera else {
      log("Aucun appareil : faites d'abord « 1. Chercher ».")
      return
    }
    var command = Data()
    command.append(le32(UInt32(12 + params.count * 4)))
    command.append(le16(1))
    command.append(le16(opcode))
    command.append(le32(0))
    for p in params { command.append(le32(p)) }
    log("PTP → \(label)")
    cam.requestSendPTPCommand(command, outData: nil) { [weak self] inData, response, error in
      guard let self = self else { return }
      var code = "?"
      let r = [UInt8](response)
      if r.count >= 8 { code = self.hex(Int(r[6]) | Int(r[7]) << 8) }
      if let error = error {
        self.log("PTP ← \(label) : ERREUR \((error as NSError).domain) \((error as NSError).code) · \(error.localizedDescription)")
      } else {
        self.log("PTP ← \(label) : réponse \(code) (0x2001 = OK) · données reçues \(inData.count) octets")
      }
      if !inData.isEmpty { handler?(inData) }
    }
  }

  private struct PTPReader {
    let bytes: [UInt8]
    var i = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    mutating func u16() -> Int? {
      guard i + 2 <= bytes.count else { return nil }
      let v = Int(bytes[i]) | Int(bytes[i + 1]) << 8
      i += 2
      return v
    }
    mutating func u32() -> Int? {
      guard i + 4 <= bytes.count else { return nil }
      let v = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
      i += 4
      return v
    }
    mutating func string() -> String? {
      guard i < bytes.count else { return nil }
      let n = Int(bytes[i])
      i += 1
      guard i + n * 2 <= bytes.count else { return nil }
      var units: [UInt16] = []
      for k in 0..<n { units.append(UInt16(bytes[i + 2 * k]) | UInt16(bytes[i + 2 * k + 1]) << 8) }
      i += n * 2
      if units.last == 0 { units.removeLast() }
      return String(decoding: units, as: UTF16.self)
    }
    mutating func list() -> [Int]? {
      guard let count = u32(), count < 5000 else { return nil }
      var out: [Int] = []
      for _ in 0..<count {
        guard let v = u16() else { return nil }
        out.append(v)
      }
      return out
    }
  }

  private func describeDeviceInfo(_ data: Data) {
    var body = data
    let raw = [UInt8](data)
    if raw.count >= 12 {
      let length = Int(raw[0]) | Int(raw[1]) << 8 | Int(raw[2]) << 16 | Int(raw[3]) << 24
      let type = Int(raw[4]) | Int(raw[5]) << 8
      if type == 2 && length == raw.count { body = data.subdata(in: 12..<data.count) }
    }
    var r = PTPReader(body)
    guard let version = r.u16(), let _ = r.u32(), let _ = r.u16(), let _ = r.string(), let _ = r.u16() else {
      log("GetDeviceInfo : données illisibles (\(data.count) octets)")
      return
    }
    let ops = r.list() ?? []
    let events = r.list() ?? []
    let props = r.list() ?? []
    let capture = r.list() ?? []
    let images = r.list() ?? []
    let maker = r.string() ?? "?"
    let model = r.string() ?? "?"
    let deviceVersion = r.string() ?? "?"
    let serial = r.string() ?? "?"
    log("PTP version \(Double(version) / 100) · \(maker) \(model) · firmware \(deviceVersion) · série \(serial)")
    log("Opérations (\(ops.count)) : " + ops.map { hex($0) }.joined(separator: " "))
    let standard: [(Int, String)] = [
      (0x100E, "InitiateCapture (déclencher)"), (0x1009, "GetObject (lire un fichier)"),
      (0x101B, "GetPartialObject (lecture partielle)"), (0x1014, "GetDevicePropDesc"),
      (0x1015, "GetDevicePropValue"), (0x1016, "SetDevicePropValue (régler)"),
      (0x101C, "InitiateOpenCapture"),
    ]
    for (code, name) in standard {
      log("  \(hex(code)) \(name) : " + (ops.contains(code) ? "OUI" : "non"))
    }
    let vendor = ops.filter { $0 >= 0x9000 }
    log("Opérations propres au constructeur (0x9xxx) : \(vendor.count)")
    log("Événements (\(events.count)) : " + events.map { hex($0) }.joined(separator: " "))
    log("Propriétés réglables (\(props.count)) : " + props.map { hex($0) }.joined(separator: " "))
    log("Formats de capture : " + capture.map { hex($0) }.joined(separator: " "))
    log("Formats d'image : " + images.map { hex($0) }.joined(separator: " "))
  }

  @objc(cameraDevice:didReceivePTPEvent:) public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
    let r = [UInt8](eventData)
    if r.count >= 8 {
      log("ÉVÉNEMENT PTP reçu : \(hex(Int(r[6]) | Int(r[7]) << 8)) (0x4002 = fichier ajouté)")
    } else {
      log("ÉVÉNEMENT PTP reçu (\(eventData.count) octets)")
    }
  }

  // MARK: - 4. Télécharger la dernière photo

  private func downloadLatest() {
    guard let cam = camera else {
      log("Aucun appareil : faites d'abord « 1. Chercher ».")
      return
    }
    let all = (cam.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
    let raws = all.filter { ($0.name ?? "").lowercased().hasSuffix(".arw") }
    guard let file = raws.last ?? all.last else {
      log("Aucun fichier dans le catalogue (session ouverte ? catalogue complet ?).")
      return
    }
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("banc_appareil", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    downloadDir = dir
    downloadStart = Date()
    log("Téléchargement : \(file.name ?? "?") (\(file.fileSize / 1_000_000) Mo)…")
    cam.requestDownloadFile(
      file,
      options: [
        ICDownloadOption.downloadsDirectoryURL: dir,
        ICDownloadOption.overwrite: true,
      ],
      downloadDelegate: self,
      didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
      contextInfo: nil)
  }

  @objc public func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any]?, contextInfo: UnsafeMutableRawPointer?) {
    let seconds = Date().timeIntervalSince(downloadStart ?? Date())
    if let error = error {
      log("TÉLÉCHARGEMENT : ÉCHEC → \((error as NSError).domain) \((error as NSError).code) · \(error.localizedDescription)")
      return
    }
    var message = "TÉLÉCHARGEMENT RÉUSSI en \(String(format: "%.1f", seconds)) s"
    if let dir = downloadDir {
      let path = dir.appendingPathComponent(file.name ?? "").path
      if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
         let size = attributes[.size] as? NSNumber {
        let mo = size.doubleValue / 1_000_000
        message += " · \(String(format: "%.1f", mo)) Mo · \(String(format: "%.1f", mo / max(seconds, 0.01))) Mo/s · fichier présent sur l'iPad"
      } else {
        message += " · fichier introuvable à \(path)"
      }
    }
    log(message)
  }

  // MARK: - 5. État

  private func state() {
    guard let cam = camera else {
      log("État : aucun appareil.")
      return
    }
    log("ÉTAT : session ouverte \(cam.hasOpenSession) · catalogue \(kv(cam, "contentCatalogPercentCompleted")) % · batterie \(kv(cam, "batteryLevel")) % (dispo \(kv(cam, "batteryLevelAvailable"))) · verrouillé \(kv(cam, "isLocked")) · accès restreint \(kv(cam, "isAccessRestrictedAppleDevice"))")
    let selectors = ["requestTakePicture", "requestEnableTethering", "tetheredCaptureEnabled", "requestSyncClock"]
    log("Méthodes présentes sur cet iPadOS : " + selectors.map { "\($0)=\(cam.responds(to: NSSelectorFromString($0)) ? "oui" : "non")" }.joined(separator: " · "))
    summarizeCatalog(cam)
  }

  private func stop() {
    camera?.requestCloseSession()
    browser?.stop()
    log("Arrêté.")
  }
}
