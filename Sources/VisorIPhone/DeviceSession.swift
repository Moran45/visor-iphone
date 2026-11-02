import AVFoundation
import AppKit
import Observation

/// Estado de la app: qué iPhone, si WebDriverAgent corre, y el puente entre la vista y WDA.
@MainActor
@Observable
final class DeviceSession {
  enum Phase: Equatable {
    case idle
    case starting(String)
    case running
    case failed(String)
  }

  /// De dónde sale el video: cable (como QuickTime, 60 fps) o WebDriverAgent por la red (MJPEG).
  enum VideoSource: String {
    case none = "Sin video"
    case usb = "Cable USB"
    case wifi = "WebDriverAgent (red)"
  }

  var devices: [PhysicalDevice] = []
  var selectedID: String? {
    didSet {
      guard oldValue != selectedID else { return }
      defaults.set(selectedID, forKey: "device")
      if oldValue != nil, selected?.available == true { start() }
    }
  }
  var phase: Phase = .idle {
    didSet { if phase != oldValue { writeLog("[visor] \(phase)") } }
  }
  var hasFrame = false
  var videoSource = VideoSource.none
  var isLocked = false
  var bluetoothState = BluetoothPointer.State.off
  var screenSize = CGSize(width: 390, height: 844)
  var orientation: Orientation = .portrait
  var fps = 0
  var frameSize = CGSize.zero
  var wdaURL: URL?
  var log: [String] = []
  var toast: String?
  var keyboardEnabled = true

  var showBezel: Bool { didSet { defaults.set(showBezel, forKey: "showBezel") } }
  var framerate: Double { didSet { defaults.set(framerate, forKey: "framerate") } }
  var resolution: Double { didSet { defaults.set(resolution, forKey: "resolution") } }
  var quality: Double { didSet { defaults.set(quality, forKey: "quality") } }
  var team: String { didSet { defaults.set(team, forKey: "team") } }
  var bundleID: String { didSet { defaults.set(bundleID, forKey: "bundleID") } }
  var bluetoothHover: Bool { didSet { defaults.set(bluetoothHover, forKey: "bluetoothHover") } }
  var bluetoothEnabled: Bool {
    didSet {
      defaults.set(bluetoothEnabled, forKey: "bluetoothEnabled")
      guard bluetoothEnabled != oldValue else { return }
      if bluetoothEnabled, phase != .idle, let device = selected { bluetooth.start(deviceName: device.name) } else { bluetooth.stop() }
    }
  }

  @ObservationIgnored private let defaults = UserDefaults.standard
  @ObservationIgnored private let runner = WDARunner()
  @ObservationIgnored private let stream = MJPEGStream()
  @ObservationIgnored private let usb = USBScreenCapture()
  @ObservationIgnored private let bluetooth = BluetoothPointer()
  @ObservationIgnored private var client: WDAClient?
  @ObservationIgnored private weak var view: DeviceView?
  @ObservationIgnored private var frames = 0
  @ObservationIgnored private var lastInput: Task<Void, Never>?
  @ObservationIgnored private var pendingText = ""
  /// Comandos directos del parche de WDA; si el WDA instalado no los tiene, se usan los normales.
  @ObservationIgnored private var directInput = true
  @ObservationIgnored private var lockCheck: Task<Void, Never>?
  @ObservationIgnored private var ticks = 0
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var chromes: [String: DeviceChrome?] = [:]
  @ObservationIgnored private var logFile: FileHandle?

  /// El registro de la última sesión también queda en disco para revisarlo fuera de la app.
  static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appending(path: "Logs/Visor iPhone.log")

