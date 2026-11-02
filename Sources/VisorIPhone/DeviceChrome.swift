import AppKit

/// Botón lateral del bezel (volumen, encendido, silencio).
struct ChromeButton {
  enum Action { case volumeUp, volumeDown, power, mute }

  let action: Action
  let title: String
  let image: NSImage
  let imageDown: NSImage
  let anchorRight: Bool
  let normal: CGPoint
  let rollover: CGPoint
}

/// Bezel del dispositivo, el mismo que dibujan Device Hub y el Simulador (recursos de DeviceKit en Xcode).
/// Todas las medidas están en puntos del dispositivo, con origen arriba a la izquierda.
final class DeviceChrome {
  /// Orden de NSDrawNinePartImage: esquinas y bordes alrededor de la pantalla.
  let pieces: [NSImage]
  let border: NSEdgeInsets
  let padding: NSEdgeInsets
  let buttons: [ChromeButton]
  let maskPDF: NSImage?

  private init(pieces: [NSImage], border: NSEdgeInsets, padding: NSEdgeInsets, buttons: [ChromeButton], maskPDF: NSImage?) {
    self.pieces = pieces
    self.border = border
    self.padding = padding
    self.buttons = buttons
    self.maskPDF = maskPDF
  }

  private static let deviceTypeDirs = [
    "/Library/Developer/CoreSimulator/Profiles/DeviceTypes",
    "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes",
  ]

  /// Busca el perfil del Simulador con el mismo modelo («iPhone13,2») para saber qué bezel y máscara usa.
  static func load(productType: String) -> DeviceChrome? {
    let fm = FileManager.default
    var profile: [String: Any]?
    search: for dir in deviceTypeDirs {
      for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".simdevicetype") {
        let url = URL(fileURLWithPath: dir).appending(path: "\(name)/Contents/Resources/profile.plist")
        guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { continue }
        if plist["modelIdentifier"] as? String == productType {
          profile = plist
          break search
        }
      }
    }
    guard let profile, let chromeID = profile["chromeIdentifier"] as? String,
      let chromeName = chromeID.components(separatedBy: ".").last
    else { return nil }

