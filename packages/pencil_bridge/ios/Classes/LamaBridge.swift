import CoreML
import CryptoKit
import Flutter
import Foundation

/// Reconstruction d'une zone effacée par LaMa (big-lama, Apache 2.0) converti en Core ML (6 bits, ≈ 40 Mo, dépôt Hugging Face
/// `Dadm-n/lama-dilated-coreml`). Remplace ONNX Runtime (0.34.0) : aucune bibliothèque externe, tout est dans Core ML.
///
/// Le modèle n'est PAS dans l'application : il est téléchargé à la première utilisation (deux gros fichiers vérifiés par leur
/// empreinte SHA-256 ; le petit fichier de description `Manifest.json` est écrit par l'application), puis compilé par Core ML et rangé
/// dans « Application Support/models ».
/// Entrées (d'après la fiche du modèle, à confirmer à l'essai) : `image` [1, 3, 512, 512] (0..1) et `mask` [1, 1, 512, 512] (1 = zone à remplir) ;
/// sortie `inpainted_image` [1, 3, 512, 512] (0..1). Le modèle vide lui-même la zone du masque.
final class LamaBridge {
  static let side = 512
  private static let repo = "https://huggingface.co/Dadm-n/lama-dilated-coreml/resolve/main/Resources/LaMa.mlpackage/"
  /// Fichiers à télécharger : chemin dans le paquet, empreinte SHA-256 attendue (« oid » LFS du dépôt, relevé le 27/11/2026), taille minimale.
  private static let parts: [(path: String, sha256: String, minBytes: Int)] = [
    ("Data/com.apple.CoreML/model.mlmodel", "f39493f520a05444c3112c491249d855626d0b296b404f0b1a3a49641f527bd3", 1_300_000),
    ("Data/com.apple.CoreML/weights/weight.bin", "2b2226b91788047b75794bd990c6eac7200853389d636692799764f40fb93bbd", 38_000_000),
  ]
  /// Contenu de `Manifest.json` du paquet (lu sur le dépôt le 27/11/2026) : écrit ici plutôt que téléchargé.
  private static let manifest = """
  {
    "fileFormatVersion": "1.0.0",
    "itemInfoEntries": {
      "78103851-967E-4083-B0A0-6C421CC29DD7": {
        "author": "com.apple.CoreML",
        "description": "CoreML Model Weights",
        "name": "weights",
        "path": "com.apple.CoreML/weights"
      },
      "8888288F-5BA8-4BAD-BCC7-E8A2378CBE5F": {
        "author": "com.apple.CoreML",
        "description": "CoreML Model Specification",
        "name": "model.mlmodel",
        "path": "com.apple.CoreML/model.mlmodel"
      }
    },
    "rootModelIdentifier": "8888288F-5BA8-4BAD-BCC7-E8A2378CBE5F"
  }
  """
  private static let lock = NSLock()
  private static var model: MLModel?
  private static var loadedUnits: MLComputeUnits = .all
  private static var loadMs: Double = 0

  private static func fail(_ text: String) -> [String: Any] { return ["error": text] }

