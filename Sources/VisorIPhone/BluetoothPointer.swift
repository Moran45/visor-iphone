import Foundation

/// Toques en vivo: el helper VisorHID presenta la Mac ante el iPhone como un puntero Bluetooth absoluto que
/// el iPhone usa con AssistiveTouch. Cada movimiento del mouse llega al momento, sin pasar por XCTest.
final class BluetoothPointer: @unchecked Sendable {
  enum State: Equatable {
    case off
    case connecting
    case needsPairing
    case ready
    case failed(String)
  }

  /// En el hilo principal.
  var onState: ((State) -> Void)?
  var onLog: ((String) -> Void)?
  private(set) var state = State.off

  private var process: Process?
  private var input: FileHandle?
  private var deviceName = ""
  private var pending = ""
  private var retry: DispatchWorkItem?
  private let queue = DispatchQueue(label: "visor.bluetooth")

  static var helperURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "VisorHID") }

  func start(deviceName: String) {
    stop()
    guard let url = Self.helperURL else {
      set(.failed("Falta el helper VisorHID dentro de la app."))
      return
    }
    self.deviceName = deviceName
    let process = Process()
    process.executableURL = url
    process.arguments = ["--stdio"]
    let toHelper = Pipe()
    let fromHelper = Pipe()
    process.standardInput = toHelper
    process.standardOutput = fromHelper
    process.standardError = FileHandle.nullDevice
    fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.queue.async { self?.consume(String(decoding: data, as: UTF8.self)) }
    }
    process.terminationHandler = { [weak self] proc in
      fromHelper.fileHandleForReading.readabilityHandler = nil
      DispatchQueue.main.async {
        guard let self, self.process === proc else { return }
        self.process = nil
        self.input = nil
        self.set(.failed("El helper Bluetooth se cerró."))
      }
    }
    do {
      try process.run()
    } catch {
      set(.failed(error.localizedDescription))
      return
    }
    self.process = process
    input = toHelper.fileHandleForWriting
    set(.connecting)
    send(["cmd": "start", "name": deviceName])
  }

  /// Al cerrar su entrada, el helper suelta el botón, cierra los canales y retira el servicio HID.
  func stop() {
    retry?.cancel()
    retry = nil
    if let process {
      self.process = nil
      process.terminationHandler = nil
      try? input?.close()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        if process.isRunning { process.terminate() }
      }
    }
    input = nil
    set(.off)
  }

  /// Coordenadas normalizadas (0…1) en la orientación actual de la pantalla del iPhone.
  func pointer(x: Double, y: Double, pressed: Bool) {
    guard state == .ready else { return }
    send([
      "cmd": "pointer",
      "x": Int((min(max(x, 0), 1) * 32767).rounded()),
      "y": Int((min(max(y, 0), 1) * 32767).rounded()),
      "buttons": pressed ? 1 : 0,
    ])
  }

  /// Rueda (vertical) y AC Pan (horizontal) en la posición actual del puntero; cada unidad es un «clic» de rueda.
  func scroll(dy: Int, dx: Int) {
    guard state == .ready, dy != 0 || dx != 0 else { return }
    send(["cmd": "scroll", "dy": max(-127, min(127, dy)), "dx": max(-127, min(127, dx))])
  }

  private func send(_ message: [String: Any]) {
    guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0A)
    try? input.write(contentsOf: data)
  }

  private func set(_ new: State) {
    guard new != state else { return }
    state = new
    onState?(new)
  }

  private func consume(_ chunk: String) {
    pending += chunk
    var lines = pending.components(separatedBy: "\n")
    pending = lines.removeLast()
    for line in lines where !line.isEmpty {
      guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
      DispatchQueue.main.async { self.handle(event, line: line) }
    }
  }

  private func handle(_ event: [String: Any], line: String) {
    guard process != nil else { return }
    let name = event["event"] as? String ?? ""
    if name != "peer_message" { onLog?("[bluetooth] \(line)") }
    switch name {
    case "ready":
      set(.ready)
    case "needs_pairing":
      set(.needsPairing)
    case "error" where state != .ready:
      set(.failed(event["message"] as? String ?? "Error de Bluetooth"))
      scheduleReconnect(after: 10)
    case "channel_closed" where state == .ready:
      // El iPhone se alejó, apagó el Bluetooth o se bloqueó: se reintenta solo.
      set(.connecting)
      scheduleReconnect(after: 2)
    default:
      break
    }
  }

  private func scheduleReconnect(after seconds: Double) {
    retry?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.process != nil, self.state != .ready else { return }
      self.set(.connecting)
      self.send(["cmd": "start", "name": self.deviceName])
    }
    retry = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }
}
