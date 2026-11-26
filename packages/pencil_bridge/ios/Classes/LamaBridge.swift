import CryptoKit
import Flutter
import Foundation

#if canImport(onnxruntime_objc)
import onnxruntime_objc

/// Reconstruction d'une zone effacée par LaMa (big-lama exporté en ONNX par Carve, Apache 2.0), exécuté avec ONNX Runtime (Microsoft, MIT).
///
/// Essai (0.29.0) : le modèle (≈ 208 Mo) n'est PAS dans l'application ; il est téléchargé à la première utilisation dans le dossier
/// « Application Support » de l'application, puis vérifié par son empreinte SHA-256.
/// Entrées du modèle : `image` [1, 3, 512, 512] (0..1) et `mask` [1, 1, 512, 512] (1 = zone à remplir) ; sortie [1, 3, 512, 512] (0..255).
final class LamaBridge {
  static let side = 512
  static let fileName = "lama_fp32.onnx"
  static let downloadURL = "https://huggingface.co/Carve/LaMa-ONNX/resolve/main/lama_fp32.onnx"
  static let expectedSha256 = "1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6"
  private static let lock = NSLock()
  private static var env: ORTEnv?
  private static var session: ORTSession?
  private static var loadMs: Double = 0

  private static func fail(_ text: String) -> [String: Any] { return ["error": text] }