  private static func modelsDir() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("models", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Modèle compilé (dossier .mlmodelc) : celui embarqué dans l'application (mis par le workflow), sinon celui téléchargé.
  private static func compiledURL() throws -> URL {
    for b in [Bundle(for: LamaBridge.self), Bundle.main] {
      if let url = b.url(forResource: "LaMa", withExtension: "mlmodelc") { return url }
    }
    return try modelsDir().appendingPathComponent("LaMaCoreML.mlmodelc", isDirectory: true)
  }

  /// Empreinte SHA-256 d'un fichier, lue par morceaux.
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

  /// Mémoire utilisée par l'application (Mo), pour mesurer le coût du modèle.
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

  /// Le modèle compilé est-il là ?
  static func status() -> [String: Any] {
    guard let url = try? compiledURL() else { return ["present": false, "bytes": 0] }
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return ["present": exists && isDir.boolValue, "bytes": exists ? 40_000_000 : 0]
  }

  /// Télécharge un fichier (bloquant) vers [dest] et le vérifie. Rend un message d'erreur, ou nil.
  private static func fetch(_ path: String, sha256 expected: String, minBytes: Int, to dest: URL) -> String? {
    guard let url = URL(string: repo + path) else { return "Adresse de téléchargement invalide." }
    let sem = DispatchSemaphore(value: 0)
    var tmp: URL?
    var problem: String?
    let task = URLSession.shared.downloadTask(with: url) { location, response, error in
      if let error = error {
        problem = "Téléchargement impossible : \(error.localizedDescription)"
      } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        problem = "Téléchargement refusé (code \(http.statusCode))."
      } else if let location = location {
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("lama_part_\(UUID().uuidString)")
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
    if let problem = problem { return problem }
    guard let file = tmp else { return "Téléchargement vide." }
    defer { try? FileManager.default.removeItem(at: file) }
    let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
    if size < minBytes { return "Fichier téléchargé trop petit (\(size) octets) : refusé." }
    guard let got = sha256(of: file) else { return "Empreinte du fichier téléchargé illisible." }
    if got != expected { return "Le fichier téléchargé n'a pas la bonne empreinte (reçu \(got.prefix(12))…). Il a été refusé." }
    do {
      try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.copyItem(at: file, to: dest)
    } catch {
      return "Rangement du modèle impossible : \(error.localizedDescription)"
    }
    return nil
  }

  /// Télécharge le modèle (bloquant : à appeler hors du fil principal), vérifie les empreintes, compile et range.
  static func download() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    guard let compiled = try? compiledURL() else { return fail("Dossier des modèles introuvable.") }
    if FileManager.default.fileExists(atPath: compiled.path) { return ["ok": true, "already": true] }
    let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("LaMa.mlpackage", isDirectory: true)
    try? FileManager.default.removeItem(at: pkg)
    defer { try? FileManager.default.removeItem(at: pkg) }
    do {
      try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
      try manifest.data(using: .utf8)!.write(to: pkg.appendingPathComponent("Manifest.json"))
    } catch {
      return fail("Préparation du modèle impossible : \(error.localizedDescription)")
    }
    for part in parts {
      if let problem = fetch(part.path, sha256: part.sha256, minBytes: part.minBytes, to: pkg.appendingPathComponent(part.path)) {
        return fail(problem)
      }
    }
    do {
      let built = try MLModel.compileModel(at: pkg)
      try? FileManager.default.removeItem(at: compiled)
      try FileManager.default.moveItem(at: built, to: compiled)
    } catch {
      return fail("Compilation du modèle impossible : \(error.localizedDescription)")
    }
    model = nil
    return ["ok": true, "already": false]
  }

  private static func loadModel(units: MLComputeUnits) throws -> MLModel {
    if let m = model, loadedUnits == units { return m }
    let url = try compiledURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NSError(domain: "Lama", code: 1, userInfo: [NSLocalizedDescriptionKey: "Le modèle LaMa n'est pas encore téléchargé."])
    }
    let started = Date()
    let config = MLModelConfiguration()
    config.computeUnits = units
    let m = try MLModel(contentsOf: url, configuration: config)
    model = m
    loadedUnits = units
    loadMs = Date().timeIntervalSince(started) * 1000
    return m
  }

