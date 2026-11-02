import SwiftUI

/// Ventana con la estructura de Device Hub: barra lateral de dispositivos, lienzo con el iPhone
/// y controles flotantes abajo.
struct ContentView: View {
  @Bindable var session: DeviceSession
  @State private var columns: NavigationSplitViewVisibility = .detailOnly
  @State private var showSettings = false
  @State private var showInfo = false
  @State private var showLog = false
  @State private var askURL = false
  @State private var urlText = ""

  var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      DeviceSidebar(session: session)
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
    } detail: {
      CanvasArea(session: session, showLog: $showLog)
        .navigationTitle(session.selected?.name ?? "Visor iPhone")
        .navigationSubtitle(session.selected.map { "iOS \($0.osVersion)" } ?? "")
        .toolbar { toolbar }
    }
    .task { await session.bootstrap() }
    .sheet(isPresented: $showLog) { LogView(lines: session.log) }
    .alert("Abrir URL en el iPhone", isPresented: $askURL) {
      TextField("https://… o miapp://ruta", text: $urlText)
      Button("Abrir") { session.open(url: urlText) }
      Button("Cancelar", role: .cancel) {}
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      Toggle(isOn: $session.keyboardEnabled) {
        Label("Teclado", systemImage: "keyboard")
      }
      .help("Enviar el teclado de la Mac al iPhone")
      Toggle(isOn: $session.showBezel) {
        Label("Bezel", systemImage: "iphone")
      }
      .help("Mostrar el marco del dispositivo")
    }
    ToolbarSpacer(.flexible)
    ToolbarItem {
      Menu {
        Button("Bloquear o desbloquear", systemImage: "lock") { session.toggleLock() }
        Button("Subir volumen", systemImage: "speaker.plus") { session.volume(up: true) }
        Button("Bajar volumen", systemImage: "speaker.minus") { session.volume(up: false) }
        Divider()
        Button("Rotar a la izquierda", systemImage: "rotate.left") { session.rotate(clockwise: false) }
        Button("Rotar a la derecha", systemImage: "rotate.right") { session.rotate(clockwise: true) }
        Divider()
        Button("Abrir URL…", systemImage: "link") { askURL = true }
        Divider()
        Button("Reiniciar WebDriverAgent", systemImage: "arrow.clockwise") { session.start() }
        Button("Detener", systemImage: "stop") { session.shutdown() }
      } label: {
        Label("Más", systemImage: "chevron.forward.2")
      }
      .menuIndicator(.hidden)
      .help("Más controles")
    }
    ToolbarSpacer(.fixed)
    ToolbarItemGroup {
      Button { showSettings.toggle() } label: { Label("Ajustes", systemImage: "slider.horizontal.3") }
        .help("Ajustes del video y de la firma")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPanel(session: session) }
      Button { showLog = true } label: { Label("Registro", systemImage: "doc.text") }
        .help("Registro de WebDriverAgent")
      Button { showInfo.toggle() } label: { Label("Información", systemImage: "info") }
        .help("Información del dispositivo")
        .popover(isPresented: $showInfo, arrowEdge: .bottom) { InfoPanel(session: session) }
    }
  }
}

private struct CanvasArea: View {
  let session: DeviceSession
  @Binding var showLog: Bool

  var body: some View {
    ZStack {
      Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
      DeviceCanvas(session: session)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 78)
      if !session.hasFrame {
        StatusOverlay(session: session, showLog: $showLog)
          .padding(.bottom, 64)
      }
      VStack(spacing: 10) {
        Spacer()
        if session.hasFrame {
          TouchStatus(session: session)
        }
        if let toast = session.toast {
          Text(toast)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        BottomControls(session: session)
      }
      .padding(.bottom, 16)
    }
    .animation(.smooth(duration: 0.25), value: session.toast)
  }
}

/// Mensajes sobre la pantalla negra del iPhone mientras no hay video.
private struct StatusOverlay: View {
  let session: DeviceSession
  @Binding var showLog: Bool