  static func modelURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(fileName)
  }

  /// Empreinte SHA-256 d'un fichier, lue par morceaux (le fichier fait ≈ 208 Mo).
  private static func sha256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = autoreleasepool { handle.readData(ofLength: 4 * 1024 * 1024) }
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Mémoire utilisée par l'application (octets), pour mesurer le coût du modèle.
  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : -1
  }

  /// Le modèle est-il là (et complet) ? Ne calcule pas l'empreinte (lent) : la taille suffit ici, l'empreinte est contrôlée au téléchargement.
  static func status() -> [String: Any] {
    guard let url = try? modelURL(),
      let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attrs[.size] as? NSNumber
    else { return ["present": false, "bytes": 0] }
    return ["present": size.intValue > 150_000_000, "bytes": size.intValue]
  }

  /// Télécharge le modèle (bloquant : à appeler hors du fil principal), vérifie l'empreinte, le range.
  static func download() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    guard let target = try? modelURL() else { return fail("Dossier des modèles introuvable.") }
    if FileManager.default.fileExists(atPath: target.path), sha256(of: target) == expectedSha256 {
      return ["ok": true, "already": true]
    }
    guard let url = URL(string: downloadURL) else { return fail("Adresse de téléchargement invalide.") }
    let sem = DispatchSemaphore(value: 0)
    var tmp: URL?
    var problem: String?
    let task = URLSession.shared.downloadTask(with: url) { location, response, error in
      if let error = error {
        problem = "Téléchargement impossible : \(error.localizedDescription)"
      } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        problem = "Téléchargement refusé (code \(http.statusCode))."
      } else if let location = location {
        // Le fichier temporaire disparaît à la fin de ce bloc : on le déplace tout de suite.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("lama_download.onnx")
        try? FileManager.default.removeItem(at: keep)
        do {
          try FileManager.default.moveItem(at: location, to: keep)
          tmp = keep
        } catch {
          problem = "Fichier téléchargé introuvable : \(error.localizedDescription)"
        }
      } else {
        problem = "Téléchargement vide."
      }
      sem.signal()
    }
    task.resume()
    sem.wait()
    if let problem = problem { return fail(problem) }
    guard let file = tmp else { return fail("Téléchargement vide.") }
    guard let got = sha256(of: file) else {
      try? FileManager.default.removeItem(at: file)
      return fail("Empreinte du fichier téléchargé illisible.")
    }
    if got != expectedSha256 {
      try? FileManager.default.removeItem(at: file)
      return fail("Le fichier téléchargé n'a pas la bonne empreinte (reçu \(got.prefix(12))…). Il a été refusé.")
    }
    try? FileManager.default.removeItem(at: target)
    do {
      try FileManager.default.moveItem(at: file, to: target)
    } catch {
      return fail("Rangement du modèle impossible : \(error.localizedDescription)")
    }
    return ["ok": true, "already": false]
  }

  private static func loadSession() throws -> ORTSession {
    if let s = session { return s }
    let url = try modelURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NSError(domain: "Lama", code: 1, userInfo: [NSLocalizedDescriptionKey: "Le modèle LaMa n'est pas encore téléchargé."])
    }
    let started = Date()
    let e = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(4)
    let s = try ORTSession(env: e, modelPath: url.path, sessionOptions: options)
    env = e
    session = s
    loadMs = Date().timeIntervalSince(started) * 1000
    return s
  }

  /// Remplit la zone du masque. `rgba` : 512 x 512 x 4 octets ; `mask` : 512 x 512 octets (255 = à remplir).
  /// Réponse : `rgba` (512 x 512 x 4), `loadMs` (chargement, 0 si déjà chargé), `runMs`, `memBeforeMB`, `memAfterMB`, ou `error`.
  static func fill(rgba: Data, mask: Data) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let n = side * side
    guard rgba.count >= n * 4, mask.count >= n else { return fail("Image ou masque de la mauvaise taille (512 x 512 attendu).") }
    do {
      let memBefore = footprintMB()
      let hadSession = session != nil
      let s = try loadSession()
      let imageData = NSMutableData(length: n * 3 * MemoryLayout<Float>.size)!
      let maskData = NSMutableData(length: n * MemoryLayout<Float>.size)!
      let img = imageData.mutableBytes.bindMemory(to: Float.self, capacity: n * 3)
      let msk = maskData.mutableBytes.bindMemory(to: Float.self, capacity: n)
      rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<n {
          img[i] = Float(p[i * 4]) / 255
          img[n + i] = Float(p[i * 4 + 1]) / 255
          img[2 * n + i] = Float(p[i * 4 + 2]) / 255
        }
      }
      mask.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<n { msk[i] = p[i] > 127 ? 1 : 0 }
      }
      let shapeImage: [NSNumber] = [1, 3, NSNumber(value: side), NSNumber(value: side)]
      let shapeMask: [NSNumber] = [1, 1, NSNumber(value: side), NSNumber(value: side)]
      let inImage = try ORTValue(tensorData: imageData, elementType: .float, shape: shapeImage)
      let inMask = try ORTValue(tensorData: maskData, elementType: .float, shape: shapeMask)
      let started = Date()
      let outputs = try s.run(
        withInputs: ["image": inImage, "mask": inMask], outputNames: ["output"], runOptions: nil)
      let runMs = Date().timeIntervalSince(started) * 1000
      guard let out = outputs["output"] else { return fail("LaMa n'a rien rendu.") }
      let outData = try out.tensorData() as Data
      guard outData.count >= n * 3 * MemoryLayout<Float>.size else { return fail("Sortie de LaMa trop courte.") }
      var result = Data(count: n * 4)
      outData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let f = raw.bindMemory(to: Float.self)
        result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
          let d = dst.bindMemory(to: UInt8.self)
          for i in 0..<n {
            d[i * 4] = UInt8(max(0, min(255, f[i].rounded())))
            d[i * 4 + 1] = UInt8(max(0, min(255, f[n + i].rounded())))
            d[i * 4 + 2] = UInt8(max(0, min(255, f[2 * n + i].rounded())))
            d[i * 4 + 3] = 255
          }
        }
      }
      return [
        "rgba": FlutterStandardTypedData(bytes: result),
        "loadMs": hadSession ? 0.0 : loadMs,
        "runMs": runMs,
        "memBeforeMB": memBefore,
        "memAfterMB": footprintMB(),
      ]
    } catch {
      return fail("LaMa : \(error.localizedDescription)")
    }
  }
}

#else

/// ONNX Runtime n'est pas inclus dans cette version (son serveur de téléchargement est en panne depuis le 26/11/2026, voir
/// `claude/sursaut-ios-supprimer-ia-faisabilite-lama-2026-11-26.md`) : mêmes méthodes, qui répondent par un message clair.
final class LamaBridge {
  private static let message = "LaMa n'est pas inclus dans cette version (ONNX Runtime indisponible pour le moment)."
  static func status() -> [String: Any] { return ["present": false, "bytes": 0] }
  static func download() -> [String: Any] { return ["error": message] }
  static func fill(rgba: Data, mask: Data) -> [String: Any] { return ["error": message] }
}

#endif
