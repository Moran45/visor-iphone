// Dibuja el ícono de la app (1024×1024) en la ruta indicada: swift Scripts/icon.swift salida.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
  let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
  let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
  NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.25, blue: 0.29, alpha: 1), NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)])!
    .draw(in: shape, angle: -90)

  // iPhone: marco claro y pantalla azul, como el lienzo de Device Hub.
  let body = NSRect(x: 352, y: 196, width: 320, height: 632)
  NSColor(white: 0.86, alpha: 1).setFill()
  NSBezierPath(roundedRect: body, xRadius: 64, yRadius: 64).fill()
  let screen = body.insetBy(dx: 18, dy: 18)
  NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.55, blue: 1, alpha: 1), NSColor(srgbRed: 0.33, green: 0.25, blue: 0.95, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: screen, xRadius: 48, yRadius: 48), angle: -60)
  NSColor(white: 0.86, alpha: 1).setFill()
  NSBezierPath(roundedRect: NSRect(x: body.midX - 52, y: screen.maxY - 34, width: 104, height: 30), xRadius: 15, yRadius: 15).fill()
  return true
}

let tiff = image.tiffRepresentation!
let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
