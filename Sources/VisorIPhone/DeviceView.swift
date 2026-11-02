import AppKit
import QuartzCore
import SwiftUI

/// Orientación pedida a WebDriverAgent. «LANDSCAPE» gira el iPhone a la izquierda (el notch queda a la izquierda).
enum Orientation: String {
  case portrait = "PORTRAIT"
  case landscapeLeft = "LANDSCAPE"
  case landscapeRight = "UIA_DEVICE_ORIENTATION_LANDSCAPERIGHT"

  /// Grados para frameCenterRotation (positivo = antihorario).
  var degrees: CGFloat {
    switch self {
    case .portrait: 0
    case .landscapeLeft: 90
    case .landscapeRight: -90
    }
  }
}

enum Gesture {
  case tap(CGPoint)
  case hold(CGPoint, TimeInterval)
  case drag([(point: CGPoint, time: TimeInterval)])
}

@MainActor
protocol DeviceViewDelegate: AnyObject {
  /// Puntos en la orientación nativa (vertical) de la pantalla del iPhone.
  func deviceView(didGesture gesture: Gesture)
  func deviceView(didPress button: ChromeButton.Action)
  func deviceView(didType text: String)
  func deviceViewDidPaste()
  /// Modo en vivo (puntero Bluetooth): cada movimiento, con el «dedo» apoyado o no.
  func deviceView(livePointer point: CGPoint, pressed: Bool)
  /// Modo en vivo: clics de rueda (positivo = hacia arriba / derecha) sobre lo que esté bajo el puntero.
  func deviceView(liveScrollY dy: Int, x dx: Int)
}

/// iPhone dibujado con su bezel; la pantalla es una capa con el último cuadro del stream.
/// Coordenadas internas en puntos del dispositivo; `scale` las lleva al tamaño de la vista.
final class DeviceView: NSView {
  weak var delegate: DeviceViewDelegate?
  var chrome: DeviceChrome? { didSet { invalidateGeometry() } }
  var showBezel = true { didSet { if oldValue != showBezel { invalidateGeometry() } } }
  var screenSize = CGSize(width: 390, height: 844) { didSet { if oldValue != screenSize { invalidateGeometry() } } }
  var keyboardEnabled = true
  /// Con el puntero Bluetooth conectado, el mouse se transmite en vivo en lugar de mandar gestos al soltar.
  var liveInput = false {
    didSet { if !liveInput { livePressed = false } }
  }
  private var livePressed = false
  /// Si el puntero del iPhone sigue al mouse sin hacer clic (iOS resalta cada elemento al pasar).
  var liveHover = false
  /// Dónde se presionó; hasta alejarse 4 pt no se mandan movimientos, para que el temblor del clic no sea un arrastre.
  private var livePressPoint: CGPoint?

  private let bezelLayer = CALayer()
  private var bezelKey = ""
  private let screenLayer = CALayer()
  private let imageLayer = CALayer()
  /// Video por cable (AVCaptureVideoPreviewLayer); si existe, reemplaza a los cuadros MJPEG.
  private var liveLayer: CALayer?
  private var contentSize = CGSize.zero
  private let maskLayer = CALayer()
  private let flashLayer = CALayer()
  private let touchLayer = CAShapeLayer()
  private var maskPixelSize = CGSize.zero
  private var samples: [(point: CGPoint, time: TimeInterval)] = []
  private var pressed: ChromeButton.Action?
  private var hovered: ChromeButton.Action?
  private var scroll: (start: CGPoint, time: TimeInterval, delta: CGPoint)?
  /// Scroll en vivo por rueda: si hay un gesto en curso y lo que sobra de puntos que aún no llega a un clic de rueda.
  private var wheelActive = false
  private var wheelRemainder = CGPoint.zero
  private var wheelIdle: DispatchWorkItem?
  /// Puntos del iPhone por clic de rueda.
  private static let pointsPerWheelStep: CGFloat = 8
  private var scrollFlush: DispatchWorkItem?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    screenLayer.backgroundColor = NSColor.black.cgColor
    screenLayer.masksToBounds = true
    screenLayer.mask = maskLayer
    imageLayer.contentsGravity = .resize
    imageLayer.minificationFilter = .trilinear
    flashLayer.backgroundColor = NSColor.white.cgColor
    flashLayer.opacity = 0
    touchLayer.fillColor = NSColor(white: 1, alpha: 0.32).cgColor
    touchLayer.strokeColor = NSColor(white: 1, alpha: 0.75).cgColor
    touchLayer.lineWidth = 1.5
    touchLayer.isHidden = true
    bezelLayer.contentsGravity = .resize
    screenLayer.addSublayer(imageLayer)
    screenLayer.addSublayer(flashLayer)
    layer?.addSublayer(bezelLayer)
    layer?.addSublayer(screenLayer)
    layer?.addSublayer(touchLayer)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: Geometría