  var body: some View {
    Group {
      switch session.phase {
      case .starting(let message):
        VStack(spacing: 12) {
          ProgressView()
          Text(message)
          Button("Cancelar") { session.shutdown() }
            .buttonStyle(.glass)
        }
      case .failed(let message):
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.title2)
            .foregroundStyle(.yellow)
          Text(message)
          HStack {
            Button("Reintentar") { session.start() }
              .buttonStyle(.glassProminent)
            Button("Ver registro") { showLog = true }
              .buttonStyle(.glass)
          }
        }
      case .idle:
        VStack(spacing: 12) {
          Text(session.selected == nil ? "Conecta un iPhone para ver su pantalla." : "La pantalla no se está mostrando.")
          if session.selected != nil {
            Button("Ver pantalla") { session.start() }
              .buttonStyle(.glassProminent)
          }
        }
      case .running:
        if !session.hasFrame {
          VStack(spacing: 12) {
            ProgressView()
            Text("Esperando video…")
          }
        }
      }
    }
    .font(.callout)
    .multilineTextAlignment(.center)
    .foregroundStyle(.white)
    .frame(maxWidth: 230)
    .environment(\.colorScheme, .dark)
  }
}

/// Con video por cable la pantalla ya se ve mientras WDA arranca: el estado de los toques va en una cápsula.
private struct TouchStatus: View {
  let session: DeviceSession

  var body: some View {
    switch session.phase {
    case .starting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Preparando los toques…")
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .glassEffect(.regular, in: .capsule)
    case .failed(let message):
      HStack(spacing: 8) {
        Image(systemName: "hand.tap").foregroundStyle(.yellow)
        Text("Toques no disponibles").help(message)
        Button("Reintentar") { session.start() }
          .buttonStyle(.borderless)
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .glassEffect(.regular, in: .capsule)
    case .running where session.bluetoothState == .needsPairing:
      HStack(spacing: 8) {
        Image(systemName: "dot.radiowaves.left.and.right")
        Text("Toques en vivo: en el iPhone, Ajustes › Bluetooth › «\(Host.current().localizedName ?? "esta Mac")»")
          .lineLimit(2)
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .frame(maxWidth: 360)
      .glassEffect(.regular, in: .capsule)
    case .running where session.isLocked:
      HStack(spacing: 8) {
        Image(systemName: "lock.fill")
        Text("iPhone bloqueado")
        Button("Desbloquear") { session.unlock() }
          .buttonStyle(.borderless)
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .glassEffect(.regular, in: .capsule)
    case .idle, .running:
      EmptyView()
    }
  }
}

/// Cápsula flotante de Device Hub: Inicio, captura y rotar.
private struct BottomControls: View {
  let session: DeviceSession

  var body: some View {
    HStack(spacing: 2) {
      control("circle.grid.3x3.fill", "Inicio (⇧⌘H)") { session.home() }
      control("camera.viewfinder", "Captura de pantalla (⌘S)") { session.screenshot() }
      control("rotate.right", "Rotar (⌘→)") { session.rotate(clockwise: true) }
    }
    .padding(5)
    .glassEffect(.regular, in: .capsule)
    .disabled(!session.isRunning)
  }

  private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .frame(width: 36, height: 30)
        .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .help(help)
  }
}

private struct DeviceSidebar: View {
  @Bindable var session: DeviceSession

  var body: some View {
    List(selection: $session.selectedID) {
      Section("Dispositivos físicos") {
        ForEach(session.devices) { device in
          DeviceRow(device: device, live: device.id == session.selectedID && session.isRunning)
            .tag(device.id)
        }
      }
    }
    .overlay {
      if session.devices.isEmpty {
        ContentUnavailableView("Sin iPhones", systemImage: "iphone.slash", description: Text("Conecta un iPhone con el Modo de desarrollador activado."))
      }
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button { Task { await session.refreshDevices() } } label: {
          Label("Buscar dispositivos", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .help("Buscar dispositivos")
        Spacer()
      }
      .padding(10)
    }
  }
}

private struct DeviceRow: View {
  let device: PhysicalDevice
  let live: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "iphone")
        .font(.title3)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(device.name)
        Text("\(device.model) · iOS \(device.osVersion)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      if live {
        Circle().fill(.green).frame(width: 7, height: 7).help("Mostrando pantalla")
      } else {
        Text(device.connectionLabel)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 3)
    .opacity(device.available ? 1 : 0.5)
  }
}

private struct SettingsPanel: View {
  @Bindable var session: DeviceSession