  init() {
    let d = UserDefaults.standard
    showBezel = d.object(forKey: "showBezel") as? Bool ?? true
    framerate = d.object(forKey: "framerate") as? Double ?? 30
    // Al 100 % WDA manda el JPEG tal cual; escalarlo en el iPhone lo hace más lento.
    resolution = d.object(forKey: "resolution") as? Double ?? 100
    quality = d.object(forKey: "quality") as? Double ?? 35
    team = d.string(forKey: "team") ?? "5JFGL5PVW6"
    bundleID = d.string(forKey: "bundleID") ?? "com.carlosmoran.wdaprueba.WebDriverAgentRunner"
    bluetoothEnabled = d.object(forKey: "bluetoothEnabled") as? Bool ?? true
    bluetoothHover = d.object(forKey: "bluetoothHover") as? Bool ?? false

    stream.onFrame = { [weak self] image in self?.receive(image) }
    stream.onDisconnect = { [weak self] in
      guard let self, self.phase == .running else { return }
      self.hasFrame = false
    }
    usb.onSize = { [weak self] size in
      guard let self, self.videoSource == .usb else { return }
      self.view?.setContentSize(size)
      self.frameSize = size
      if !self.hasFrame { self.hasFrame = true }
    }
    USBScreenCapture.enableDevices()
    for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          Task { await self.updateVideoSource() }
        }
      }
    }
    bluetooth.onState = { [weak self] state in
      guard let self else { return }
      self.bluetoothState = state
      self.writeLog("[visor] puntero Bluetooth: \(state)")
    }
    bluetooth.onLog = { [weak self] line in self?.writeLog(line) }
    runner.onLog = { [weak self] line in self?.appendLog(line) }
    runner.onReady = { [weak self] url in Task { await self?.connect(url) } }
    runner.onExit = { [weak self] message in self?.wdaExited(message) }
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let count = self.videoSource == .usb ? self.usb.takeFrameCount() : self.frames
        if self.fps != count { self.fps = count }
        self.frames = 0
        self.ticks += 1
        if self.ticks % 4 == 0 { self.checkLock() }
      }
    }
  }

  var selected: PhysicalDevice? { devices.first { $0.id == selectedID } }

  var chrome: DeviceChrome? {
    guard let type = selected?.productType, !type.isEmpty else { return nil }
    if let cached = chromes[type] { return cached }
    let loaded = DeviceChrome.load(productType: type)
    chromes[type] = loaded
    return loaded
  }

  var isRunning: Bool { phase == .running }

  func attach(_ view: DeviceView) {
    self.view = view
  }

  // MARK: Ciclo de vida

  /// Al abrir: busca iPhones y, si el último usado está conectado, empieza a verlo.
  func bootstrap() async {
    await refreshDevices()
    if selected?.available == true { start() }
  }

  func refreshDevices() async {
    let found = await DeviceList.load()
    devices = found
    if selected == nil {
      selectedID = found.first { $0.id == defaults.string(forKey: "device") }?.id ?? found.first { $0.available }?.id ?? found.first?.id
    }
  }

  func start() {
    guard let device = selected else {
      phase = .failed("Conecta un iPhone con el Modo de desarrollador activado.")
      return
    }
    guard device.available else {
      phase = .failed("\(device.name) no está conectado. Conéctalo por cable o a la misma red Wi-Fi.")
      return
    }
    shutdown()
    log.removeAll()
    try? FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
    logFile = try? FileHandle(forWritingTo: Self.logURL)
    orientation = .portrait
    phase = .starting("Preparando WebDriverAgent…")
    do {
      try runner.start(.init(udid: device.id, team: team, bundleID: bundleID))
    } catch {
      phase = .failed(error.localizedDescription)
    }
    // Por cable el video no necesita a WDA: aparece en segundos mientras WDA arranca.
    Task { await updateVideoSource() }
    // El puntero Bluetooth tampoco: los toques en vivo funcionan aunque WDA siga arrancando.
    if bluetoothEnabled { bluetooth.start(deviceName: device.name) }
  }

  /// Detiene el video y WebDriverAgent: mientras corre, WDA escucha sin contraseña en la red.
  func shutdown() {
    bluetooth.stop()
    stream.stop()
    usb.stop()
    view?.setLive(nil)
    videoSource = .none
    runner.stop()
    client = nil
    wdaURL = nil
    hasFrame = false
    view?.clearScreen()
    if phase != .idle { phase = .idle }
  }

  private func connect(_ url: URL) async {
    phase = .starting("Conectando con el iPhone…")
    let client = WDAClient(base: url)
    do {
      try await client.waitUntilReady()
      try await client.startSession()
      try? await client.applySettings(streamSettings)
      let size = try await client.windowSize()
      if size.width > 0 { screenSize = CGSize(width: min(size.width, size.height), height: max(size.width, size.height)) }
      self.client = client
      wdaURL = url
      phase = .running
      await updateVideoSource()
    } catch {
      phase = .failed(error.localizedDescription)
      runner.stop()
    }
  }

  private func wdaExited(_ message: String) {
    client = nil
    wdaURL = nil
    if videoSource == .wifi {
      stream.stop()
      videoSource = .none
      hasFrame = false
      view?.clearScreen()
    }
    phase = .failed(message)
  }

  /// Elige el video: por cable si el iPhone está conectado por USB; si no, el MJPEG de WebDriverAgent.
  func updateVideoSource() async {
    guard phase != .idle, let device = selected else { return }
    if let capture = USBScreenCapture.device(udid: device.id, name: device.name) {
      guard usb.deviceID != capture.uniqueID else { return }
      guard await AVCaptureDevice.requestAccess(for: .video) else {
        show(toast: "Sin permiso de cámara, el video va por la red. Actívalo en Ajustes del Sistema › Privacidad › Cámara.")
        return useNetworkVideo()
      }
      do {
        try usb.start(capture)
        stream.stop()
        view?.setLive(usb.previewLayer)
        videoSource = .usb
        writeLog("[visor] video por cable: \(capture.localizedName)")
      } catch {
        writeLog("[visor] error de video por cable: \(error.localizedDescription)")
        useNetworkVideo()
      }
    } else {
      if usb.isRunning {
        usb.stop()
        view?.setLive(nil)
        videoSource = .none
        hasFrame = false
      }
      useNetworkVideo()
    }
  }

  private func useNetworkVideo() {
    guard let url = wdaURL, videoSource != .wifi else { return }
    videoSource = .wifi
    hasFrame = false
    stream.start(host: url.host ?? "", port: 9100)
  }

  private func receive(_ image: CGImage) {
    guard videoSource == .wifi else { return }
    frames += 1
    view?.show(image)
    if !hasFrame { hasFrame = true }
    let size = CGSize(width: image.width, height: image.height)
    if size != frameSize { frameSize = size }
  }

  private func writeLog(_ line: String) {
    logFile?.write(Data((line + "\n").utf8))
  }

  private func appendLog(_ line: String) {
    log.append(line)
    if log.count > 3000 { log.removeFirst(log.count - 3000) }
    writeLog(line)
    if case .starting = phase {
      if line.contains("Unlock") && line.contains("to Continue") {
        phase = .starting("Desbloquea el iPhone para continuar…")
      } else if line.contains("Signing ") || line.contains("CodeSign ") {
        phase = .starting("Firmando WebDriverAgent…")
      } else if line.contains("Testing started") || line.contains("Test Suite") {
        phase = .starting("Abriendo WebDriverAgent en el iPhone…")
      }
    }
  }

  // MARK: Ajustes del video

  var streamSettings: [String: Any] {
    [
      "mjpegServerFramerate": Int(framerate),
      "mjpegScalingFactor": Int(resolution),
      "mjpegServerScreenshotQuality": Int(quality),
      "animationCoolOffTimeout": 0,
    ]
  }

  func applyStreamSettings() {
    enqueue { client in try await client.applySettings(self.streamSettings) }
  }

  // MARK: Acciones

  /// Las órdenes a WDA van en fila: un gesto no empieza hasta que terminó el anterior.
  private func enqueue(_ work: @escaping @MainActor (WDAClient) async throws -> Void) {
    guard let client, phase == .running else { return }
    let previous = lastInput
    lastInput = Task { @MainActor in
      await previous?.value
      do {
        try await work(client)
      } catch {
        self.writeLog("[visor] error: \(error.localizedDescription)")
        self.show(toast: error.localizedDescription)
      }
    }
  }

  /// De la vertical nativa a las coordenadas de la orientación actual, que son las que entiende WDA.
  private func toInterface(_ p: CGPoint) -> CGPoint {
    switch orientation {
    case .portrait: p
    case .landscapeLeft: CGPoint(x: p.y, y: screenSize.width - p.x)
    case .landscapeRight: CGPoint(x: screenSize.height - p.y, y: p.x)
    }
  }

  func home() { enqueue { try await $0.home() } }

  /// Si el iPhone se bloqueó (bloqueo automático), se ofrece desbloquearlo desde la app.
  private func checkLock() {
    guard let client, phase == .running, lockCheck == nil else { return }
    lockCheck = Task { @MainActor in
      if let locked = try? await client.isLocked(), locked != self.isLocked { self.isLocked = locked }
      self.lockCheck = nil
    }
  }

  func unlock() {
    enqueue { client in
      try await client.unlock()
      self.isLocked = false
    }
  }

  func toggleLock() { enqueue { try await $0.toggleLock() } }

  func volume(up: Bool) { enqueue { try await $0.pressButton(up ? "volumeUp" : "volumeDown") } }

  func rotate(clockwise: Bool) {
    let next: Orientation =
      switch (orientation, clockwise) {
      case (.portrait, true): .landscapeRight
      case (.portrait, false): .landscapeLeft
      case (.landscapeLeft, true), (.landscapeRight, false): .portrait
      case (.landscapeLeft, false): .landscapeRight
      case (.landscapeRight, true): .landscapeLeft
      }
    enqueue { client in
      try await client.setOrientation(next.rawValue)
      self.orientation = next
    }
  }

  func screenshot() {
    enqueue { client in
      let png = try await client.screenshotPNG()
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
      let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
      let name = "\(self.selected?.name ?? "iPhone") \(formatter.string(from: Date())).png"
      try png.write(to: desktop.appending(path: name))
      self.view?.flash()
      self.show(toast: "Captura guardada en el Escritorio")
    }
  }

  func open(url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    enqueue { try await $0.open(url: trimmed) }
  }

  func show(toast text: String) {
    toast = text
    toastTask?.cancel()
    toastTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      if !Task.isCancelled { self.toast = nil }
    }
  }
}

