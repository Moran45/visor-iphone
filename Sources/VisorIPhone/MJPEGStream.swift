import CoreGraphics
import Foundation
import ImageIO
import Network

/// Lee el stream MJPEG de WebDriverAgent (puerto 9100) y entrega solo el cuadro más reciente.
/// Cada parte llega como «--BoundaryString / Content-Length: N / \r\n\r\n / <jpeg>».
final class MJPEGStream: @unchecked Sendable {
  var onFrame: ((CGImage) -> Void)?
  var onDisconnect: (() -> Void)?

  private let queue = DispatchQueue(label: "visor.mjpeg")
  private let decodeQueue = DispatchQueue(label: "visor.mjpeg.decode", qos: .userInteractive)
  private var connection: NWConnection?
  private var buffer = Data()
  private var headerSkipped = false
  private var decoding = false
  private var stopped = true
  private var endpoint: (host: String, port: UInt16)?

  private static let headerEnd = Data("\r\n\r\n".utf8)
  private static let lengthKey = Data("Content-Length:".utf8)

  func start(host: String, port: UInt16) {
    queue.async {
      self.stopped = false
      self.endpoint = (host, port)
      self.connect()
    }
  }

  func stop() {
    queue.async {
      self.stopped = true
      self.connection?.cancel()
      self.connection = nil
    }
  }

  private func connect() {
    guard !stopped, let endpoint, let port = NWEndpoint.Port(rawValue: endpoint.port) else { return }
    buffer.removeAll(keepingCapacity: true)
    headerSkipped = false
    let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
    self.connection = connection
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        connection.send(content: Data("GET / HTTP/1.0\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        self.receive(on: connection)
      case .failed, .cancelled:
        self.retry(after: connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func retry(after old: NWConnection) {
    guard connection === old else { return }
    connection = nil
    guard !stopped else { return }
    DispatchQueue.main.async { self.onDisconnect?() }
    queue.asyncAfter(deadline: .now() + 0.7) { self.connect() }
  }

  private func receive(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self, self.connection === connection else { return }
      if let data, !data.isEmpty {
        self.buffer.append(data)
        self.parse()
      }
      if isComplete || error != nil {
        connection.cancel()
      } else {
        self.receive(on: connection)
      }
    }
  }

  private func parse() {
    if !headerSkipped {
      // Respuesta HTTP: se descarta hasta la línea en blanco.
      guard let end = buffer.range(of: Self.headerEnd) else { return }
      buffer = Data(buffer[end.upperBound...])
      headerSkipped = true
    }
    var latest: Data?
    while let key = buffer.range(of: Self.lengthKey),
      let end = buffer.range(of: Self.headerEnd, in: key.upperBound..<buffer.endIndex)
    {
      let digits = String(decoding: buffer[key.upperBound..<end.lowerBound], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let length = Int(digits) else {
        buffer = Data(buffer[end.upperBound...])
        continue
      }
      guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { break }
      let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
      latest = Data(buffer[end.upperBound..<bodyEnd])
      buffer = Data(buffer[bodyEnd...])
    }
    if let latest { decode(latest) }
  }

  private func decode(_ jpeg: Data) {
    // Si el cuadro anterior sigue decodificándose, este se descarta: nunca se acumula retraso.
    guard !decoding else { return }
    decoding = true
    decodeQueue.async {
      let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      let image = CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
      self.queue.async { self.decoding = false }
      if let image {
        DispatchQueue.main.async { self.onFrame?(image) }
      }
    }
  }
}