  var body: some View {
    Form {
      Section {
        slider("Fluidez", value: $session.framerate, range: 5...60, unit: "fps")
        slider("Resolución", value: $session.resolution, range: 25...100, unit: "%")
        slider("Calidad", value: $session.quality, range: 10...100, unit: "%")
      } header: {
        Text("Video por la red")
      } footer: {
        Text("Solo cuando el iPhone no está conectado por cable. Por cable el video va a 60 fps, como en QuickTime.")
      }
      Section {
        Toggle("Toques en vivo por Bluetooth", isOn: $session.bluetoothEnabled)
        Toggle("El puntero sigue al mouse", isOn: $session.bluetoothHover)
          .disabled(!session.bluetoothEnabled)
      } header: {
        Text("Toques")
      } footer: {
        Text("La Mac se presenta como un puntero Bluetooth: tocar, arrastrar y hacer scroll llegan al momento. Requiere AssistiveTouch activado y el iPhone emparejado con esta Mac. Si no está disponible, se usa WebDriverAgent. Con «sigue al mouse», iOS resalta cada elemento al pasar por encima.")
      }
      Section {
        TextField("Equipo de desarrollo", text: $session.team)
        TextField("Bundle ID del runner", text: $session.bundleID)
      } header: {
        Text("Firma de WebDriverAgent")
      } footer: {
        Text("Se aplica al reiniciar WebDriverAgent. Con un Personal Team la firma dura 7 días y se renueva sola al arrancar.")
      }
    }
    .formStyle(.grouped)
    .frame(width: 360)
  }

  private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
    LabeledContent(title) {
      HStack {
        Slider(value: value, in: range, step: 5) { editing in
          if !editing { session.applyStreamSettings() }
        }
        Text("\(Int(value.wrappedValue)) \(unit)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 52, alignment: .trailing)
      }
    }
  }
}

private struct InfoPanel: View {
  let session: DeviceSession

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
        if let d = session.selected {
          row("Dispositivo", d.name)
          row("Modelo", "\(d.model) (\(d.productType))")
          row("iOS", d.osVersion)
          row("Conexión", d.connectionLabel)
          row("UDID", d.id)
        }
        row("WebDriverAgent", session.wdaURL?.absoluteString ?? "Detenido")
        row("Toques", touchLabel)
        row("Video", session.hasFrame ? "\(session.videoSource.rawValue) · \(Int(session.frameSize.width))×\(Int(session.frameSize.height)) · \(session.fps) fps" : session.videoSource.rawValue)
      }
      Text("Mientras se ve la pantalla, WebDriverAgent escucha sin contraseña en la red del iPhone. Al cerrar la app se detiene.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 380)
    .textSelection(.enabled)
  }

  private var touchLabel: String {
    switch session.bluetoothState {
    case .ready: "Bluetooth en vivo (AssistiveTouch)"
    case .connecting: "Conectando puntero Bluetooth…"
    case .needsPairing: "Falta emparejar el iPhone con esta Mac"
    case .failed(let message): "WebDriverAgent · Bluetooth: \(message)"
    case .off: "WebDriverAgent"
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).lineLimit(1).truncationMode(.middle)
    }
  }
}

private struct LogView: View {
  let lines: [String]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        Text(lines.suffix(800).joined(separator: "\n"))
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .defaultScrollAnchor(.bottom)
      Divider()
      HStack {
        Text("\(lines.count) líneas").foregroundStyle(.secondary)
        Spacer()
        Button("Copiar todo") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
        Button("Cerrar") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(width: 720, height: 460)
  }
}
