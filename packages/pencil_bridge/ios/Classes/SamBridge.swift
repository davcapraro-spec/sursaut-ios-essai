import CoreGraphics
import CoreML
import CoreVideo
import Flutter
import Foundation

/// Sélection au toucher par SAM 2.1 « small » (Meta, Apache 2.0), version Core ML d'Apple (Apache 2.0, apple/coreml-sam2.1-small).
///
/// Trois modèles compilés (`.mlmodelc`, mis dans l'application avec le plugin par le workflow) :
/// - encodeur d'image : `image` (photo 1024 x 1024) -> `image_embedding`, `feats_s0`, `feats_s1` (une fois par photo) ;
/// - encodeur de points : `points` [1, N, 2] (pixels dans 1024 x 1024), `labels` [1, N] (0 = en dehors, 1 = dans l'objet)
///   -> `sparse_embeddings`, `dense_embeddings` ;
/// - décodeur : tout cela -> `low_res_masks` [1, 3, 256, 256] (valeurs avant sigmoïde : > 0 = dans l'objet), `scores` [1, 3].
/// Les noms et formes viennent du code de référence d'Apple/Hugging Face (sam2-studio, Apache 2.0).
final class SamBridge {
  static let side = 1024
  static let maskSide = 256
  private static let lock = NSLock()
  private static var encoder: MLModel?
  private static var promptEncoder: MLModel?
  private static var decoder: MLModel?
  private static var embedding: MLFeatureValue?
  private static var feats0: MLFeatureValue?
  private static var feats1: MLFeatureValue?
  private static var encodedKey: Int = 0

  private static func fail(_ text: String) -> NSError {
    return NSError(domain: "Sam", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }

  private static func load(_ name: String) throws -> MLModel {
    for b in [Bundle(for: SamBridge.self), Bundle.main] {
      if let url = b.url(forResource: name, withExtension: "mlmodelc") {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU
        return try MLModel(contentsOf: url, configuration: cfg)
      }
    }
    throw fail("Le modèle \(name) est absent de l'application.")
  }

  private static func loadAll() throws {
    if encoder == nil { encoder = try load("SAM2_1SmallImageEncoderFLOAT16") }
    if promptEncoder == nil { promptEncoder = try load("SAM2_1SmallPromptEncoderFLOAT16") }
    if decoder == nil { decoder = try load("SAM2_1SmallMaskDecoderFLOAT16") }
  }

  /// La photo (RGBA 8 bits) étirée en 1024 x 1024 (comme le programme de référence), en BGRA.
  private static func pixelBuffer(_ rgba: Data, _ width: Int, _ height: Int) -> CVPixelBuffer? {
    guard width > 0, height > 0, rgba.count >= width * height * 4,
      let provider = CGDataProvider(data: rgba as CFData)
    else { return nil }
    let srcInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: srcInfo,
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        == kCVReturnSuccess,
      let pb = buffer
    else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let dstInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pb), width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: dstInfo)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return pb
  }

  /// Analyse la photo (une fois ; `key` identifie la photo pour ne pas la refaire).
  static func encode(rgba: Data, width: Int, height: Int, key: Int) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    do {
      if encodedKey == key && embedding != nil { return ["ok": true, "cached": true] }
      try loadAll()
      guard let pb = pixelBuffer(rgba, width, height) else {
        throw fail("La photo n'a pas pu être préparée pour SAM 2.1.")
      }
      let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
      let out = try encoder!.prediction(from: input)
      guard let e = out.featureValue(for: "image_embedding"),
        let f0 = out.featureValue(for: "feats_s0"),
        let f1 = out.featureValue(for: "feats_s1")
      else { throw fail("L'encodeur SAM 2.1 n'a pas rendu les trois sorties attendues.") }
      embedding = e
      feats0 = f0
      feats1 = f1
      encodedKey = key
      return ["ok": true, "cached": false]
    } catch {
      embedding = nil
      encodedKey = 0
      return ["error": "SAM 2.1 : \(error.localizedDescription)"]
    }
  }

  /// Masque pour des points `[x, y, étiquette]` (x et y : fractions de la photo ; étiquette 1 = dans l'objet, 0 = en dehors).
  /// Réponse : `size` (256), `logits` (256 x 256 flottants 32 bits, avant sigmoïde), `score` (confiance du meilleur masque).
  static func decode(points: [[Double]]) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    do {
      guard let e = embedding, let f0 = feats0, let f1 = feats1 else {
        throw fail("La photo n'est pas encore analysée.")
      }
      guard !points.isEmpty else { throw fail("Aucun point.") }
      try loadAll()
      let n = points.count
      let pts = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float32)
      let labels = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
      for (i, p) in points.enumerated() {
        guard p.count >= 3 else { throw fail("Point illisible.") }
        pts[[0, NSNumber(value: i), 0]] = NSNumber(value: Float(p[0] * Double(side)))
        pts[[0, NSNumber(value: i), 1]] = NSNumber(value: Float(p[1] * Double(side)))
        labels[[0, NSNumber(value: i)]] = NSNumber(value: Int32(p[2]))
      }
      let promptIn = try MLDictionaryFeatureProvider(dictionary: [
        "points": MLFeatureValue(multiArray: pts),
        "labels": MLFeatureValue(multiArray: labels),
      ])
      let prompt = try promptEncoder!.prediction(from: promptIn)
      guard let sparse = prompt.featureValue(for: "sparse_embeddings"),
        let dense = prompt.featureValue(for: "dense_embeddings")
      else { throw fail("L'encodeur de points SAM 2.1 n'a pas rendu les sorties attendues.") }
      let decIn = try MLDictionaryFeatureProvider(dictionary: [
        "image_embedding": e,
        "sparse_embedding": sparse,
        "dense_embedding": dense,
        "feats_s0": f0,
        "feats_s1": f1,
      ])
      let out = try decoder!.prediction(from: decIn)
      guard let masks = out.featureValue(for: "low_res_masks")?.multiArrayValue,
        let scores = out.featureValue(for: "scores")?.multiArrayValue
      else { throw fail("Le décodeur SAM 2.1 n'a pas rendu les sorties attendues.") }
      var best = 0
      var bestScore = -Float.greatestFiniteMagnitude
      for k in 0..<min(3, scores.count) {
        let v = scores[k].floatValue
        if v > bestScore {
          bestScore = v
          best = k
        }
      }
      let m = maskSide
      let st = masks.strides.map { $0.intValue }
      guard st.count == 4, masks.shape.count == 4, masks.shape[2].intValue == m, masks.shape[3].intValue == m
      else { throw fail("Forme du masque SAM 2.1 inattendue.") }
      var floats = [Float](repeating: 0, count: m * m)
      for y in 0..<m {
        for x in 0..<m {
          floats[y * m + x] = masks[best * st[1] + y * st[2] + x * st[3]].floatValue
        }
      }
      let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
      return ["size": m, "logits": FlutterStandardTypedData(float32: data), "score": Double(bestScore)]
    } catch {
      return ["error": "SAM 2.1 : \(error.localizedDescription)"]
    }
  }
}