extension DeviceSession: DeviceViewDelegate {
  func deviceView(livePointer point: CGPoint, pressed: Bool) {
    let p = toInterface(point)
    let size = orientation == .portrait ? screenSize : CGSize(width: screenSize.height, height: screenSize.width)
    bluetooth.pointer(x: p.x / size.width, y: p.y / size.height, pressed: pressed)
  }

  func deviceView(liveScrollY dy: Int, x dx: Int) {
    bluetooth.scroll(dy: dy, dx: dx)
  }

  func deviceView(didGesture gesture: Gesture) {
    let start: TimeInterval
    let path: [(point: CGPoint, time: TimeInterval)]
    var hold: TimeInterval = 0
    switch gesture {
    case .tap(let p):
      start = 0
      path = [(p, 0)]
    case .hold(let p, let duration):
      start = 0
      path = [(p, 0)]
      hold = duration
    case .drag(let samples):
      start = samples.first?.time ?? 0
      path = samples
    }
    let native = path.map { (point: $0.point, time: $0.time - start) }
    let mapped = native.map { (point: toInterface($0.point), time: $0.time) }
    enqueue { client in
      if self.directInput {
        do {
          return try await client.directTouch(native, hold: hold)
        } catch let error as WDAError where error.message.contains("Unhandled endpoint") {
          self.directInput = false
        }
      }
      switch gesture {
      case .tap: try await client.tap(mapped[0].point)
      case .hold: try await client.touchAndHold(mapped[0].point, duration: hold)
      case .drag: try await client.drag(mapped)
      }
    }
  }

  func deviceView(didPress button: ChromeButton.Action) {
    switch button {
    case .volumeUp: volume(up: true)
    case .volumeDown: volume(up: false)
    case .power: toggleLock()
    case .mute: show(toast: "El interruptor de silencio no se puede mover a distancia.")
    }
  }

  /// Las teclas se juntan unos milisegundos para mandarlas en una sola llamada a WDA.
  func deviceView(didType text: String) {
    let flush = pendingText.isEmpty
    pendingText += text
    guard flush else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      let chunk = self.pendingText
      self.pendingText = ""
      self.enqueue { client in try await self.type(chunk, with: client) }
    }
  }

  func deviceViewDidPaste() {
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    enqueue { client in try await self.type(text, with: client) }
  }

  private func type(_ text: String, with client: WDAClient) async throws {
    if directInput {
      do {
        return try await client.directType(text)
      } catch let error as WDAError where error.message.contains("Unhandled endpoint") {
        directInput = false
      }
    }
    try await client.type(text)
  }
}
