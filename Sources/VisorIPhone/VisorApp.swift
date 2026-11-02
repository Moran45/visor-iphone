import AppKit
import SwiftUI

@main
struct VisorIPhoneApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var session = DeviceSession()

  var body: some Scene {
    Window("Visor iPhone", id: "main") {
      ContentView(session: session)
        .frame(minWidth: 340, minHeight: 520)
        .onAppear { appDelegate.session = session }
    }
    .defaultSize(width: 470, height: 920)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Dispositivo") {
        Button("Inicio") { session.home() }
          .keyboardShortcut("h", modifiers: [.command, .shift])
        Button("Captura de pantalla") { session.screenshot() }
          .keyboardShortcut("s")
        Button("Bloquear o desbloquear") { session.toggleLock() }
          .keyboardShortcut("l")
        Divider()
        Button("Rotar a la izquierda") { session.rotate(clockwise: false) }
          .keyboardShortcut(.leftArrow)
        Button("Rotar a la derecha") { session.rotate(clockwise: true) }
          .keyboardShortcut(.rightArrow)
        Button("Subir volumen") { session.volume(up: true) }
          .keyboardShortcut(.upArrow)
        Button("Bajar volumen") { session.volume(up: false) }
          .keyboardShortcut(.downArrow)
        Divider()
        Toggle("Enviar teclado al iPhone", isOn: $session.keyboardEnabled)
          .keyboardShortcut("k")
        Toggle("Mostrar bezel", isOn: $session.showBezel)
          .keyboardShortcut("b", modifiers: [.command, .shift])
        Divider()
        Button(session.isRunning ? "Reiniciar WebDriverAgent" : "Ver pantalla") { session.start() }
          .keyboardShortcut("r")
        Button("Detener") { session.shutdown() }
          .keyboardShortcut(".")
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var session: DeviceSession?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Si el helper Bluetooth muere, escribirle no debe tumbar la app.
    signal(SIGPIPE, SIG_IGN)
    // Necesario cuando se corre con `swift run` fuera del .app.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { session?.shutdown() }
  }
}
