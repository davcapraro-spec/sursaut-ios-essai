import Flutter
import Foundation
import TensorFlowLite

/// Parties du corps d'une personne (cheveux, peau du corps, peau du visage, vêtements) par le modèle MediaPipe
/// « selfie multiclasse 256x256 » (Google, Apache 2.0), exécuté avec TensorFlow Lite (Google, Apache 2.0).
///
/// Dart envoie la photo (RGBA 8 bits) et un carré de découpe (`x0`, `y0`, `side`, en pixels, qui peut dépasser la photo :
/// ce qui dépasse est noir). Le carré est ramené à 256 x 256, le modèle donne 6 classes par pixel :
/// 0 fond, 1 cheveux, 2 peau du corps, 3 peau du visage, 4 vêtements, 5 autres.
/// Réponse : `size` (256) et `probs` : 6 plans de 256 x 256 octets (classe par classe), probabilité x 255.
final class BodyPartsBridge {
  static let size = 256
  static let classes = 6
  private static let lock = NSLock()
  private static var interpreter: Interpreter?

  /// Le fichier du modèle (mis dans l'application avec le plugin), ou nil.
  private static func modelPath() -> String? {
    for b in [Bundle(for: BodyPartsBridge.self), Bundle.main] {
      if let p = b.path(forResource: "selfie_multiclass_256x256", ofType: "tflite") { return p }
    }
    return nil
  }

  private static func loadInterpreter() throws -> Interpreter {
    if let existing = interpreter { return existing }
    guard let path = modelPath() else {
      throw NSError(
        domain: "BodyParts", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Le fichier du modèle (selfie_multiclass_256x256.tflite) est absent de l'application."])
    }
    var options = Interpreter.Options()
    options.threadCount = 2
    let made = try Interpreter(modelPath: path, options: options)
    try made.allocateTensors()
    interpreter = made
    return made
  }

  /// Le carré de la photo, ramené à 256 x 256, en réels (rouge, vert, bleu entre 0 et 1) : moyenne de plusieurs points par pixel.
  private static func prepare(_ rgba: Data, _ width: Int, _ height: Int, _ x0: Int, _ y0: Int, _ side: Int) -> Data {
    let n = size
    var out = [Float](repeating: 0, count: n * n * 3)
    let k = max(1, min(6, Int((Double(side) / Double(n) / 2.0).rounded(.up))))
    let step = Double(side) / Double(n * k)
    rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      func texel(_ x: Int, _ y: Int, _ c: Int) -> Float {
        if x < 0 || y < 0 || x >= width || y >= height { return 0 }
        return Float(base[(y * width + x) * 4 + c])
      }
      for oy in 0..<n {
        for ox in 0..<n {
          var acc: (Float, Float, Float) = (0, 0, 0)
          for sy in 0..<k {
            let fy = Double(y0) + (Double(oy * k + sy) + 0.5) * step - 0.5
            let iy = Int(fy.rounded(.down))
            let ty = Float(fy - Double(iy))
            for sx in 0..<k {
              let fx = Double(x0) + (Double(ox * k + sx) + 0.5) * step - 0.5
              let ix = Int(fx.rounded(.down))
              let tx = Float(fx - Double(ix))
              for c in 0..<3 {
                let a = texel(ix, iy, c) * (1 - tx) + texel(ix + 1, iy, c) * tx
                let b = texel(ix, iy + 1, c) * (1 - tx) + texel(ix + 1, iy + 1, c) * tx
                let v = a * (1 - ty) + b * ty
                if c == 0 { acc.0 += v } else if c == 1 { acc.1 += v } else { acc.2 += v }
              }
            }
          }
          let d = Float(k * k) * 255
          let o = (oy * n + ox) * 3
          out[o] = acc.0 / d
          out[o + 1] = acc.1 / d
          out[o + 2] = acc.2 / d
        }
      }
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func run(rgba: Data, width: Int, height: Int, x0: Int, y0: Int, side: Int) -> [String: Any] {
    guard width > 0, height > 0, side >= 16, rgba.count >= width * height * 4 else {
      return ["error": "Image ou zone illisible pour les parties du corps."]
    }
    lock.lock()
    defer { lock.unlock() }
    do {
      let itp = try loadInterpreter()
      try itp.copy(prepare(rgba, width, height, x0, y0, side), toInputAt: 0)
      try itp.invoke()
      let data = try itp.output(at: 0).data
      let n = size
      let c = classes
      guard data.count >= n * n * c * MemoryLayout<Float>.size else {
        return ["error": "Réponse inattendue du modèle (taille \(data.count))."]
      }
      var planes = [UInt8](repeating: 0, count: n * n * c)
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let f = raw.bindMemory(to: Float.self)
        for p in 0..<(n * n) {
          var m = f[p * c]
          for k in 1..<c { m = max(m, f[p * c + k]) }
          var sum: Float = 0
          for k in 0..<c { sum += expf(f[p * c + k] - m) }
          for k in 0..<c {
            let share = expf(f[p * c + k] - m) / sum * 255
            planes[k * n * n + p] = UInt8(max(0, min(255, share.rounded())))
          }
        }
      }
      return ["size": n, "probs": FlutterStandardTypedData(bytes: Data(planes))]
    } catch {
      return ["error": "Parties du corps impossibles : \(error.localizedDescription)"]
    }
  }
}