  private var activeChrome: DeviceChrome? { showBezel ? chrome : nil }

  var deviceSize: CGSize { activeChrome?.deviceSize(screen: screenSize) ?? screenSize }

  private var screenRect: CGRect { activeChrome?.screenRect(screen: screenSize) ?? CGRect(origin: .zero, size: screenSize) }

  private var scale: CGFloat { deviceSize.width > 0 ? bounds.width / deviceSize.width : 1 }

  private func invalidateGeometry() {
    maskPixelSize = .zero
    bezelKey = ""
    needsLayout = true
    superview?.needsLayout = true
  }

  /// El bezel se rasteriza solo cuando cambia el tamaño o el estado de un botón.
  private func updateBezel() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    bezelLayer.frame = bounds
    guard let chrome = activeChrome, bounds.width > 0 else {
      bezelLayer.contents = nil
      bezelKey = ""
      return
    }
    let pixelScale = scale * (window?.backingScaleFactor ?? 2)
    let key = "\(bounds.size)|\(pixelScale)|\(String(describing: hovered))|\(String(describing: pressed))"
    guard key != bezelKey else { return }
    bezelKey = key
    bezelLayer.contents = chrome.render(screen: screenSize, scale: pixelScale, hovered: hovered, pressed: pressed)
  }

  override func layout() {
    super.layout()
    let s = scale
    let rect = screenRect
    let backing = window?.backingScaleFactor ?? 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    screenLayer.frame = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
    maskLayer.frame = screenLayer.bounds
    flashLayer.frame = screenLayer.bounds
    let pixels = CGSize(width: (screenLayer.bounds.width * backing).rounded(), height: (screenLayer.bounds.height * backing).rounded())
    if pixels != maskPixelSize, pixels.width > 0 {
      maskPixelSize = pixels
      if let mask = chrome?.maskImage(pixelSize: pixels) {
        maskLayer.contents = mask
        maskLayer.backgroundColor = nil
        maskLayer.cornerRadius = 0
      } else {
        maskLayer.contents = nil
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.cornerRadius = 47 * s
      }
    }
    layoutContent()
    CATransaction.commit()
    updateBezel()
  }

  /// Si el video llega en horizontal (la app giró), se devuelve a la vertical nativa de la pantalla.
  private func layoutContent() {
    let bounds = screenLayer.bounds
    let content = liveLayer ?? imageLayer
    content.setAffineTransform(.identity)
    if contentSize.width > contentSize.height {
      content.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
      content.position = CGPoint(x: bounds.midX, y: bounds.midY)
      let angle = (superview as? DeviceHostView)?.orientation == .landscapeRight ? CGFloat.pi / 2 : -CGFloat.pi / 2
      content.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    } else {
      content.frame = bounds
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let backing = window?.backingScaleFactor ?? 2
    for l in [screenLayer, imageLayer, maskLayer, flashLayer, touchLayer] { l.contentsScale = backing }
    invalidateGeometry()
  }

  // MARK: Video

  func show(_ image: CGImage) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = image
    setContentSize(CGSize(width: image.width, height: image.height))
    CATransaction.commit()
  }

  func setContentSize(_ size: CGSize) {
    let turned = (size.width > size.height) != (contentSize.width > contentSize.height)
    contentSize = size
    if turned {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layoutContent()
      CATransaction.commit()
    }
  }

  /// Muestra una capa de video en vivo (cable) en lugar de los cuadros MJPEG; nil vuelve a MJPEG.
  func setLive(_ layer: CALayer?) {
    guard layer !== liveLayer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    liveLayer?.removeFromSuperlayer()
    liveLayer = layer
    if let layer { screenLayer.insertSublayer(layer, below: flashLayer) }
    imageLayer.isHidden = layer != nil
    layoutContent()
    CATransaction.commit()
  }

  func clearScreen() {
    imageLayer.contents = nil
  }

  func flash() {
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 0.85
    animation.toValue = 0
    animation.duration = 0.35
    flashLayer.add(animation, forKey: "flash")
  }

  // MARK: Mouse y trackpad

  private func devicePoint(_ event: NSEvent) -> CGPoint {
    let p = convert(event.locationInWindow, from: nil)
    return CGPoint(x: p.x / scale, y: p.y / scale)
  }

  private func screenPoint(_ p: CGPoint, clamp: Bool = false) -> CGPoint? {
    let rect = screenRect
    if !clamp && !rect.contains(p) { return nil }
    let x = min(max(p.x - rect.minX, 0), rect.width - 1)
    let y = min(max(p.y - rect.minY, 0), rect.height - 1)
    return CGPoint(x: x, y: y)
  }

  private func button(at p: CGPoint) -> ChromeButton? {
    guard let chrome = activeChrome else { return nil }
    return chrome.buttons.first { chrome.rect(for: $0, screen: screenSize, hover: true).contains(p) }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  override func mouseMoved(with event: NSEvent) {
    // En vivo, el puntero del iPhone sigue al mouse como en Device Hub.
    if liveInput && liveHover, let sp = screenPoint(devicePoint(event)) { delegate?.deviceView(livePointer: sp, pressed: false) }
    let action = button(at: devicePoint(event))?.action
    if action != hovered {
      hovered = action
      updateBezel()
      toolTip = button(at: devicePoint(event))?.title
    }
  }

  override func mouseExited(with event: NSEvent) {
    if hovered != nil {
      hovered = nil
      updateBezel()
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let p = devicePoint(event)
    if let button = button(at: p) {
      pressed = button.action
      updateBezel()
      return
    }
    guard let sp = screenPoint(p) else { return }
    showTouch(at: p)
    if liveInput {
      livePressed = true
      livePressPoint = sp
      delegate?.deviceView(livePointer: sp, pressed: true)
      return
    }
    samples = [(sp, event.timestamp)]
  }

  override func mouseDragged(with event: NSEvent) {
    if livePressed, let sp = screenPoint(devicePoint(event), clamp: true) {
      if let start = livePressPoint {
        guard hypot(sp.x - start.x, sp.y - start.y) >= 4 else { return }
        livePressPoint = nil
      }
      delegate?.deviceView(livePointer: sp, pressed: true)
      showTouch(at: CGPoint(x: sp.x + screenRect.minX, y: sp.y + screenRect.minY))
      return
    }
    guard pressed == nil, !samples.isEmpty, let sp = screenPoint(devicePoint(event), clamp: true) else { return }
    samples.append((sp, event.timestamp))
    showTouch(at: CGPoint(x: sp.x + screenRect.minX, y: sp.y + screenRect.minY))
  }

  override func mouseUp(with event: NSEvent) {
    if let action = pressed {
      pressed = nil
      updateBezel()
      if button(at: devicePoint(event))?.action == action { delegate?.deviceView(didPress: action) }
      return
    }
    if livePressed {
      livePressed = false
      touchLayer.isHidden = true
      // Un clic sin arrastre se suelta donde se presionó.
      if let sp = livePressPoint ?? screenPoint(devicePoint(event), clamp: true) { delegate?.deviceView(livePointer: sp, pressed: false) }
      livePressPoint = nil
      return
    }
    guard !samples.isEmpty else { return }
    if let sp = screenPoint(devicePoint(event), clamp: true) { samples.append((sp, event.timestamp)) }
    let path = samples
    samples.removeAll()
    touchLayer.isHidden = true
    let first = path[0]
    let last = path[path.count - 1]
    let distance = hypot(last.point.x - first.point.x, last.point.y - first.point.y)
    let duration = last.time - first.time
    if distance < 6 {
      delegate?.deviceView(didGesture: duration > 0.45 ? .hold(first.point, duration) : .tap(first.point))
    } else {
      delegate?.deviceView(didGesture: .drag(Self.simplify(path: path)))
    }
  }

  /// Como mucho ~24 muestras: WDA ejecuta cada tramo como un movimiento con su duración.
  private static func simplify(path: [(point: CGPoint, time: TimeInterval)]) -> [(point: CGPoint, time: TimeInterval)] {
    guard path.count > 24 else { return path }
    let step = Double(path.count - 1) / 23
    return (0..<24).map { path[Int((Double($0) * step).rounded())] }
  }

  private func showTouch(at p: CGPoint) {
    let s = scale
    let radius = 17 * s
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    touchLayer.path = CGPath(ellipseIn: CGRect(x: p.x * s - radius, y: p.y * s - radius, width: radius * 2, height: radius * 2), transform: nil)
    touchLayer.isHidden = false
    CATransaction.commit()
  }

  override func scrollWheel(with event: NSEvent) {
    if liveInput {
      liveScroll(event)
      return
    }
    // La inercia la pone iOS: solo cuenta el tramo con los dedos en el trackpad.
    guard event.momentumPhase.isEmpty else { return }
    let p = devicePoint(event)
    let unit: CGFloat = (event.hasPreciseScrollingDeltas ? 1 : 12) / scale
    let delta = CGPoint(x: event.scrollingDeltaX * unit, y: event.scrollingDeltaY * unit)

    if event.phase == .began || scroll == nil {
      guard let start = screenPoint(p) else { return }
      scroll = (start, event.timestamp, .zero)
    }
    scroll?.delta.x += delta.x
    scroll?.delta.y += delta.y

    if event.phase == .ended || event.phase == .cancelled {
      finishScroll(at: event.timestamp)
    } else if event.phase.isEmpty {
      // Rueda de mouse clásica: se agrupan los saltos que llegan seguidos.
      scrollFlush?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.finishScroll(at: ProcessInfo.processInfo.systemUptime) }
      scrollFlush = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
  }

  /// Scroll en vivo como rueda de mouse: no presiona nada, así no se «pega» a un botón ni termina en clic.
  /// Incluye la inercia del trackpad, que en iOS se ve como seguir girando la rueda.
  private func liveScroll(_ event: NSEvent) {
    let gestureStart = event.phase == .began || (!wheelActive && event.momentumPhase.isEmpty)
    if gestureStart {
      guard let sp = screenPoint(devicePoint(event)) else { return }
      wheelActive = true
      wheelRemainder = .zero
      // La rueda mueve lo que está bajo el puntero: primero se lleva ahí.
      delegate?.deviceView(livePointer: sp, pressed: false)
    }
    guard wheelActive else { return }
    let unit: CGFloat = (event.hasPreciseScrollingDeltas ? 1 : 12) / scale
    wheelRemainder.x += event.scrollingDeltaX * unit
    wheelRemainder.y += event.scrollingDeltaY * unit
    let step = Self.pointsPerWheelStep
    let dy = Int(wheelRemainder.y / step)
    let dx = Int(wheelRemainder.x / step)
    wheelRemainder.y -= CGFloat(dy) * step
    wheelRemainder.x -= CGFloat(dx) * step
    // Con el desplazamiento natural, deltaY negativo (dedos hacia arriba) es bajar en el contenido: rueda negativa.
    if dy != 0 || dx != 0 { delegate?.deviceView(liveScrollY: dy, x: -dx) }
    if event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase.isEmpty) || event.phase == .cancelled {
      wheelActive = false
    }
    // Rueda clásica (sin fases): el gesto termina tras una pausa.
    wheelIdle?.cancel()
    let idle = DispatchWorkItem { [weak self] in self?.wheelActive = false }
    wheelIdle = idle
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: idle)
  }

  private func clampToScreen(_ p: CGPoint) -> CGPoint {
    CGPoint(x: min(max(p.x, 1), screenSize.width - 1), y: min(max(p.y, 1), screenSize.height - 1))
  }

  private func finishScroll(at time: TimeInterval) {
    guard let s = scroll else { return }
    scroll = nil
    guard hypot(s.delta.x, s.delta.y) > 4 else { return }
    let end = clampToScreen(CGPoint(x: s.start.x + s.delta.x, y: s.start.y + s.delta.y))
    let duration = min(max(time - s.time, 0.08), 0.6)
    delegate?.deviceView(didGesture: .drag([(s.start, 0), (end, duration)]))
  }

  // MARK: Teclado

  /// Teclas especiales de XCUIKeyboardKey.
  private static let specialKeys: [UInt16: String] = [
    51: "\u{8}", 117: "\u{7F}", 36: "\n", 76: "\n", 48: "\t",
    123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}",
  ]

  override func keyDown(with event: NSEvent) {
    guard keyboardEnabled, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else {
      super.keyDown(with: event)
      return
    }
    if let special = Self.specialKeys[event.keyCode] {
      delegate?.deviceView(didType: special)
    } else if let text = event.characters, !text.isEmpty, event.keyCode != 53 {
      delegate?.deviceView(didType: text)
    } else {
      super.keyDown(with: event)
    }
  }

  @objc func paste(_ sender: Any?) {
    delegate?.deviceViewDidPaste()
  }
}

