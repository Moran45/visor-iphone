import Foundation

struct WDAError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Cliente HTTP mínimo de WebDriverAgent. Las coordenadas van en puntos de la orientación actual.
final class WDAClient: @unchecked Sendable {
  let base: URL
  private var sessionID: String?
  private let http: URLSession

  init(base: URL) {
    self.base = base
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    http = URLSession(configuration: config)
  }

  @discardableResult
  func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 60) async throws -> Any? {
    var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await http.data(for: request)
    let value = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["value"]
    if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
      let message = (value as? [String: Any])?["message"] as? String
      throw WDAError(message: message ?? "WebDriverAgent respondió \(status).")
    }
    return value
  }

  func waitUntilReady(attempts: Int = 40) async throws {
    var lastError: Error?
    for _ in 0..<attempts {
      do {
        if let value = try await call("GET", "status", timeout: 3) as? [String: Any], value["ready"] as? Bool == true { return }
      } catch {
        lastError = error
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    let reason = lastError.map { " (\($0.localizedDescription))" } ?? ""
    throw WDAError(message: "WebDriverAgent arrancó pero no responde en \(base.absoluteString)\(reason). Si macOS pidió acceso a la red local, acéptalo y reintenta.")
  }

  func startSession() async throws {
    // Sin bundleId: la sesión se pega a la app que esté al frente.
    let caps: [String: Any] = ["shouldWaitForQuiescence": false, "waitForIdleTimeout": 0, "shouldUseCompactResponses": true]
    let value = try await call("POST", "session", ["capabilities": ["alwaysMatch": caps]])
    sessionID = (value as? [String: Any])?["sessionId"] as? String
    if sessionID == nil { throw WDAError(message: "WebDriverAgent no devolvió una sesión.") }
  }

  /// Comandos que necesitan sesión; si la sesión murió (p. ej. se cerró la app), se recrea una vez.
  @discardableResult
  func sessionCall(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Any? {
    if sessionID == nil { try await startSession() }
    do {
      return try await call(method, "session/\(sessionID!)/\(path)", body)
    } catch let error as WDAError where error.message.localizedCaseInsensitiveContains("session") {
      try await startSession()
      return try await call(method, "session/\(sessionID!)/\(path)", body)
    }
  }

  func applySettings(_ settings: [String: Any]) async throws {
    try await sessionCall("POST", "appium/settings", ["settings": settings])
  }

  func windowSize() async throws -> CGSize {
    let value = try await call("GET", "window/size") as? [String: Any]
    let w = value?["width"] as? Double ?? 0
    let h = value?["height"] as? Double ?? 0
    return CGSize(width: w, height: h)
  }

  /// Toque, toque largo o arrastre con el comando directo que el Visor agrega a WDA (vendor/…/FBTouchActionCommands.m).
  /// Puntos en la vertical nativa de la pantalla y tiempos en segundos desde el primer contacto.
  func directTouch(_ path: [(point: CGPoint, time: TimeInterval)], hold: TimeInterval = 0) async throws {
    let points = path.map { [$0.point.x, $0.point.y, $0.time] }
    try await call("POST", "wda/visor/touch", ["points": points, "hold": hold])
  }

  func directType(_ text: String) async throws {
    try await call("POST", "wda/visor/type", ["text": text])
  }

  func isLocked() async throws -> Bool {
    try await call("GET", "wda/locked", timeout: 5) as? Bool ?? false
  }

  func unlock() async throws { try await call("POST", "wda/unlock") }

  func tap(_ p: CGPoint) async throws {
    try await sessionCall("POST", "wda/tap", ["x": p.x, "y": p.y])
  }

  func touchAndHold(_ p: CGPoint, duration: TimeInterval) async throws {
    try await sessionCall("POST", "wda/touchAndHold", ["x": p.x, "y": p.y, "duration": duration])
  }

  /// Arrastre que sigue el trazo y la velocidad del mouse (acciones W3C).
  func drag(_ path: [(point: CGPoint, time: TimeInterval)]) async throws {
    guard let first = path.first else { return }
    var actions: [[String: Any]] = [
      ["type": "pointerMove", "duration": 0, "x": first.point.x, "y": first.point.y],
      ["type": "pointerDown", "button": 0],
    ]
    var previous = first.time
    for sample in path.dropFirst() {
      let ms = max(10, Int((sample.time - previous) * 1000))
      actions.append(["type": "pointerMove", "duration": ms, "x": sample.point.x, "y": sample.point.y])
      previous = sample.time
    }
    actions.append(["type": "pointerUp", "button": 0])
    let finger: [String: Any] = ["type": "pointer", "id": "dedo", "parameters": ["pointerType": "touch"], "actions": actions]
    try await sessionCall("POST", "actions", ["actions": [finger]])
  }

  func type(_ text: String) async throws {
    try await sessionCall("POST", "wda/keys", ["value": [text]])
  }

  func pressButton(_ name: String) async throws {
    try await sessionCall("POST", "wda/pressButton", ["name": name])
  }

  func home() async throws { try await call("POST", "wda/homescreen") }

  func toggleLock() async throws {
    let locked = try await call("GET", "wda/locked") as? Bool ?? false
    try await call("POST", locked ? "wda/unlock" : "wda/lock")
  }

  func screenshotPNG() async throws -> Data {
    guard let base64 = try await call("GET", "screenshot") as? String, let data = Data(base64Encoded: base64) else {
      throw WDAError(message: "No se pudo leer la captura.")
    }
    return data
  }

  func setOrientation(_ name: String) async throws {
    try await call("POST", "orientation", ["orientation": name])
  }

  func open(url: String) async throws {
    try await sessionCall("POST", "url", ["url": url])
  }
}

/// Lanza WebDriverAgent en el iPhone con `xcodebuild test` y lo mantiene vivo mientras corre el proceso.
final class WDARunner: @unchecked Sendable {
  struct Config {
    let udid: String
    let team: String
    let bundleID: String
  }

  var onLog: ((String) -> Void)?
  var onReady: ((URL) -> Void)?
  var onExit: ((String) -> Void)?

  private var process: Process?
  private var pending = ""
  private var ready = false
  private var hint: String?
  private let queue = DispatchQueue(label: "visor.wda.log")

  static let derivedData: URL = {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appending(path: "com.cmoran.visoriphone/DerivedData")
  }()

  var isRunning: Bool { process?.isRunning == true }

  func start(_ config: Config) throws {
    stop()
    let project = try Self.projectURL()
    // Si una ejecución anterior quedó huérfana (la app se cerró de golpe), se detiene antes.
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-f", Self.derivedData.path]
    try? pkill.run()
    pkill.waitUntilExit()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xcodebuild", "test",
      "-project", project.appending(path: "WebDriverAgent.xcodeproj").path,
      "-scheme", "WebDriverAgentRunner",
      "-destination", "id=\(config.udid)",
      "-derivedDataPath", Self.derivedData.path,
      // Release: WDA optimizado y sin código de depuración; responde más rápido que la compilación Debug de `test`.
      "-configuration", "Release",
      "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
      "DEVELOPMENT_TEAM=\(config.team)", "CODE_SIGN_STYLE=Automatic",
      "PRODUCT_BUNDLE_IDENTIFIER=\(config.bundleID)",
      "USE_PORT=8100", "MJPEG_SERVER_PORT=9100",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.queue.async { self?.consume(String(decoding: data, as: UTF8.self)) }
    }
    process.terminationHandler = { [weak self] proc in
      pipe.fileHandleForReading.readabilityHandler = nil
      self?.queue.async {
        guard let self, self.process === proc else { return }
        self.process = nil
        let message =
          self.ready
          ? "WebDriverAgent se detuvo."
          : self.hint ?? "WebDriverAgent no arrancó (xcodebuild salió con código \(proc.terminationStatus)). Revisa el registro."
        DispatchQueue.main.async { self.onExit?(message) }
      }
    }
    ready = false
    hint = nil
    pending = ""
    self.process = process
    try process.run()
  }

  func stop() {
    guard let process else { return }
    self.process = nil
    process.terminationHandler = nil
    if process.isRunning {
      process.terminate()
      // xcodebuild cancela la prueba y el runner se cierra en el iPhone; se espera poco para no trabar la salida.
      let deadline = Date().addingTimeInterval(3)
      while process.isRunning && Date() < deadline { usleep(50_000) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }

  private func consume(_ chunk: String) {
    pending += chunk
    var lines = pending.components(separatedBy: "\n")
    pending = lines.removeLast()
    for line in lines where !line.isEmpty {
      DispatchQueue.main.async { self.onLog?(line) }
      if hint == nil { hint = Self.hint(for: line) }
      if !ready, let range = line.range(of: #"ServerURLHere->(.+)<-ServerURLHere"#, options: .regularExpression) {
        let raw = line[range].replacingOccurrences(of: "ServerURLHere->", with: "").replacingOccurrences(of: "<-ServerURLHere", with: "")
        if let url = URL(string: raw) {
          ready = true
          DispatchQueue.main.async { self.onReady?(url) }
        }
      }
    }
  }

  /// Errores conocidos de xcodebuild, traducidos a lo que hay que hacer.
  private static func hint(for line: String) -> String? {
    if line.contains("Developer App Certificate is not trusted") || line.contains("profile has not been explicitly trusted") {
      return "El iPhone no confía en el certificado. Ve a Ajustes › General › VPN y gestión de dispositivos y confía en la app de desarrollador."
    }
    if line.localizedCaseInsensitiveContains("device is locked") || line.contains("Unlock") && line.contains("to Continue") {
      return "Desbloquea el iPhone y vuelve a intentarlo."
    }
    if line.contains("No Account for Team") || line.contains("No signing certificate") || line.contains("requires a development team") {
      return "Xcode no pudo firmar WebDriverAgent con el equipo configurado. Revisa el equipo en Ajustes y que la cuenta esté en Xcode › Settings › Apple Accounts."
    }
    if line.contains("Developer Mode") && line.contains("disabled") {
      return "Activa el Modo de desarrollador en el iPhone (Ajustes › Privacidad y seguridad)."
    }
    return nil
  }

  /// WebDriverAgent viaja dentro del .app; se copia a Application Support porque xcodebuild escribe junto al proyecto.
  static func projectURL() throws -> URL {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["VISOR_WDA_PROJECT"] {
      return URL(fileURLWithPath: override)
    }
    if let bundled = Bundle.main.resourceURL?.appending(path: "WebDriverAgent"), fm.fileExists(atPath: bundled.path) {
      let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "VisorIPhone")
      let target = support.appending(path: "WebDriverAgent")
      let stamp = target.appending(path: ".version")
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
      if (try? String(contentsOf: stamp, encoding: .utf8)) != version {
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.copyItem(at: bundled, to: target)
        try version.write(to: stamp, atomically: true, encoding: .utf8)
      }
      return target
    }
    // Ejecución de desarrollo (swift run): busca vendor/WebDriverAgent subiendo desde el ejecutable.
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<6 {
      let candidate = dir.appending(path: "vendor/WebDriverAgent")
      if fm.fileExists(atPath: candidate.appending(path: "WebDriverAgent.xcodeproj").path) { return candidate }
      dir.deleteLastPathComponent()
    }
    throw WDAError(message: "No encontré WebDriverAgent. Recompila la app con build.sh.")
  }
}
