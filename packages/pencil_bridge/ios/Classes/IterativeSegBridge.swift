import Flutter
import CoreGraphics
import Foundation
import Vision

/// Essai : segmentation au toucher de Vision (Apple, iPadOS 27 : GenerateIterativeSegmentationRequest).
/// Dart envoie la photo (RGBA 8 bits) et un point (fractions de la photo, origine en haut à gauche) ; la réponse est un masque
/// d'un octet par pixel (255 = dans l'objet) à la taille de la photo, le temps de calcul, ou un message d'erreur lisible.
final class IterativeSegBridge {
  static func segment(
    rgba: Data, width: Int, height: Int, points: [[Double]], completion: @escaping ([String: Any]) -> Void
  ) {
    guard #available(iOS 27.0, *) else {
      completion(["error": "La segmentation au toucher de Vision demande iPadOS 27 ou plus."])
      return
    }
    Task.detached {
      completion(await run(rgba: rgba, width: width, height: height, points: points))
    }
  }

  @available(iOS 27.0, *)
  private static func run(rgba: Data, width: Int, height: Int, points: [[Double]]) async -> [String: Any] {
    guard width > 0, height > 0, rgba.count >= width * height * 4, let first = points.first, first.count >= 2,
      let provider = CGDataProvider(data: rgba as CFData)
    else { return ["error": "Photo ou point illisible."] }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
        shouldInterpolate: true, intent: .defaultIntent)
    else { return ["error": "Photo illisible."] }
    let started = Date()
    do {
      // Vision compte les ordonnées à partir du bas de l'image.
      var request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: first[0], y: 1 - first[1]))
      for p in points.dropFirst() where p.count >= 3 {
        let pt = NormalizedPoint(x: p[0], y: 1 - p[1])
        if p[2] > 0.5 { try request.addIncludedPoint(pt) } else { try request.addExcludedPoint(pt) }
      }
      // Le modèle de Vision est téléchargé par Apple à la première utilisation (DownloadableAssetsRequest) : on le télécharge si besoin.
      var downloaded = false
      let status = await request.assetStatus
      if case .ready = status {
      } else {
        try await request.downloadAssets()
        downloaded = true
      }
      let handler = ImageRequestHandler(image)
      guard let observation = try await handler.perform(request) else {
        return ["error": "Vision n'a trouvé aucun objet à cet endroit."]
      }
      let maskImage = try observation.cgImage
      // Masque ramené à la taille de la photo, en niveaux de gris : > 127 = dans l'objet.
      var out = Data(count: width * height)
      let ok: Bool = out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
        guard let base = buf.baseAddress,
          let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      if !ok { return ["error": "Masque de Vision illisible."] }
      return [
        "mask": FlutterStandardTypedData(bytes: out),
        "ms": Date().timeIntervalSince(started) * 1000,
        "downloaded": downloaded,
        "maskWidth": maskImage.width,
        "maskHeight": maskImage.height,
      ]
    } catch {
      return ["error": "Vision : \(error.localizedDescription)"]
    }
  }
}