/// Centra el iPhone en el espacio disponible, lo escala y lo gira como Device Hub.
final class DeviceHostView: NSView {
  let deviceView = DeviceView()
  var orientation: Orientation = .portrait {
    didSet { if oldValue != orientation { needsLayout = true } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(deviceView)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let size = deviceView.deviceSize
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
    let turned = orientation != .portrait
    let w = turned ? size.height : size.width
    let h = turned ? size.width : size.height
    // Hasta tamaño real en puntos: más grande solo se ve borroso.
    let s = min(bounds.width / w, bounds.height / h, 1.25)
    let fitted = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    deviceView.frameCenterRotation = 0
    deviceView.frame = CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    deviceView.frameCenterRotation = orientation.degrees
    deviceView.needsLayout = true
  }
}

/// Puente a SwiftUI.
struct DeviceCanvas: NSViewRepresentable {
  let session: DeviceSession

  func makeNSView(context: Context) -> DeviceHostView {
    let host = DeviceHostView()
    host.deviceView.delegate = session
    session.attach(host.deviceView)
    return host
  }

  func updateNSView(_ host: DeviceHostView, context: Context) {
    host.orientation = session.orientation
    let view = host.deviceView
    view.chrome = session.chrome
    view.showBezel = session.showBezel
    view.screenSize = session.screenSize
    view.keyboardEnabled = session.keyboardEnabled
    view.liveInput = session.bluetoothState == .ready
    view.liveHover = session.bluetoothHover
    host.needsLayout = true
  }
}
