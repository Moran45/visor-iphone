import AVFoundation
import CoreMediaIO

/// Video de la pantalla del iPhone por cable: el mismo canal que usa QuickTime («Nueva grabación de película»).
/// Va a 60 fps con poco retraso y no depende de WebDriverAgent ni de Device Hub.
final class USBScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let previewLayer: AVCaptureVideoPreviewLayer
  /// Primer cuadro y cambios de tamaño (la app del iPhone giró), en el hilo principal.
  var onSize: ((CGSize) -> Void)?

  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "visor.usb")
  private var size = CGSize.zero
  private let lock = NSLock()
  private var frames = 0
  private(set) var deviceID: String?

  override init() {
    previewLayer = AVCaptureVideoPreviewLayer(session: session)
    previewLayer.videoGravity = .resize
    super.init()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
  }

  /// macOS solo publica los iPhone conectados por cable como fuentes de video si una app lo pide.
  static func enableDevices() {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
  }

  /// La pantalla del iPhone aparece como dispositivo «muxed» (video y audio); la Cámara de Continuidad no.
  static func device(udid: String, name: String) -> AVCaptureDevice? {
    let compact = udid.replacingOccurrences(of: "-", with: "")
    let screens = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    return screens.first { device in [udid, compact].contains { device.uniqueID.caseInsensitiveCompare($0) == .orderedSame } }
      ?? screens.first { $0.localizedName == name }
  }

  var isRunning: Bool { deviceID != nil }

  func start(_ device: AVCaptureDevice) throws {
    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()
    session.inputs.forEach(session.removeInput)
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw WDAError(message: "No se pudo abrir el video del iPhone por cable.")
    }
    session.addInput(input)
    if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    deviceID = device.uniqueID
    size = .zero
    queue.async { self.session.startRunning() }
  }

  func stop() {
    deviceID = nil
    queue.async {
      self.session.stopRunning()
      self.session.inputs.forEach(self.session.removeInput)
    }
  }

  /// Cuadros recibidos desde la última llamada (para el contador de fps).
  func takeFrameCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    let n = frames
    frames = 0
    return n
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    lock.lock()
    frames += 1
    lock.unlock()
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let d = CMVideoFormatDescriptionGetDimensions(format)
    let current = CGSize(width: Int(d.width), height: Int(d.height))
    if current != size {
      size = current
      DispatchQueue.main.async { self.onSize?(current) }
    }
  }
}