  private static func pixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &pb)
    return pb
  }

  /// Entrée `image` : tableau [1, 3, 512, 512] (0..1), ou image 512 x 512 si le modèle la déclare ainsi.
  private static func imageInput(_ m: MLModel, rgba: Data) throws -> MLFeatureValue {
    let n = side * side
    guard let desc = m.modelDescription.inputDescriptionsByName["image"] else {
      throw NSError(domain: "Lama", code: 2, userInfo: [NSLocalizedDescriptionKey: "Le modèle n'a pas d'entrée « image »."])
    }
    if desc.type == .image {
      guard let pb = pixelBuffer(width: side, height: side, format: kCVPixelFormatType_32BGRA) else {
        throw NSError(domain: "Lama", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image d'entrée impossible à créer."])
      }
      CVPixelBufferLockBaseAddress(pb, [])
      defer { CVPixelBufferUnlockBaseAddress(pb, []) }
      let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pb)
      rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        for y in 0..<side {
          for x in 0..<side {
            let s = (y * side + x) * 4
            let d = y * stride + x * 4
            base[d] = p[s + 2]
            base[d + 1] = p[s + 1]
            base[d + 2] = p[s]
            base[d + 3] = 255
          }
        }
      }
      return MLFeatureValue(pixelBuffer: pb)
    }
    let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
    let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: n * 3)
    rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let p = raw.bindMemory(to: UInt8.self)
      for i in 0..<n {
        ptr[i] = Float(p[i * 4]) / 255
        ptr[n + i] = Float(p[i * 4 + 1]) / 255
        ptr[2 * n + i] = Float(p[i * 4 + 2]) / 255
      }
    }
    return MLFeatureValue(multiArray: arr)
  }

  /// Entrée `mask` : tableau [1, 1, 512, 512] (1 = à remplir), ou image en niveaux de gris si le modèle la déclare ainsi.
  private static func maskInput(_ m: MLModel, mask: Data) throws -> MLFeatureValue {
    let n = side * side
    guard let desc = m.modelDescription.inputDescriptionsByName["mask"] else {
      throw NSError(domain: "Lama", code: 2, userInfo: [NSLocalizedDescriptionKey: "Le modèle n'a pas d'entrée « mask »."])
    }
    if desc.type == .image {
      guard let pb = pixelBuffer(width: side, height: side, format: kCVPixelFormatType_OneComponent8) else {
        throw NSError(domain: "Lama", code: 3, userInfo: [NSLocalizedDescriptionKey: "Masque d'entrée impossible à créer."])
      }
      CVPixelBufferLockBaseAddress(pb, [])
      defer { CVPixelBufferUnlockBaseAddress(pb, []) }
      let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pb)
      mask.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let p = raw.bindMemory(to: UInt8.self)
        for y in 0..<side { for x in 0..<side { base[y * stride + x] = p[y * side + x] > 127 ? 255 : 0 } }
      }
      return MLFeatureValue(pixelBuffer: pb)
    }
    let arr = try MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
    let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
    mask.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let p = raw.bindMemory(to: UInt8.self)
      for i in 0..<n { ptr[i] = p[i] > 127 ? 1 : 0 }
    }
    return MLFeatureValue(multiArray: arr)
  }

  /// Lit la sortie (tableau [1, 3, 512, 512] ou image) en RVBA 8 bits ; nil si elle est invalide (valeurs hors limites, ou zone remplie
  /// très différente de son pourtour : cas d'une demi-précision qui déborde sur le Neural Engine).
  private static func readOutput(_ out: MLFeatureProvider, rgba: Data, mask: Data) -> Data? {
    let n = side * side
    var result = Data(count: n * 4)
    var bad = 0
    let names = out.featureNames
    let name = names.contains("inpainted_image") ? "inpainted_image" : (names.first ?? "")
    guard let value = out.featureValue(for: name) else { return nil }
    if let arr = value.multiArrayValue {
      guard arr.count >= n * 3 else { return nil }
      var floats = [Float](repeating: 0, count: n * 3)
      if arr.dataType == .float32 {
        let src = arr.dataPointer.bindMemory(to: Float.self, capacity: n * 3)
        for i in 0..<(n * 3) { floats[i] = src[i] }
      } else {
        for i in 0..<(n * 3) { floats[i] = arr[i].floatValue }
      }
      result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        let d = dst.bindMemory(to: UInt8.self)
        for i in 0..<n {
          for c in 0..<3 {
            let v = floats[c * n + i]
            if v.isNaN || v.isInfinite { bad += 1; d[i * 4 + c] = 0 } else { d[i * 4 + c] = UInt8(max(0, min(255, (v * 255).rounded()))) }
          }
          d[i * 4 + 3] = 255
        }
      }
    } else if let pb = value.imageBufferValue {
      CVPixelBufferLockBaseAddress(pb, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
      guard let addr = CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb) >= side, CVPixelBufferGetHeight(pb) >= side else { return nil }
      let base = addr.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(pb)
      result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        let d = dst.bindMemory(to: UInt8.self)
        for y in 0..<side {
          for x in 0..<side {
            let s = y * stride + x * 4
            let o = (y * side + x) * 4
            d[o] = base[s + 2]
            d[o + 1] = base[s + 1]
            d[o + 2] = base[s]
            d[o + 3] = 255
          }
        }
      }
    } else {
      return nil
    }
    // Contrôle limité à la zone remplie (la sortie entière peut être correcte alors que le trou est noir ou plein de points).
    var inside = 0
    var sumIn = 0.0
    var ring = 0
    var sumRing = 0.0
    var maskCount = 0
    rgba.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
      mask.withUnsafeBytes { (m: UnsafeRawBufferPointer) in
        result.withUnsafeBytes { (res: UnsafeRawBufferPointer) in
          let s = src.bindMemory(to: UInt8.self), mk = m.bindMemory(to: UInt8.self), r = res.bindMemory(to: UInt8.self)
          for i in 0..<n {
            if mk[i] > 127 {
              maskCount += 1
              inside += 1
              sumIn += 0.299 * Double(r[i * 4]) + 0.587 * Double(r[i * 4 + 1]) + 0.114 * Double(r[i * 4 + 2])
            } else if i % 7 == 0 {
              ring += 1
              sumRing += 0.299 * Double(s[i * 4]) + 0.587 * Double(s[i * 4 + 1]) + 0.114 * Double(s[i * 4 + 2])
            }
          }
        }
      }
    }
    if bad > max(30, maskCount / 50) { return nil }
    if inside > 50 && ring > 50 {
      let meanIn = sumIn / Double(inside), meanRing = sumRing / Double(ring)
      if abs(meanIn - meanRing) > 90 { return nil }
    }
    return result
  }

  private static func run(rgba: Data, mask: Data, units: MLComputeUnits) throws -> (Data?, Double) {
    let m = try loadModel(units: units)
    let inputs = try MLDictionaryFeatureProvider(dictionary: [
      "image": try imageInput(m, rgba: rgba),
      "mask": try maskInput(m, mask: mask),
    ])
    let started = Date()
    let out = try m.prediction(from: inputs)
    return (readOutput(out, rgba: rgba, mask: mask), Date().timeIntervalSince(started) * 1000)
  }

  /// Remplit la zone du masque. `rgba` : 512 x 512 x 4 octets ; `mask` : 512 x 512 octets (255 = à remplir).
  /// Réponse : `rgba` (512 x 512 x 4), `loadMs` (chargement, 0 si déjà chargé), `runMs`, `memBeforeMB`, `memAfterMB`, `units`, ou `error`.
  /// Essai d'abord avec tous les processeurs (Neural Engine compris) ; si le résultat est invalide (valeurs hors limites en demi-précision),
  /// nouvel essai sur processeur et carte graphique seulement.
  static func fill(rgba: Data, mask: Data) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let n = side * side
    guard rgba.count >= n * 4, mask.count >= n else { return fail("Image ou masque de la mauvaise taille (512 x 512 attendu).") }
    let memBefore = footprintMB()
    let hadModel = model != nil
    var usedUnits = "tous les processeurs"
    do {
      var (data, ms) = try run(rgba: rgba, mask: mask, units: .all)
      if data == nil {
        usedUnits = "processeur et carte graphique"
        (data, ms) = try run(rgba: rgba, mask: mask, units: .cpuAndGPU)
      }
      guard let result = data else { return fail("LaMa a rendu une image invalide.") }
      return [
        "rgba": FlutterStandardTypedData(bytes: result),
        "loadMs": hadModel ? 0.0 : loadMs,
        "runMs": ms,
        "memBeforeMB": memBefore,
        "memAfterMB": footprintMB(),
        "units": usedUnits,
      ]
    } catch {
      return fail("LaMa : \(error.localizedDescription)")
    }
  }
}