    let resources = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome/\(chromeName).devicechrome/Contents/Resources")
    guard let data = try? Data(contentsOf: resources.appending(path: "chrome.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let images = json["images"] as? [String: Any]
    else { return nil }

    let image = { (name: String) in NSImage(contentsOf: resources.appending(path: "\(name).pdf")) }
    let keys = ["topLeft", "top", "topRight", "left", "screen", "right", "bottomLeft", "bottom", "bottomRight"]
    let pieces = keys.compactMap { (images[$0] as? String).flatMap(image) }
    guard pieces.count == keys.count else { return nil }

    let insets = { (dict: Any?, keys: [String]) -> NSEdgeInsets in
      let d = dict as? [String: Any] ?? [:]
      let v = keys.map { CGFloat(d[$0] as? Double ?? 0) }
      return NSEdgeInsets(top: v[0], left: v[1], bottom: v[2], right: v[3])
    }
    let border = insets(images["sizing"], ["topHeight", "leftWidth", "bottomHeight", "rightWidth"])
    let padding = insets(images["devicePadding"], ["top", "left", "bottom", "right"])

    let actions: [String: ChromeButton.Action] = ["volume-up": .volumeUp, "volume-down": .volumeDown, "power": .power, "mute": .mute]
    let titles: [ChromeButton.Action: String] = [.volumeUp: "Subir volumen", .volumeDown: "Bajar volumen", .power: "Bloquear / desbloquear", .mute: "Silencio"]
    let point = { (dict: Any?) -> CGPoint in
      let d = dict as? [String: Any] ?? [:]
      return CGPoint(x: d["x"] as? Double ?? 0, y: d["y"] as? Double ?? 0)
    }
    let buttons: [ChromeButton] = (json["inputs"] as? [[String: Any]] ?? []).compactMap { input in
      guard let name = input["name"] as? String, let action = actions[name],
        let normal = (input["image"] as? String).flatMap(image),
        let down = (input["imageDown"] as? String).flatMap(image)
      else { return nil }
      let offsets = input["offsets"] as? [String: Any] ?? [:]
      return ChromeButton(
        action: action, title: titles[action] ?? name, image: normal, imageDown: down,
        anchorRight: input["anchor"] as? String == "right",
        normal: point(offsets["normal"]), rollover: point(offsets["rollover"]))
    }

    let mask = (profile["framebufferMask"] as? String).flatMap {
      NSImage(contentsOf: URL(fileURLWithPath: "/Library/Developer/DeviceKit/FramebufferMasks/\($0).pdf"))
    }
    return DeviceChrome(pieces: pieces, border: border, padding: padding, buttons: buttons, maskPDF: mask)
  }

  func deviceSize(screen: CGSize) -> CGSize {
    CGSize(
      width: padding.left + border.left + screen.width + border.right + padding.right,
      height: padding.top + border.top + screen.height + border.bottom + padding.bottom)
  }

  func frameRect(screen: CGSize) -> CGRect {
    CGRect(x: padding.left, y: padding.top, width: border.left + screen.width + border.right, height: border.top + screen.height + border.bottom)
  }

  func screenRect(screen: CGSize) -> CGRect {
    CGRect(origin: CGPoint(x: padding.left + border.left, y: padding.top + border.top), size: screen)
  }

  /// Los botones asoman por detrás del marco; al pasar el mouse salen un poco más (offset «rollover»).
  func rect(for button: ChromeButton, screen: CGSize, hover: Bool) -> CGRect {
    let offset = hover ? button.rollover : button.normal
    let size = button.image.size
    let x = button.anchorRight ? deviceSize(screen: screen).width + offset.x - size.width : offset.x
    return CGRect(x: x, y: padding.top + offset.y, width: size.width, height: size.height)
  }

  /// Forma visible de la pantalla (esquinas redondeadas y notch) rasterizada al tamaño pedido.
  func maskImage(pixelSize: CGSize) -> CGImage? {
    guard let maskPDF else { return nil }
    var rect = CGRect(origin: .zero, size: pixelSize)
    return maskPDF.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  /// Rasteriza botones y marco una sola vez. Los bordes miden 1 pt y se estiran: NSDrawNinePartImage
  /// los repetiría cientos de veces por cuadro y saturaba el hilo principal.
  func render(screen: CGSize, scale: CGFloat, hovered: ChromeButton.Action?, pressed: ChromeButton.Action?) -> CGImage? {
    let size = deviceSize(screen: screen)
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let draw = { (image: NSImage, rect: CGRect) in
      image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    for button in buttons {
      draw(pressed == button.action ? button.imageDown : button.image, rect(for: button, screen: screen, hover: hovered == button.action))
    }
    let f = frameRect(screen: screen)
    let (tl, top, tr, left, center, right, bl, bottom, br) = (pieces[0], pieces[1], pieces[2], pieces[3], pieces[4], pieces[5], pieces[6], pieces[7], pieces[8])
    draw(tl, CGRect(origin: f.origin, size: tl.size))
    draw(tr, CGRect(x: f.maxX - tr.size.width, y: f.minY, width: tr.size.width, height: tr.size.height))
    draw(bl, CGRect(x: f.minX, y: f.maxY - bl.size.height, width: bl.size.width, height: bl.size.height))
    draw(br, CGRect(x: f.maxX - br.size.width, y: f.maxY - br.size.height, width: br.size.width, height: br.size.height))
    draw(top, CGRect(x: f.minX + tl.size.width, y: f.minY, width: f.width - tl.size.width - tr.size.width, height: top.size.height))
    draw(bottom, CGRect(x: f.minX + bl.size.width, y: f.maxY - bottom.size.height, width: f.width - bl.size.width - br.size.width, height: bottom.size.height))
    draw(left, CGRect(x: f.minX, y: f.minY + tl.size.height, width: left.size.width, height: f.height - tl.size.height - bl.size.height))
    draw(right, CGRect(x: f.maxX - right.size.width, y: f.minY + tr.size.height, width: right.size.width, height: f.height - tr.size.height - br.size.height))
    draw(center, CGRect(x: f.minX + left.size.width, y: f.minY + top.size.height, width: f.width - left.size.width - right.size.width, height: f.height - top.size.height - bottom.size.height))
    return context.makeImage()
  }
}
