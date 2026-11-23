import Flutter
import UIKit
import Vision
import CoreVideo

/// Détourage par Vision (Apple) : sujet principal ou personnes, sans fichier de modèle.
///
/// Appelé par Dart (canal « sursaut/vision/methods », méthode « instanceMask ») avec une photo RGBA 8 bits.
/// Renvoie une image de masque (un octet par pixel, 255 = dans la zone) ou un message d'erreur lisible.
/// Demande iPadOS 17 ou plus ; sur une version plus ancienne, renvoie un message au lieu de planter.
final class VisionBridge {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "sursaut/vision/methods",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "instanceMask" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let typed = args["rgba"] as? FlutterStandardTypedData,
        let width = args["width"] as? Int,
        let height = args["height"] as? Int,
        let kind = args["kind"] as? String
      else {
        result(["error": "Arguments manquants pour le détourage."])
        return
      }
      let tapX = args["x"] as? Double
      let tapY = args["y"] as? Double
      let pixels = typed.data
      DispatchQueue.global(qos: .userInitiated).async {
        let out = VisionBridge.instanceMask(
          rgba: pixels, width: width, height: height,
          person: kind == "person", tapX: tapX, tapY: tapY)
        DispatchQueue.main.async { result(out) }
      }
    }
  }

  /// Image CGImage d'une photo RGBA 8 bits (le canal alpha est ignoré).
  private static func makeImage(_ data: Data, _ width: Int, _ height: Int) -> CGImage? {
    guard width > 0, height > 0, data.count >= width * height * 4,
      let provider = CGDataProvider(data: data as CFData)
    else { return nil }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  /// Masque du sujet principal (`person` faux) ou des personnes (`person` vrai).
  /// Avec un toucher (`tapX`, `tapY` : fractions de la photo, origine en haut à gauche), seul l'élément touché ;
  /// sans toucher, tous les éléments ensemble.
  static func instanceMask(
    rgba: Data, width: Int, height: Int, person: Bool, tapX: Double?, tapY: Double?
  ) -> [String: Any] {
    guard #available(iOS 17.0, *) else {
      return ["error": "Le détourage automatique demande iPadOS 17 ou plus."]
    }
    guard let image = makeImage(rgba, width, height) else {
      return ["error": "Image illisible pour le détourage."]
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let request: VNImageBasedRequest
    if person {
      request = VNGeneratePersonInstanceMaskRequest()
    } else {
      request = VNGenerateForegroundInstanceMaskRequest()
    }
    do {
      try handler.perform([request])
    } catch {
      return ["error": "Vision a refusé l'image : \(error.localizedDescription)"]
    }
    guard let observation = (request.results as? [VNInstanceMaskObservation])?.first,
      !observation.allInstances.isEmpty
    else {
      return ["error": person ? "Aucune personne repérée." : "Aucun sujet repéré par iPadOS."]
    }

    var chosen = observation.allInstances
    if let fx = tapX, let fy = tapY {
      let label = labelAt(observation.instanceMask, fx, fy)
      if label == 0 || !observation.allInstances.contains(label) {
        return ["error": "Aucun élément repéré à cet endroit."]
      }
      chosen = IndexSet(integer: label)
    }

    do {
      let buffer = try observation.generateScaledMaskForImage(forInstances: chosen, from: handler)
      guard let plane = planeFrom(buffer) else {
        return ["error": "Format de masque inattendu."]
      }
      return [
        "width": CVPixelBufferGetWidth(buffer),
        "height": CVPixelBufferGetHeight(buffer),
        "count": observation.allInstances.count,
        "mask": FlutterStandardTypedData(bytes: plane),
      ]
    } catch {
      return ["error": "Le masque n'a pas pu être fabriqué : \(error.localizedDescription)"]
    }
  }

  /// Numéro d'élément (0 = fond) à la position donnée (fractions) dans le masque d'étiquettes de Vision.
  private static func labelAt(_ buffer: CVPixelBuffer, _ fx: Double, _ fy: Double) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
    let x = min(max(Int(fx * Double(w)), 0), w - 1)
    let y = min(max(Int(fy * Double(h)), 0), h - 1)
    let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
    return Int(row.assumingMemoryBound(to: UInt8.self)[x])
  }

  /// Masque doux de Vision (réels de 0 à 1, ou octets) en un octet par pixel.
  private static func planeFrom(_ buffer: CVPixelBuffer) -> Data? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let format = CVPixelBufferGetPixelFormatType(buffer)
    var out = Data(count: w * h)
    if format == kCVPixelFormatType_OneComponent32Float {
      out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        for y in 0..<h {
          let src = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
          for x in 0..<w {
            let v = min(max(src[x], 0), 1)
            dst[y * w + x] = UInt8((v * 255).rounded())
          }
        }
      }
      return out
    }
    if format == kCVPixelFormatType_OneComponent8 {
      out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        for y in 0..<h {
          let src = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
          for x in 0..<w {
            dst[y * w + x] = src[x] > 0 ? 255 : 0
          }
        }
      }
      return out
    }
    return nil
  }
}
