import Flutter
import UIKit
import Vision
import CoreVideo
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

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
      guard call.method == "instanceMask" || call.method == "listPersons" || call.method == "faceParts" else {
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
      let listing = call.method == "listPersons"
      let faces = call.method == "faceParts"
      DispatchQueue.global(qos: .userInitiated).async {
        let out: [String: Any]
        if faces {
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
    // d'abord MediaPipe (478 points, contours fins) ; sinon repli sur Vision (76 points) avec la raison du repli
    var fineNote = ""
    #if canImport(MediaPipeTasksVision)
    let fine = fineFaces(image: image)
    if let list = fine.faces, !list.isEmpty {
      return ["faces": list, "source": "mediapipe"]
    }
    fineNote = fine.note ?? "MediaPipe n'a trouvé aucun visage."
    #else
    fineNote = "MediaPipe n'est pas dans cette version de l'application."
    #endif
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
    return ["faces": faces, "source": "vision", "note": fineNote]
  }

  /// Le fichier du modèle MediaPipe « face_landmarker.task » (mis dans l'application par le workflow), ou nil.
  private static func faceModelPath() -> String? {
    for b in [Bundle(for: VisionBridge.self), Bundle.main] {
      if let p = b.path(forResource: "face_landmarker", ofType: "task") { return p }
    }
    return nil
  }

  #if canImport(MediaPipeTasksVision)
  /// Les contours du maillage à 478 points de MediaPipe, dans l'ordre du tour (numéros de points connus du Face Mesh).
  private static let meshRings: [(String, [Int])] = [
    ("rightEye", [33, 246, 161, 160, 159, 158, 157, 173, 133, 155, 154, 153, 145, 144, 163, 7]),
    ("leftEye", [263, 466, 388, 387, 386, 385, 384, 398, 362, 382, 381, 380, 374, 373, 390, 249]),
    ("rightBrow", [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]),
    ("leftBrow", [300, 293, 334, 296, 336, 285, 295, 282, 283, 276]),
    ("outerLips", [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146]),
    ("innerLips", [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95]),
    ("contour", [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]),
  ]

  /// Les visages vus par MediaPipe : mêmes clés que Vision (suites x, y en fractions de la photo) plus « fine ».
  private static func fineFaces(image: CGImage) -> (faces: [[String: Any]]?, note: String?) {
    guard let path = faceModelPath() else {
      return (nil, "Le modèle MediaPipe du visage n'est pas dans l'application.")
    }
    // photo réduite à 1536 px au plus : plus rapide, et les repères sont en fractions donc indépendants de la taille
    var work = image
    let longSide = max(image.width, image.height)
    if longSide > 1536 {
      let scale = 1536.0 / Double(longSide)
      let nw = max(1, Int(Double(image.width) * scale))
      let nh = max(1, Int(Double(image.height) * scale))
      if let ctx = CGContext(
        data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      {
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        if let small = ctx.makeImage() { work = small }
      }
    }
    do {
      let options = FaceLandmarkerOptions()
      options.baseOptions.modelAssetPath = path
      options.runningMode = .image
      options.numFaces = 10
      let landmarker = try FaceLandmarker(options: options)
      let mpImage = try MPImage(uiImage: UIImage(cgImage: work))
      let result = try landmarker.detect(image: mpImage)
      var faces: [[String: Any]] = []
      for marks in result.faceLandmarks {
        if marks.count < 468 { continue }
        var x0 = 1.0, y0 = 1.0, x1 = 0.0, y1 = 0.0
        for m in marks {
          x0 = min(x0, Double(m.x))
          y0 = min(y0, Double(m.y))
          x1 = max(x1, Double(m.x))
          y1 = max(y1, Double(m.y))
        }
        var face: [String: Any] = ["x0": x0, "y0": y0, "x1": x1, "y1": y1, "fine": true]
        for (name, ring) in meshRings {
          var values: [Double] = []
          for i in ring {
            values.append(Double(marks[i].x))
            values.append(Double(marks[i].y))
          }
          face[name] = values
        }
        faces.append(face)
      }
      if faces.isEmpty { return (nil, "MediaPipe n'a trouvé aucun visage.") }
      return (faces, nil)
    } catch {
      return (nil, "MediaPipe a échoué : \(error.localizedDescription)")
    }
  }
  #endif

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
