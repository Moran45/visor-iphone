import Foundation

/// iPhone físico que conoce CoreDevice (`xcrun devicectl list devices`).
struct PhysicalDevice: Identifiable, Hashable {
  let id: String  // UDID
  let name: String
  let model: String  // «iPhone 12»
  let productType: String  // «iPhone13,2»
  let osVersion: String
  let wireless: Bool
  let available: Bool

  var connectionLabel: String { available ? (wireless ? "Wi-Fi" : "USB") : "Sin conexión" }
}

enum DeviceList {
  static func load() async -> [PhysicalDevice] {
    let out = FileManager.default.temporaryDirectory.appending(path: "visor-iphone-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: out) }
    guard (try? await Shell.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "-q", "--json-output", out.path])) != nil,
      let data = try? Data(contentsOf: out),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let devices = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]]
    else { return [] }

    return devices.compactMap { d in
      let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
      let props = d["deviceProperties"] as? [String: Any] ?? [:]
      let conn = d["connectionProperties"] as? [String: Any] ?? [:]
      guard hw["reality"] as? String == "physical", hw["platform"] as? String == "iOS",
        let udid = hw["udid"] as? String
      else { return nil }
      let transport = conn["transportType"] as? String
      return PhysicalDevice(
        id: udid,
        name: props["name"] as? String ?? "iPhone",
        model: hw["marketingName"] as? String ?? "iPhone",
        productType: hw["productType"] as? String ?? "",
        osVersion: props["osVersionNumber"] as? String ?? "",
        wireless: transport == "localNetwork",
        available: transport != nil && conn["pairingState"] as? String == "paired"
      )
    }
    .sorted { ($0.available ? 0 : 1, $0.name) < ($1.available ? 0 : 1, $1.name) }
  }
}

struct ShellError: LocalizedError {
  let output: String
  var errorDescription: String? { output }
}

enum Shell {
  /// Corre un comando y devuelve su salida; falla si el código de salida no es 0.
  @discardableResult
  static func run(_ executable: String, _ args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = args
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.terminationHandler = { proc in
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if proc.terminationStatus == 0 {
          cont.resume(returning: text)
        } else {
          cont.resume(throwing: ShellError(output: text))
        }
      }
      do {
        try process.run()
      } catch {
        cont.resume(throwing: error)
      }
    }
  }
}
