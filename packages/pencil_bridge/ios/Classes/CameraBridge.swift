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
  private var lastHandle: Int?
  private var receivedCount = 0
  private var quietSettings = false
  private var watchCodes: Set<Int> = []
  private var lastISO: Int? = nil
  private var lastValues: [Int: Int] = [:]
  private var protocol3 = false
  private var afterRead: (() -> Void)? = nil
  // Mode connecté (écran « Capturer »)
  private var liveReady = false
  private var lastChoices: [Int: [Int]] = [:]
  private var lastSizes: [Int: Int] = [:]
  private var lastWritable: [Int: Bool] = [:]
  private var lastEnabled: [Int: Bool] = [:]
  private var lastFilePath: String? = nil
  private var liveRefreshing = false
  private var liveRefreshAgain = false
  private var liveBusy = false
  private var lastRanges: [Int: (lo: Int, hi: Int)] = [:]
  private var pendingSet: (code: Int, value: Int, ok: Bool, since: Date)? = nil

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
    if call.method == "previewLast" {
      result(previewLast())
      return
    }
    if call.method == "liveAF" {
      guard let a = call.arguments as? [String: Any], let x = a["x"] as? Int, let y = a["y"] as? Int else {
        result(FlutterError(code: "args", message: "liveAF : x et y attendus", details: nil))
        return
      }
      afPoint(0xD2DC, max(0, min(639, x)), max(0, min(479, y)), "touché sur l'image", quiet: true)
      result(nil)
      return
    }
    if call.method == "liveFrame" {
      result(liveFramePath())
      return
    }
    if call.method == "liveSnapshot" {
      result(liveSnapshot())
      return
    }
    if call.method == "liveSet" {
      guard let a = call.arguments as? [String: Any], let code = a["code"] as? Int, let value = a["value"] as? Int else {
        result(FlutterError(code: "args", message: "liveSet : code et value attendus", details: nil))
        return
      }
      liveSet(code, value)
      result(nil)
      return
    }
    switch call.method {
    case "liveStreamStart": liveStreamStart()
    case "liveStreamStop": liveStreamStop()
    case "liveFocus": liveFocus()
    case "liveviewTest": liveviewTest()
    case "afTopLeft": afPoint(0xD2DC, 0, 0, "coin haut gauche")
    case "afCenter": afPoint(0xD2DC, 320, 240, "centre")
    case "afBottomRight": afPoint(0xD2DC, 639, 479, "coin bas droit")
    case "touchCenter": touchCenter()
    case "liveStart": start()
    case "liveOpen": openSession()
    case "liveHandshake": sonyConnect3()
    case "liveRefresh": liveRefresh()
    case "liveShoot": liveShoot()
    case "liveStop": liveStop()
    case "start": start()
    case "openSession": openSession()
    case "ptpInfo": ptpInfo()
    case "takePicture": takePicture()
    case "sonyConnect": sonyConnect()
    case "iccShoot": iccShoot()
    case "readObject": readObject()
    case "sonyShoot": sonyShoot()
    case "burst": burst(5)
    case "readSettings": readSettings()
    case "writeISO": writeProperty(0xD21E, 4, "ISO") { $0 == 100 ? 200 : 100 }
    case "writeAperture": writeProperty(0x5007, 2, "ouverture") { $0 == 0x276 ? 0x230 : 0x276 }
    case "writeShutter": writeProperty(0xD20D, 4, "vitesse") { $0 == 0x10064 ? 0x1007D : 0x10064 }
    case "sonyConnect3": sonyConnect3()
    case "shareFiles": shareFiles(onlyLast: false)
    case "shareLast": shareFiles(onlyLast: true)
    case "clearFiles": clearFiles()
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
      // Ne jamais recréer le navigateur : le recréer fait perdre l'appareil déjà trouvé.
      if self.browser != nil {
        if let cam = self.camera {
          self.log("Recherche déjà en cours. Appareil déjà connu : \(cam.name ?? "?"). Passez à « 2. Ouvrir la session ».")
        } else {
          self.log("Recherche déjà en cours. Aucun appareil pour l'instant : débranchez puis rebranchez le câble USB-C.")
        }
        return
      }
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
    liveReady = false
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
    liveReady = false
    log("Session fermée" + (error.map { " (erreur : \($0.localizedDescription))" } ?? ""))
  }

  @objc(didRemoveDevice:) public func didRemove(_ device: ICDevice) {
    log("Appareil débranché.")
    liveReady = false
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


  // MARK: - 6. Poignée de main Sony (expérimental)

  /// Séquence de connexion propre à Sony, d'après des projets libres
  /// (non vérifiée sur cet appareil) : SDIOConnect 1, 2, lecture des infos
  /// étendues, SDIOConnect 3. Sans elle, l'appareil n'annonce peut-être
  /// pas les nouvelles photos à l'iPad.
  private func sonyConnect() {
    protocol3 = false
    log("POIGNÉE DE MAIN SONY (expérimentale) : 0x9201 (1) → 0x9201 (2) → 0x9202 → 0x9201 (3)")
    let steps: [(UInt16, [UInt32], String)] = [
      (0x9201, [1, 0, 0], "SDIOConnect phase 1 (0x9201)"),
      (0x9201, [2, 0, 0], "SDIOConnect phase 2 (0x9201)"),
      (0x9202, [0xC8], "SDIOGetExtDeviceInfo (0x9202)"),
      (0x9201, [3, 0, 0], "SDIOConnect phase 3 (0x9201)"),
    ]
    runSteps(steps, 0)
  }

  /// Poignée de main au protocole « Camera Control PTP 3 » (version 3.00 = 0x012C),
  /// celui que Sony recommande pour l'A7 IV (le PTP 2 est annoncé comme déprécié).
  private func sonyConnect3() {
    protocol3 = true
    log("POIGNÉE DE MAIN SONY PTP 3 : 0x9201 (1) → 0x9201 (2) → 0x9202 (version 0x012C) → 0x9201 (3)")
    let steps: [(UInt16, [UInt32], String)] = [
      (0x9201, [1, 0, 0], "SDIOConnect phase 1 (0x9201)"),
      (0x9201, [2, 0, 0], "SDIOConnect phase 2 (0x9201)"),
      (0x9202, [0x012C, 0], "SDIOGetExtDeviceInfo version 3.00 (0x9202)"),
      (0x9201, [3, 0, 0], "SDIOConnect phase 3 (0x9201)"),
    ]
    runSteps(steps, 0)
  }

  private func runSteps(_ steps: [(UInt16, [UInt32], String)], _ index: Int) {
    if index >= steps.count {
      liveReady = protocol3
      log("Séquence terminée. Prenez maintenant une photo au déclencheur et guettez « ÉVÉNEMENT PTP ».")
      return
    }
    let step = steps[index]
    sendPTP(opcode: step.0, params: step.1, label: step.2, handler: { [weak self] data in
      self?.log("  données reçues : \(data.count) octets")
    }, done: { [weak self] ok in
      if ok {
        self?.runSteps(steps, index + 1)
      } else {
        self?.log("Séquence arrêtée à l'étape \(index + 1) (réponse différente de 0x2001).")
      }
    })
  }

  // MARK: - 7. Photo par iPadOS (requestTakePicture)

  private func iccShoot() {
    guard let cam = camera else {
      log("Aucun appareil : faites d'abord « 1. Chercher ».")
      return
    }
    for name in ["requestEnableTethering", "requestTakePicture"] {
      let selector = NSSelectorFromString(name)
      if cam.responds(to: selector) {
        log("iPadOS : appel de \(name)…")
        _ = cam.perform(selector)
      } else {
        log("iPadOS : \(name) absent.")
      }
    }
  }

  // MARK: - 8. Lire la photo annoncée

  private func stripContainer(_ data: Data) -> Data {
    let raw = [UInt8](data)
    if raw.count >= 12 {
      let type = Int(raw[4]) | Int(raw[5]) << 8
      if type == 2 { return data.subdata(in: 12..<data.count) }
    }
    return data
  }

  private func readObject() {
    let handle = UInt32(lastHandle ?? 0xFFFFC001)
    log("Lecture de l'objet \(hex(Int(handle))) : GetObjectInfo (0x1008) puis GetObject (0x1009)")
    var name = "objet.bin"
    sendPTP(opcode: 0x1008, params: [handle], label: "GetObjectInfo (0x1008)", handler: { [weak self] data in
      guard let self = self else { return }
      var r = PTPReader(self.stripContainer(data))
      guard let _ = r.u32(), let format = r.u16(), let _ = r.u16(), let size = r.u32(),
            let _ = r.u16(), let _ = r.u32(), let _ = r.u32(), let _ = r.u32(),
            let w = r.u32(), let h = r.u32(), let _ = r.u32(), let _ = r.u32(),
            let _ = r.u16(), let _ = r.u32(), let _ = r.u32() else {
        self.log("  GetObjectInfo : données illisibles (\(data.count) octets)")
        return
      }
      let file = r.string() ?? "?"
      if file != "?" && !file.isEmpty { name = file }
      self.log("  OBJET : \(file) · format \(self.hex(format)) · \(size / 1_000_000) Mo · \(w) × \(h) px")
    }, done: { [weak self] ok in
      guard let self = self else { return }
      if !ok { self.log("  GetObjectInfo n'a pas répondu 0x2001 ; on tente quand même GetObject.") }
      self.getObject(handle, name)
    })
  }

  private func getObject(_ handle: UInt32, _ name: String) {
    let start = Date()
    sendPTP(opcode: 0x1009, params: [handle], label: "GetObject (0x1009)", handler: { [weak self] data in
      guard let self = self else { return }
      let body = self.stripContainer(data)
      let seconds = Date().timeIntervalSince(start)
      let mo = Double(body.count) / 1_000_000
      let sig = [UInt8](body.prefix(4)).map { String(format: "%02X", $0) }.joined(separator: " ")
      var message = "OBJET REÇU : \(String(format: "%.1f", mo)) Mo en \(String(format: "%.1f", seconds)) s (\(String(format: "%.1f", mo / max(seconds, 0.01))) Mo/s) · début du fichier : \(sig) (FF D8 = JPEG ; 49 49 2A 00 = ARW)"
      if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("banc_appareil", isDirectory: true) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
          try body.write(to: dir.appendingPathComponent(name))
          message += " · enregistré : \(name)"
          self.receivedCount += 1
          self.lastFilePath = dir.appendingPathComponent(name).path
          self.streamPaused = false
          self.emitPhoto(name, body.count, seconds)
        } catch {
          message += " · écriture impossible : \(error.localizedDescription)"
        }
      }
      self.log(message)
    })
  }

  // MARK: - 9. Déclencher depuis l'iPad (Sony 0x9207, expérimental)

  /// Séquence de déclenchement d'après des projets libres (non vérifiée) :
  /// opération 0x9207, propriété 0xD2C1 (mise au point) puis 0xD2C2
  /// (déclenchement) ; valeur 2 = appui, 1 = relâchement.
  private func sonyShoot(then: (() -> Void)? = nil) {
    log("DÉCLENCHEMENT SONY (expérimental) : 0x9207 sur 0xD2C1 puis 0xD2C2 (peut prendre une photo)")
    let steps: [(UInt32, UInt16, String)] = [
      (0xD2C1, 2, "mise au point : appui"),
      (0xD2C2, 2, "déclencheur : appui"),
      (0xD2C2, 1, "déclencheur : relâché"),
      (0xD2C1, 1, "mise au point : relâchée"),
    ]
    runControl(steps, 0, then)
  }

  private func runControl(_ steps: [(UInt32, UInt16, String)], _ index: Int, _ then: (() -> Void)? = nil) {
    if index >= steps.count {
      log("Séquence de déclenchement terminée. Une photo doit arriver (événement 0xC201).")
      then?()
      return
    }
    let step = steps[index]
    sendPTP(opcode: 0x9207, params: [step.0], label: "SetControlDeviceB 0x9207 · \(step.2)", handler: nil, outData: le16(step.1), done: { [weak self] ok in
      guard let self = self else { return }
      if !ok { self.log("  cette étape n'a pas répondu 0x2001 ; on continue pour relâcher proprement.") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.runControl(steps, index + 1, then)
      }
    })
  }

  // MARK: - 13. Lire les réglages de l'appareil (Sony 0x9209)

  private func typeSize(_ t: Int) -> Int? {
    switch t {
    case 1, 2: return 1
    case 3, 4: return 2
    case 5, 6: return 4
    case 7, 8: return 8
    default: return nil
    }
  }

  private func propName(_ code: Int) -> String {
    switch code {
    case 0x5001: return "batterie (probable)"
    case 0x5005: return "balance des blancs (probable)"
    case 0x5007: return "ouverture ƒ (probable)"
    case 0x500A: return "mode de mise au point (probable)"
    case 0x500B: return "zone / mesure de mise au point (hypothèse)"
    case 0xD218: return "batterie % (hypothèse)"
    case 0xD20F: return "température de couleur K (hypothèse)"
    case 0x500E: return "mode d'exposition (probable)"
    case 0x500F: return "ISO (probable)"
    case 0x5010: return "compensation d'exposition (probable)"
    case 0x5013: return "entraînement (probable)"
    case 0xD20D: return "vitesse d'obturation (probable)"
    case 0xD21E: return "ISO Sony (probable)"
    default: return "?"
    }
  }

  private func interp(_ code: Int, _ cur: UInt64) -> String {
    switch code {
    case 0x5007: return " ≈ ƒ/" + String(format: "%.1f", Double(cur) / 100)
    case 0xD20D:
      let den = Int(truncatingIfNeeded: cur & 0xFFFF), num = Int(truncatingIfNeeded: cur >> 16)
      return den > 0 ? " ≈ \(num)/\(den) s" : ""
    case 0xD21E: return " ≈ ISO \(cur)"
    case 0xD218: return " ≈ \(Int(Int8(truncatingIfNeeded: cur))) %"
    case 0xD20F: return " ≈ \(cur) K"
    default: return ""
    }
  }

  private func readSettings(quiet: Bool = false, watch: Set<Int> = [], then: (() -> Void)? = nil) {
    quietSettings = quiet
    watchCodes = watch
    afterRead = then
    sendPTP(opcode: 0x9209, params: protocol3 ? [0, 0] : [], label: "SDIOGetAllExtDevicePropInfo (0x9209)\(protocol3 ? " PTP 3" : "")", handler: { [weak self] data in
      self?.parseSettings(self?.stripContainer(data) ?? data)
    }, done: { [weak self] ok in
      if !ok { self?.afterRead = nil; self?.quietSettings = false }
    })
  }

  private func parseSettings(_ body: Data) {
    let quiet = quietSettings
    let watch = watchCodes
    let b = [UInt8](body)
    let n = b.count
    if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("banc_appareil", isDirectory: true) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try? body.write(to: dir.appendingPathComponent("reglages_0x9209.bin"))
    }
    func hexDump(_ from: Int, _ count: Int) -> String {
      return b[from..<min(n, from + count)].map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    if !quiet { log("RÉGLAGES : \(n) octets reçus, début : \(hexDump(0, 40))") }
    var off = 0
    while off < n && !quiet {
      log("  HEX \(off) : \(hexDump(off, 48))")
      off += 48
    }
    var pos = 0
    func rd(_ size: Int) -> UInt64? {
      guard pos + size <= n else { return nil }
      var v: UInt64 = 0
      for k in 0..<size { v |= UInt64(b[pos + k]) << UInt64(8 * k) }
      pos += size
      return v
    }
    // En-tête éventuel : nombre de propriétés sur 8 octets.
    var expected = -1
    if n >= 8 {
      var c: UInt64 = 0
      for k in 0..<8 { c |= UInt64(b[k]) << UInt64(8 * k) }
      if c >= 1 && c <= 500 { expected = Int(truncatingIfNeeded: c); pos = 8 }
    }
    if !quiet { log("RÉGLAGES : \(expected >= 0 ? "\(expected) propriétés annoncées" : "pas d'en-tête de nombre (lecture directe)")") }
    var count = 0
    while pos + 6 <= n && (expected < 0 || count < expected) {
      let startPos = pos
      guard let code = rd(2), let type = rd(2), let getSet = rd(1), let enabled = rd(1) else { break }
      // Propriété de type texte (0xFFFF) : défaut, actuel = chaînes PTP (1 octet = nb de caractères, puis UTF-16), puis forme.
      if type == 0xFFFF, (code & 0xF000) == 0x5000 || (code & 0xF000) == 0xD000 || (code & 0xF000) == 0xE000 {
        func rdString() -> String? {
          guard let len = rd(1) else { return nil }
          var chars: [UInt16] = []
          for _ in 0..<Int(len) { guard let c = rd(2) else { return nil }; chars.append(UInt16(c)) }
          if let last = chars.last, last == 0 { chars.removeLast() }
          return String(decoding: chars, as: UTF16.self)
        }
        guard let _ = rdString(), let curS = rdString(), let _ = rd(1) else { break }
        count += 1
        if watch.contains(Int(truncatingIfNeeded: code)) || (!quiet && !curS.isEmpty) { log("  \(hex(Int(truncatingIfNeeded: code))) texte · \(getSet == 1 ? "modifiable" : "lecture seule") · « \(curS) »") }
        continue
      }
      guard (code & 0xF000) == 0x5000 || (code & 0xF000) == 0xD000 || (code & 0xF000) == 0xE000, let size = typeSize(Int(type)) else {
        log("RÉGLAGES : analyse incertaine à l'octet \(startPos) : \(hexDump(startPos, 32))")
        break
      }
      guard let def = rd(size), let cur = rd(size), let form = rd(1) else { break }
      var choices = ""
      var lists0: [UInt64] = []
      if form == 1 {
        if let lo = rd(size), let hi = rd(size), let st = rd(size) {
          choices = " · plage \(hex(Int(truncatingIfNeeded: lo)))…\(hex(Int(truncatingIfNeeded: hi))) pas \(hex(Int(truncatingIfNeeded: st)))"
          lastRanges[Int(truncatingIfNeeded: code)] = (Int(truncatingIfNeeded: lo), Int(truncatingIfNeeded: hi))
        }
      } else if form == 2 {
        var lists: [[UInt64]] = []
        for round in 0..<2 {
          // Après la 1re liste, un code de propriété (0x5xxx / 0xDxxx) signale la propriété suivante.
          if round == 1 && pos + 2 <= n {
            let peek = Int(b[pos]) | Int(b[pos + 1]) << 8
            if (peek & 0xF000) == 0x5000 || (peek & 0xF000) == 0xD000 || (peek & 0xF000) == 0xE000 { break }
          }
          guard let k = rd(2), k < 2000 else { break }
          var vals: [UInt64] = []
          for _ in 0..<Int(k) { if let v = rd(size) { vals.append(v) } }
          lists.append(vals)
        }
        lists0 = lists.first ?? []
        if let l = lists.first, !l.isEmpty {
          let shown = l.prefix(14).map { hex(Int(truncatingIfNeeded: $0)) }.joined(separator: " ")
          choices = " · \(l.count) choix : \(shown)\(l.count > 14 ? " …" : "")"
        }
      }
      count += 1
      if Int(truncatingIfNeeded: code) == 0xD21E { lastISO = Int(truncatingIfNeeded: cur) }
      lastValues[Int(truncatingIfNeeded: code)] = Int(truncatingIfNeeded: cur)
      lastSizes[Int(truncatingIfNeeded: code)] = size
      lastWritable[Int(truncatingIfNeeded: code)] = (getSet == 1)
      lastEnabled[Int(truncatingIfNeeded: code)] = (enabled == 1)
      lastChoices[Int(truncatingIfNeeded: code)] = (form == 2) ? (lists0.map { Int(truncatingIfNeeded: $0) }) : []
      if !quiet || watch.contains(Int(truncatingIfNeeded: code)) { log("  \(hex(Int(truncatingIfNeeded: code))) \(propName(Int(truncatingIfNeeded: code))) · type \(type) · \(getSet == 1 ? "modifiable" : "lecture seule") · \(enabled == 1 ? "actif" : "inactif") · défaut \(hex(Int(truncatingIfNeeded: def))) · ACTUEL \(hex(Int(truncatingIfNeeded: cur)))\(interp(Int(truncatingIfNeeded: code), cur))\(choices)") }
    }
    if !quiet { log("RÉGLAGES : \(count) propriété(s) lue(s). Fichier brut : reglages_0x9209.bin (dans le partage).") }
    let callback = afterRead
    afterRead = nil
    quietSettings = false
    emitState()
    resolvePendingSet()
    callback?()
  }

  // MARK: - 14 à 16. Écrire un réglage (SetExtDevicePropValue 0x9205, protocole PTP 3)

  /// Lit la valeur actuelle, demande la valeur choisie par `pick`, relit, et dit
  /// si l'appareil a pris le changement. Nécessite la poignée de main PTP 3 (« 6b »).
  private func writeProperty(_ code: Int, _ size: Int, _ name: String, _ pick: @escaping (Int) -> Int) {
    guard camera != nil else {
      log("Aucun appareil : faites d'abord 1, 2 puis 6b.")
      return
    }
    guard protocol3 else {
      log("ÉCRITURE : faites d'abord « 6b. Poignée de main PTP 3 » (l'ancien protocole ne règle pas \(name) directement).")
      return
    }
    log("ÉCRITURE (essai) : \(name) par SetExtDevicePropValue 0x9205 sur la propriété \(hex(code)).")
    readSettings(quiet: true, watch: [code]) { [weak self] in
      guard let self = self, let old = self.lastValues[code] else {
        self?.log("ÉCRITURE : valeur actuelle de \(name) introuvable, essai annulé.")
        return
      }
      let wanted = pick(old)
      self.log("ÉCRITURE : \(name) actuel \(self.hex(old)), demandé \(self.hex(wanted)).")
      let payload = size == 2 ? self.le16(UInt16(truncatingIfNeeded: wanted)) : self.le32(UInt32(truncatingIfNeeded: wanted))
      self.sendPTP(opcode: 0x9205, params: [UInt32(code), 0], label: "SetExtDevicePropValue 0x9205 · \(name) \(self.hex(wanted))", handler: nil, outData: payload, done: { [weak self] ok in
        guard let self = self else { return }
        self.log("ÉCRITURE : l'appareil répond \(ok ? "OK (0x2001)" : "autre chose que 0x2001"). Relecture dans 1 s…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          self?.readSettings(quiet: true, watch: [code]) { [weak self] in
            guard let self = self else { return }
            let now = self.lastValues[code] ?? -1
            self.log("ÉCRITURE : \(name) avant \(self.hex(old)) · demandé \(self.hex(wanted)) · relu \(self.hex(now)) → " + (now == wanted ? "CHANGEMENT PRIS" : "PAS DE CHANGEMENT"))
          }
        }
      })
    }
  }

  // MARK: - 11. Rafale de 5 photos / 12. Partager les fichiers

  private var burstRunning = false

  /// Déclenche `total` photos l'une après l'autre (2 s entre chaque) et
  /// compte celles qui arrivent réellement sur l'iPad.
  private func burst(_ total: Int) {
    if burstRunning {
      log("RAFALE déjà en cours.")
      return
    }
    guard camera != nil else {
      log("Aucun appareil : faites d'abord « 1. Chercher », « 2. Ouvrir la session » et « 6. Poignée de main ».")
      return
    }
    burstRunning = true
    let before = receivedCount
    let started = Date()
    log("RAFALE : \(total) photos, une toutes les 2 s environ (appareil en RAW, objectif dégagé).")
    nextBurst(1, total, before, started)
  }

  private func nextBurst(_ i: Int, _ total: Int, _ before: Int, _ started: Date) {
    if i > total {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        guard let self = self else { return }
        let got = self.receivedCount - before
        let secs = Date().timeIntervalSince(started)
        self.log("RAFALE TERMINÉE : \(got) photo(s) reçue(s) sur \(total) demandée(s), en \(String(format: "%.0f", secs)) s. " + (got == total ? "TOUT EST ARRIVÉ." : "IL EN MANQUE."))
        self.burstRunning = false
      }
      return
    }
    log("RAFALE : photo \(i) sur \(total)")
    sonyShoot(then: { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        self?.nextBurst(i + 1, total, before, started)
      }
    })
  }

  /// Ouvre la feuille de partage d'iPadOS avec tous les fichiers reçus
  /// (Enregistrer dans Fichiers, AirDrop, etc.).
  private func shareFiles(onlyLast: Bool) {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("banc_appareil", isDirectory: true)
    let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var files = all.filter { !$0.lastPathComponent.hasPrefix("apercu_") && $0.pathExtension.lowercased() != "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    if onlyLast, let last = files.last { files = [last] }
    if files.isEmpty {
      log("PARTAGE : aucun fichier à partager.")
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      var top = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })?.rootViewController }
        .first
      while let presented = top?.presentedViewController { top = presented }
      guard let vc = top else {
        self.log("PARTAGE : écran introuvable.")
        return
      }
      let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = vc.view
      sheet.popoverPresentationController?.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
      sheet.popoverPresentationController?.permittedArrowDirections = []
      vc.present(sheet, animated: true)
      let total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      self.log("PARTAGE : \(files.count) fichier(s), \(String(format: "%.1f", Double(total) / 1_000_000)) Mo proposés à la feuille de partage.")
    }
  }

  /// Vide le dossier des fichiers reçus (cache de l'app uniquement).
  private func clearFiles() {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("banc_appareil", isDirectory: true)
    let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var removed = 0
    for f in all {
      if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
    }
    log("FICHIERS REÇUS : \(removed) fichier(s) supprimé(s) du cache de l'app (les copies déjà enregistrées dans Fichiers ne sont pas touchées).")
  }

  // MARK: - 10. Aperçu de la dernière photo (JPEG intégré au RAW)

  private func jpegExtent(_ b: UnsafeBufferPointer<UInt8>, _ start: Int) -> (start: Int, end: Int, w: Int, h: Int)? {
    let n = b.count
    var p = start + 2
    var w = 0
    var h = 0
    while p + 4 <= n {
      if b[p] != 0xFF { return nil }
      let m = b[p + 1]
      if m == 0xFF { p += 1; continue }
      if m == 0xD9 { return nil }
      let len = (Int(b[p + 2]) << 8) | Int(b[p + 3])
      if (m == 0xC0 || m == 0xC1 || m == 0xC2) && p + 9 <= n {
        h = (Int(b[p + 5]) << 8) | Int(b[p + 6])
        w = (Int(b[p + 7]) << 8) | Int(b[p + 8])
      }
      if m == 0xDA {
        var q = p + 2 + len
        while q + 1 < n {
          if b[q] == 0xFF {
            let nx = b[q + 1]
            if nx == 0xD9 { return (start, q + 2, w, h) }
            if nx == 0x00 || (nx >= 0xD0 && nx <= 0xD7) || nx == 0xFF { q += 2; continue }
          }
          q += 1
        }
        return nil
      }
      p += 2 + len
    }
    return nil
  }

  /// Cherche dans le dernier fichier reçu le plus grand JPEG intégré (les RAW
  /// Sony en contiennent un), l'enregistre et renvoie son chemin.
  private func previewLast() -> String? {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("banc_appareil", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
      log("APERÇU : aucun fichier reçu pour l'instant.")
      return nil
    }
    func modified(_ u: URL) -> Date {
      return (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
    }
    let candidates = files.filter { !$0.lastPathComponent.hasPrefix("apercu_") }
    guard let newest = candidates.max(by: { modified($0) < modified($1) }) else {
      log("APERÇU : aucun fichier reçu pour l'instant.")
      return nil
    }
    guard let data = try? Data(contentsOf: newest, options: .mappedIfSafe) else {
      log("APERÇU : impossible de lire \(newest.lastPathComponent).")
      return nil
    }
    var best: (start: Int, end: Int, w: Int, h: Int)? = nil
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let b = raw.bindMemory(to: UInt8.self)
      let n = b.count
      var i = 0
      while i + 4 < n {
        if b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF {
          if let r = jpegExtent(b, i) {
            if best == nil || (r.end - r.start) > (best!.end - best!.start) { best = r }
            i = r.end
            continue
          }
        }
        i += 1
      }
    }
    guard let r = best else {
      log("APERÇU : aucun JPEG intégré trouvé dans \(newest.lastPathComponent).")
      return nil
    }
    for old in files where old.lastPathComponent.hasPrefix("apercu_") {
      try? FileManager.default.removeItem(at: old)
    }
    let out = dir.appendingPathComponent("apercu_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
    do {
      try data.subdata(in: r.start..<r.end).write(to: out)
    } catch {
      log("APERÇU : écriture impossible : \(error.localizedDescription)")
      return nil
    }
    let mo = Double(r.end - r.start) / 1_000_000.0
    log("APERÇU : JPEG intégré de \(String(format: "%.2f", mo)) Mo, \(r.w) × \(r.h) px, extrait de \(newest.lastPathComponent).")
    return out.path
  }

  private func le16(_ v: UInt16) -> Data {
    return Data([UInt8(v & 0xFF), UInt8(v >> 8)])
  }

  private func le32(_ v: UInt32) -> Data {
    return Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
  }

  private func sendPTP(opcode: UInt16, params: [UInt32], label: String, handler: ((Data) -> Void)?, outData: Data? = nil, silent: Bool = false, done: ((Bool) -> Void)? = nil) {
    guard let cam = camera else {
      log("Aucun appareil : faites d'abord « 1. Chercher ».")
      done?(false)
      return
    }
    var command = Data()
    command.append(le32(UInt32(12 + params.count * 4)))
    command.append(le16(1))
    command.append(le16(opcode))
    command.append(le32(0))
    for p in params { command.append(le32(p)) }
    if !silent { log("PTP → \(label)") }
    cam.requestSendPTPCommand(command, outData: outData) { [weak self] inData, response, error in
      guard let self = self else { return }
      var code = "?"
      let r = [UInt8](response)
      if r.count >= 8 { code = self.hex(Int(r[6]) | Int(r[7]) << 8) }
      if let error = error {
        self.log("PTP ← \(label) : ERREUR \((error as NSError).domain) \((error as NSError).code) · \(error.localizedDescription)")
      } else if !silent || code != "0x2001" {
        self.log("PTP ← \(label) : réponse \(code) (0x2001 = OK) · données reçues \(inData.count) octets")
      }
      if !inData.isEmpty { handler?(inData) }
      done?(error == nil && code == "0x2001")
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
    guard r.count >= 8 else {
      log("ÉVÉNEMENT PTP reçu (\(eventData.count) octets)")
      return
    }
    let code = Int(r[6]) | Int(r[7]) << 8
    var params: [Int] = []
    var i = 12
    while i + 4 <= r.count {
      params.append(Int(r[i]) | Int(r[i + 1]) << 8 | Int(r[i + 2]) << 16 | Int(r[i + 3]) << 24)
      i += 4
    }
    let text = params.map { hex($0) }.joined(separator: " ")
    log("ÉVÉNEMENT PTP \(hex(code))" + (params.isEmpty ? "" : " · paramètres : \(text)"))
    if code == 0xC203 && liveReady { liveRefresh() }
    if code == 0xC201, let first = params.first {
      lastHandle = first
      log("  → objet annoncé : \(hex(first)) : lecture automatique…")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.readObject() }
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


  // MARK: - Mode connecté (écran « Capturer »)

  /// Propriétés que l'écran de capture présente.
  private let liveCodes: [Int] = [0xD21E, 0x5007, 0xD20D, 0x5005, 0x500E, 0x5010, 0x500A, 0x5013, 0xD222, 0xD218, 0xD20F]

  /// État complet pour Dart : appareil, session, poignée de main, réglages (valeur, droits, choix).
  private func liveSnapshot() -> [String: Any] {
    var props: [String: Any] = [:]
    for c in liveCodes {
      guard let cur = lastValues[c] else { continue }
      props[String(c)] = [
        "cur": cur,
        "w": lastWritable[c] ?? false,
        "on": lastEnabled[c] ?? true,
        "size": lastSizes[c] ?? 0,
        "ch": lastChoices[c] ?? [],
      ] as [String: Any]
    }
    var out: [String: Any] = [
      "found": camera != nil,
      "session": camera?.hasOpenSession ?? false,
      "ready": liveReady,
      "received": receivedCount,
      "props": props,
    ]
    if let r = lastRanges[0xD267] {
      // Zone utile de la vue directe (0xD267) : X dans les 2 octets de poids fort, Y dans les 2 de poids faible.
      out["area"] = [(r.lo >> 16) & 0xFFFF, r.lo & 0xFFFF, (r.hi >> 16) & 0xFFFF, r.hi & 0xFFFF]
    }
    if let n = camera?.name { out["name"] = n }
    if let p = lastFilePath { out["lastFile"] = p }
    return out
  }

  private func emitState() {
    let snap = liveSnapshot()
    DispatchQueue.main.async { [weak self] in
      self?.sink?(["state": snap])
    }
  }

  private func emitPhoto(_ name: String, _ bytes: Int, _ seconds: Double) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(["photo": ["name": name, "bytes": bytes, "seconds": seconds]])
    }
  }

  private func emitSet(_ code: Int, _ wanted: Int, _ ok: Bool, _ now: Int) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(["set": ["code": code, "wanted": wanted, "ok": ok, "now": now]])
    }
  }

  /// Relit tous les réglages (silencieux). Une relecture demandée pendant une autre est refaite juste après.
  private func liveRefresh() {
    guard camera != nil, protocol3 else { return }
    if liveRefreshing {
      liveRefreshAgain = true
      return
    }
    liveRefreshing = true
    readSettings(quiet: true, watch: []) { [weak self] in
      guard let self = self else { return }
      self.liveRefreshing = false
      if self.liveRefreshAgain {
        self.liveRefreshAgain = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.liveRefresh() }
      }
    }
    // Si l'appareil ne répond pas, ne pas rester bloqué.
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
      guard let self = self else { return }
      if self.liveRefreshing && self.afterRead == nil { self.liveRefreshing = false }
    }
  }

  /// Règle une propriété (SetExtDevicePropValue 0x9205), relit, et dit si l'appareil a pris la valeur.
  private func liveSet(_ code: Int, _ value: Int) {
    guard camera != nil, protocol3, liveCodes.contains(code), let size = lastSizes[code], size == 2 || size == 4 else {
      emitSet(code, value, false, lastValues[code] ?? -1)
      return
    }
    guard lastWritable[code] == true else {
      emitSet(code, value, false, lastValues[code] ?? -1)
      return
    }
    let payload = size == 2 ? le16(UInt16(truncatingIfNeeded: value)) : le32(UInt32(truncatingIfNeeded: value))
    sendPTP(opcode: 0x9205, params: [UInt32(code), 0], label: "RÉGLAGE \(hex(code)) → \(hex(value))", handler: nil, outData: payload, done: { [weak self] ok in
      guard let self = self else { return }
      self.pendingSet = (code, value, ok, Date())
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.liveRefresh() }
    })
  }

  /// Après une relecture : le changement demandé est-il pris ? Réponse dès que la valeur correspond,
  /// ou au bout de 2,5 s (sinon on relit encore).
  private func resolvePendingSet() {
    guard let p = pendingSet else { return }
    let now = lastValues[p.code] ?? -1
    if now == p.value {
      pendingSet = nil
      emitSet(p.code, p.value, p.ok, now)
    } else if Date().timeIntervalSince(p.since) > 2.5 || !p.ok {
      pendingSet = nil
      emitSet(p.code, p.value, false, now)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.liveRefresh() }
    }
  }

  /// Déclenche une photo ; l'événement 0xC201 déclenche ensuite la lecture automatique du fichier.
  private func liveShoot() {
    guard camera != nil, liveReady else { return }
    if liveBusy { return }
    liveBusy = true
    streamPaused = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) { [weak self] in self?.streamPaused = false }
    sonyShoot(then: { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.liveBusy = false }
    })
  }

  private func liveStop() {
    liveReady = false
    camera?.requestCloseSession()
  }


  // MARK: - Vue directe et collimateur (banc, d'après la référence PTP 3 de Sony)

  private var liveTestRunning = false
  private var liveFrameSaved: String? = nil

  private func liveFramePath() -> String? {
    guard let p = liveFrameSaved, FileManager.default.fileExists(atPath: p) else { return nil }
    return p
  }

  /// Essai de la vue directe : état 0xD221, activation éventuelle (0xD313), 40 images par GetObject 0xFFFFC002.
  private func liveviewTest() {
    guard camera != nil, protocol3 else {
      log("VUE DIRECTE : faites d'abord 1, 2 puis 6b (poignée de main PTP 3).")
      return
    }
    if liveTestRunning {
      log("VUE DIRECTE : essai déjà en cours.")
      return
    }
    liveTestRunning = true
    log("VUE DIRECTE : lecture de l'état de la vue directe (0xD221)…")
    readSettings(quiet: true, watch: [0xD221, 0xD284]) { [weak self] in self?.liveStep2(tried: false) }
  }

  private func liveStep2(tried: Bool) {
    let st = lastValues[0xD221]
    guard let state = st else {
      log("VUE DIRECTE : propriété 0xD221 absente de la liste de l'appareil. Essai arrêté.")
      liveTestRunning = false
      return
    }
    log("VUE DIRECTE : état 0xD221 = \(state) (0 = désactivée, 1 = activée, 2 = non prise en charge).")
    if state == 2 {
      liveTestRunning = false
      return
    }
    if state == 1 {
      liveStep3()
      return
    }
    if tried {
      log("VUE DIRECTE : toujours désactivée après la commande d'activation 0xD313. Appareil en mode prise de vue (pas lecture, pas menu) ? Essai arrêté.")
      liveTestRunning = false
      return
    }
    log("VUE DIRECTE : désactivée. Essai de la commande d'activation 0xD313 (valeur 2).")
    sendPTP(opcode: 0x9207, params: [0xD313], label: "SetControlDeviceB 0x9207 · activer la vue directe (0xD313 = 2)", handler: nil, outData: le16(2), done: { [weak self] ok in
      guard let self = self else { return }
      self.log("VUE DIRECTE : commande d'activation \(ok ? "acceptée" : "refusée (réponse différente de 0x2001)"). Relecture dans 1 s…")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.readSettings(quiet: true, watch: [0xD221]) { [weak self] in self?.liveStep2(tried: true) }
      }
    })
  }

  private func liveStep3() {
    sendPTP(opcode: 0x1008, params: [0xFFFFC002], label: "GetObjectInfo 0xFFFFC002 (vue directe)", handler: { [weak self] data in
      guard let self = self else { return }
      var r = PTPReader(self.stripContainer(data))
      if let _ = r.u32(), let _ = r.u16(), let _ = r.u16(), let size = r.u32() {
        self.log("  VUE DIRECTE : taille annoncée (maximum, pas la taille réelle) : \(size / 1000) ko")
      }
    }, done: { [weak self] ok in
      guard let self = self else { return }
      if !ok {
        self.log("VUE DIRECTE : GetObjectInfo refusé. On tente quand même la lecture des images.")
      }
      self.liveLoop(index: 1, total: 40, started: Date(), good: 0, bad: 0, consecutiveBad: 0, sizes: [], dims: "?", lastJPEG: nil, firstFocal: nil)
    })
  }

  private func u32le(_ b: [UInt8], _ o: Int) -> Int? {
    guard o >= 0, o + 4 <= b.count else { return nil }
    return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
  }

  private func u16le(_ b: [UInt8], _ o: Int) -> Int? {
    guard o >= 0, o + 2 <= b.count else { return nil }
    return Int(b[o]) | Int(b[o + 1]) << 8
  }

  /// Décrit les cadres de mise au point (structure « FocalFrameInfo » de la référence, version 1.00 et suivantes).
  private func describeFocal(_ f: [UInt8]) -> String {
    guard f.count > 60, let version = u16le(f, 0) else { return "cadres : données trop courtes (\(f.count) octets)" }
    var pos = 8 + 40
    guard let n = u16le(f, pos) else { return "cadres : illisibles" }
    pos += 2 + 6 + n * 24
    guard let xd = u32le(f, pos), let yd = u32le(f, pos + 4), let num = u16le(f, pos + 8) else {
      return "version \(version) : zone des cadres de mise au point introuvable (\(f.count) octets)"
    }
    pos += 8 + 2 + 6
    var out = "version \(version) · grille \(xd)×\(yd) · \(num) cadre(s) de mise au point"
    var k = 0
    while k < min(num, 4) {
      guard let type = u16le(f, pos), let state = u16le(f, pos + 2), let x = u32le(f, pos + 8), let y = u32le(f, pos + 12), let h = u32le(f, pos + 16), let w = u32le(f, pos + 20) else { break }
      out += " · [type \(type) état \(state) x \(x) y \(y) h \(h) l \(w)]"
      pos += 24
      k += 1
    }
    return out
  }

  private func liveLoop(index: Int, total: Int, started: Date, good: Int, bad: Int, consecutiveBad: Int, sizes: [Int], dims: String, lastJPEG: Data?, firstFocal: String?) {
    if index > total || consecutiveBad >= 10 {
      let secs = Date().timeIntervalSince(started)
      let avg = sizes.isEmpty ? 0 : sizes.reduce(0, +) / sizes.count
      let fps = secs > 0 ? Double(good) / secs : 0
      log("VUE DIRECTE : TERMINÉ · \(good) image(s) reçue(s), \(bad) vide(s) ou refusée(s), en \(String(format: "%.1f", secs)) s = \(String(format: "%.1f", fps)) images/s · taille \(sizes.min() ?? 0)–\(sizes.max() ?? 0) octets (moyenne \(avg)) · dimensions \(dims)")
      if let f = firstFocal { log("VUE DIRECTE : cadres : \(f)") }
      if let d = lastJPEG, let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("banc_appareil", isDirectory: true) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("apercu_live.jpg")
        if (try? d.write(to: out)) != nil {
          liveFrameSaved = out.path
          log("VUE DIRECTE : dernière image enregistrée (bouton « 17b. Voir la dernière image directe »).")
        }
      }
      if consecutiveBad >= 10 { log("VUE DIRECTE : arrêt après 10 échecs de suite.") }
      liveTestRunning = false
      return
    }
    var gotSize = 0
    var gotDims = dims
    var gotJPEG: Data? = lastJPEG
    var gotFocal: String? = firstFocal
    sendPTP(opcode: 0x1009, params: [0xFFFFC002], label: "GetObject 0xFFFFC002 (image \(index))", handler: { [weak self] data in
      guard let self = self else { return }
      let body = self.stripContainer(data)
      let b = [UInt8](body)
      guard let imgOff = self.u32le(b, 0), let imgSize = self.u32le(b, 4), let fOff = self.u32le(b, 8), let fSize = self.u32le(b, 12) else { return }
      if index == 1 { self.log("  VUE DIRECTE image 1 : \(b.count) octets reçus · décalage image \(imgOff), taille image \(imgSize), décalage cadres \(fOff), taille cadres \(fSize)") }
      guard imgSize > 0, imgOff + imgSize <= b.count else { return }
      gotSize = imgSize
      gotJPEG = body.subdata(in: imgOff..<(imgOff + imgSize))
      body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        if imgOff + 2 < p.count, let e = self.jpegExtent(p, imgOff) { gotDims = "\(e.w) × \(e.h) px" }
      }
      if gotFocal == nil, fSize > 0, fOff + fSize <= b.count {
        gotFocal = self.describeFocal(Array(b[fOff..<(fOff + fSize)]))
      }
    }, silent: true, done: { [weak self] ok in
      guard let self = self else { return }
      let success = ok && gotSize > 0
      var s = sizes
      if success { s.append(gotSize) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
        self?.liveLoop(index: index + 1, total: total, started: started, good: good + (success ? 1 : 0), bad: bad + (success ? 0 : 1), consecutiveBad: success ? 0 : consecutiveBad + 1, sizes: s, dims: gotDims, lastJPEG: gotJPEG, firstFocal: gotFocal)
      }
    })
  }

  /// Envoie une position de collimateur (0xD2DC) : X (0–639) dans les 2 octets de poids fort, Y (0–479) dans les 2 de poids faible.
  private func afPoint(_ code: UInt32, _ x: Int, _ y: Int, _ name: String, quiet: Bool = false) {
    guard camera != nil, protocol3 else {
      log("COLLIMATEUR : faites d'abord 1, 2 puis 6b.")
      return
    }
    let value = UInt32((x << 16) | y)
    if !quiet { log("COLLIMATEUR : \(name) (x \(x), y \(y)) par \(hex(Int(code))). Regardez le carré de mise au point sur l'appareil (zone « Point flexible »).") }
    sendPTP(opcode: 0x9207, params: [code], label: "SetControlDeviceB \(hex(Int(code))) · position \(x),\(y)", handler: nil, outData: le32(value), silent: quiet, done: { [weak self] ok in
      if !quiet || !ok { self?.log("COLLIMATEUR : \(ok ? "commande acceptée (0x2001)" : "commande refusée") : le carré a-t-il bougé sur l'appareil ?") }
    })
  }

  /// Toucher à distance (0xD2E4) : utilisable seulement si 0xD284 vaut 1.
  private func touchCenter() {
    guard camera != nil, protocol3 else {
      log("TOUCHER : faites d'abord 1, 2 puis 6b.")
      return
    }
    readSettings(quiet: true, watch: [0xD284]) { [weak self] in
      guard let self = self else { return }
      let st = self.lastValues[0xD284]
      self.log("TOUCHER : état « toucher à distance possible » 0xD284 = \(st.map { String($0) } ?? "absent") (1 = possible).")
      if st == 1 {
        self.afPoint(0xD2E4, 320, 240, "toucher au centre")
      }
    }
  }


  // MARK: - Flux de vue directe pour l'écran « Capturer »

  private var streaming = false
  private var streamPaused = false
  private var streamBad = 0
  private var streamIndex = 0

  private func liveStreamStart() {
    guard camera != nil, protocol3 else { return }
    if streaming { return }
    streaming = true
    streamPaused = false
    streamBad = 0
    streamIndex = 0
    streamNext()
  }

  private func liveStreamStop() {
    streaming = false
  }

  /// Cadres de mise au point : [x, y, largeur, hauteur, type, état], x et y en fractions de l'image (0 à 1).
  private func parseFocalFrames(_ f: [UInt8]) -> [[Double]] {
    guard f.count > 60 else { return [] }
    var pos = 8 + 40
    guard let n = u16le(f, pos) else { return [] }
    pos += 2 + 6 + n * 24
    guard let xd = u32le(f, pos), let yd = u32le(f, pos + 4), let num = u16le(f, pos + 8), xd > 0, yd > 0 else { return [] }
    pos += 8 + 2 + 6
    var out: [[Double]] = []
    var k = 0
    while k < min(num, 8) {
      guard let type = u16le(f, pos), let state = u16le(f, pos + 2), let x = u32le(f, pos + 8), let y = u32le(f, pos + 12), let h = u32le(f, pos + 16), let w = u32le(f, pos + 20) else { break }
      out.append([Double(x) / Double(xd), Double(y) / Double(yd), Double(w) / Double(xd), Double(h) / Double(yd), Double(type), Double(state)])
      pos += 24
      k += 1
    }
    return out
  }

  private func streamNext() {
    guard streaming else { return }
    guard camera != nil else {
      streaming = false
      return
    }
    if streamPaused {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.streamNext() }
      return
    }
    var payload: [String: Any]? = nil
    sendPTP(opcode: 0x1009, params: [0xFFFFC002], label: "vue directe", handler: { [weak self] data in
      guard let self = self else { return }
      let body = self.stripContainer(data)
      let b = [UInt8](body)
      guard let imgOff = self.u32le(b, 0), let imgSize = self.u32le(b, 4), let fOff = self.u32le(b, 8), let fSize = self.u32le(b, 12),
            imgSize > 0, imgOff + imgSize <= b.count else { return }
      var w = 0
      var h = 0
      body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        if imgOff + 2 < p.count, let e = self.jpegExtent(p, imgOff) {
          w = e.w
          h = e.h
        }
      }
      var focus: [[Double]] = []
      if fSize > 0, fOff + fSize <= b.count { focus = self.parseFocalFrames(Array(b[fOff..<(fOff + fSize)])) }
      payload = [
        "jpeg": FlutterStandardTypedData(bytes: body.subdata(in: imgOff..<(imgOff + imgSize))),
        "w": w,
        "h": h,
        "focus": focus,
      ]
    }, silent: true, done: { [weak self] ok in
      guard let self = self else { return }
      if ok, let p = payload {
        self.streamBad = 0
        self.streamIndex += 1
        DispatchQueue.main.async { [weak self] in self?.sink?(["frame": p]) }
      } else {
        self.streamBad += 1
      }
      if self.streamBad >= 25 {
        self.streaming = false
        self.log("VUE DIRECTE : flux arrêté (25 échecs de suite). L'appareil est-il en mode prise de vue ?")
        DispatchQueue.main.async { [weak self] in self?.sink?(["stream": ["state": "stopped"]]) }
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.03 : 0.25)) { [weak self] in self?.streamNext() }
    })
  }

  /// Mise au point seule (demi-course du déclencheur) sans déclencher la photo.
  private func liveFocus() {
    guard camera != nil, liveReady else { return }
    let steps: [(UInt32, UInt16, String)] = [
      (0xD2C1, 2, "mise au point : appui"),
      (0xD2C1, 1, "mise au point : relâchée"),
    ]
    streamPaused = true
    runControl(steps, 0, { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.streamPaused = false }
    })
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
