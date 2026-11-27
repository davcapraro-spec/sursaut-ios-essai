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
      guard call.method == "instanceMask" || call.method == "listPersons" || call.method == "faceParts" || call.method == "bodyParts" || call.method == "samEncode" || call.method == "samDecode" || call.method == "lamaStatus" || call.method == "lamaDownload" || call.method == "lamaFill" || call.method == "iterSeg" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if call.method == "iterSeg" {
        guard let a = call.arguments as? [String: Any],
          let typed = a["rgba"] as? FlutterStandardTypedData,
          let w = a["width"] as? Int, let h = a["height"] as? Int,
          let pts = a["points"] as? [[Double]]
        else {
          result(["error": "Arguments manquants pour la segmentation de Vision."])
          return
        }
        IterativeSegBridge.segment(rgba: typed.data, width: w, height: h, points: pts) { out in
          DispatchQueue.main.async { result(out) }
        }
        return
      }
      if call.method == "lamaStatus" {
        result(LamaBridge.status())
        return
      }
      if call.method == "lamaDownload" {
        DispatchQueue.global(qos: .userInitiated).async {
          let out = LamaBridge.download()
          DispatchQueue.main.async { result(out) }
        }
        return
      }
      if call.method == "lamaFill" {
        guard let a = call.arguments as? [String: Any],
          let img = a["rgba"] as? FlutterStandardTypedData,
          let msk = a["mask"] as? FlutterStandardTypedData
        else {
          result(["error": "Image ou masque manquant pour LaMa."])
          return
        }
        let imgData = img.data
        let mskData = msk.data
        DispatchQueue.global(qos: .userInitiated).async {
          let out = LamaBridge.fill(rgba: imgData, mask: mskData)
          DispatchQueue.main.async { result(out) }
        }
        return
      }
      if call.method == "samDecode" {
        guard let a = call.arguments as? [String: Any], let raw = a["points"] as? [[Double]] else {
          result(["error": "Points manquants pour SAM 2.1."])
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let out = SamBridge.decode(points: raw)
          DispatchQueue.main.async { result(out) }
        }
        return
      }
      if call.method == "samEncode" {
        guard let a = call.arguments as? [String: Any],
          let typed = a["rgba"] as? FlutterStandardTypedData,
          let w = a["width"] as? Int, let h = a["height"] as? Int, let key = a["key"] as? Int
        else {
          result(["error": "Arguments manquants pour SAM 2.1."])
          return
        }
        let crop = a["crop"] as? [Double]
        let pixels = typed.data
        DispatchQueue.global(qos: .userInitiated).async {
          let out = SamBridge.encode(rgba: pixels, width: w, height: h, key: key, crop: crop)
          DispatchQueue.main.async { result(out) }
        }
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
      let listing = call.method == "listPersons"
      let faces = call.method == "faceParts"
      let body = call.method == "bodyParts"
      let cropX = args["cropX"] as? Int ?? 0
      let cropY = args["cropY"] as? Int ?? 0
      let cropSide = args["cropSide"] as? Int ?? 0
      DispatchQueue.global(qos: .userInitiated).async {
        let out: [String: Any]
        if body {
          out = BodyPartsBridge.run(rgba: pixels, width: width, height: height, x0: cropX, y0: cropY, side: cropSide)
        } else if faces {
          out = VisionBridge.faceParts(rgba: pixels, width: width, height: height)
        } else if listing {
          out = VisionBridge.listPersons(rgba: pixels, width: width, height: height)
        } else {
          out = VisionBridge.instanceMask(
            rgba: pixels, width: width, height: height,
            person: kind == "person", tapX: tapX, tapY: tapY)
        }
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

  /// Les visages repérés avec leurs repères (yeux, sourcils, lèvres, contour) : suites x, y, x, y… en fractions de la photo.
  static func faceParts(rgba: Data, width: Int, height: Int) -> [String: Any] {
    guard let image = makeImage(rgba, width, height) else {
      return ["error": "Image illisible pour le repérage des visages."]
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let request = VNDetectFaceLandmarksRequest()
    do {
      try handler.perform([request])
    } catch {
      return ["error": "Vision a refusé l'image : \(error.localizedDescription)"]
    }
    guard let found = request.results, !found.isEmpty else {
      return ["error": "Aucun visage repéré par iPadOS."]
    }
    var faces: [[String: Any]] = []
    for face in found {
      guard let marks = face.landmarks else { continue }
      let box = face.boundingBox
      func flat(_ region: VNFaceLandmarkRegion2D?) -> [Double] {
        guard let region = region else { return [] }
        var values: [Double] = []
        for p in region.normalizedPoints {
          values.append(Double(box.minX + p.x * box.width))
          values.append(Double(1.0 - (box.minY + p.y * box.height)))
        }
        return values
      }
      faces.append([
        "x0": Double(box.minX),
        "y0": Double(1.0 - box.maxY),
        "x1": Double(box.maxX),
        "y1": Double(1.0 - box.minY),
        "leftEye": flat(marks.leftEye),
        "rightEye": flat(marks.rightEye),
        "leftBrow": flat(marks.leftEyebrow),
        "rightBrow": flat(marks.rightEyebrow),
        "outerLips": flat(marks.outerLips),
        "innerLips": flat(marks.innerLips),
        "contour": flat(marks.faceContour),
      ])
    }
    if faces.isEmpty {
      return ["error": "Aucun visage exploitable."]
    }
    return ["faces": faces]
  }

  /// Les personnes repérées : pour chacune son cadre et un point à l'intérieur de sa silhouette (fractions de la photo).
  static func listPersons(rgba: Data, width: Int, height: Int) -> [String: Any] {
    guard #available(iOS 17.0, *) else {
      return ["error": "Le détourage automatique demande iPadOS 17 ou plus."]
    }
    guard let image = makeImage(rgba, width, height) else {
      return ["error": "Image illisible pour le détourage."]
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let request = VNGeneratePersonInstanceMaskRequest()
    do {
      try handler.perform([request])
    } catch {
      return ["error": "Vision a refusé l'image : \(error.localizedDescription)"]
    }
    guard let observation = (request.results as? [VNInstanceMaskObservation])?.first,
      !observation.allInstances.isEmpty
    else {
      return ["error": "Aucune personne repérée."]
    }
    let buffer = observation.instanceMask
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
      return ["error": "Masque des personnes illisible."]
    }
    var minX = [Int](repeating: Int.max, count: 256)
    var minY = [Int](repeating: Int.max, count: 256)
    var maxX = [Int](repeating: -1, count: 256)
    var maxY = [Int](repeating: -1, count: 256)
    var sumX = [Int](repeating: 0, count: 256)
    var sumY = [Int](repeating: 0, count: 256)
    var cnt = [Int](repeating: 0, count: 256)
    for y in 0..<h {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
      for x in 0..<w {
        let l = Int(row[x])
        if l == 0 { continue }
        if x < minX[l] { minX[l] = x }
        if y < minY[l] { minY[l] = y }
        if x > maxX[l] { maxX[l] = x }
        if y > maxY[l] { maxY[l] = y }
        sumX[l] += x
        sumY[l] += y
        cnt[l] += 1
      }
    }
    // le point de la silhouette le plus proche de son centre de gravité (le centre peut tomber hors de la personne)
    var bestD = [Int](repeating: Int.max, count: 256)
    var bestX = [Int](repeating: 0, count: 256)
    var bestY = [Int](repeating: 0, count: 256)
    for y in 0..<h {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
      for x in 0..<w {
        let l = Int(row[x])
        if l == 0 || cnt[l] == 0 { continue }
        let dx = x - sumX[l] / cnt[l]
        let dy = y - sumY[l] / cnt[l]
        let d = dx * dx + dy * dy
        if d < bestD[l] {
          bestD[l] = d
          bestX[l] = x
          bestY[l] = y
        }
      }
    }
    var persons: [[String: Any]] = []
    let smallest = max(20, w * h / 2000)
    for l in observation.allInstances where l > 0 && l < 256 && cnt[l] >= smallest {
      persons.append([
        "x0": Double(minX[l]) / Double(w),
        "y0": Double(minY[l]) / Double(h),
        "x1": Double(maxX[l] + 1) / Double(w),
        "y1": Double(maxY[l] + 1) / Double(h),
        "px": (Double(bestX[l]) + 0.5) / Double(w),
        "py": (Double(bestY[l]) + 0.5) / Double(h),
      ])
    }
    if persons.isEmpty {
      return ["error": "Aucune personne assez grande repérée."]
    }
    return ["persons": persons]
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
