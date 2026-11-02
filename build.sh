#!/bin/bash
# Compila «Visor iPhone.app» con WebDriverAgent adentro.
#
#   ./build.sh             → build/Visor iPhone.app
#   ./build.sh --install   → además lo instala en /Applications (o ~/Applications si no hay permiso)
#
# Firma con el certificado de desarrollo del Personal Team si está en el llavero: con una firma estable,
# macOS recuerda los permisos de cámara y red local entre compilaciones. Si no está, firma ad hoc.
# Para otra identidad: SIGN_IDENTITY="Apple Development: …" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Visor iPhone.app"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

if [[ ! -f vendor/WebDriverAgent/WebDriverAgent.xcodeproj/project.pbxproj ]]; then
  echo "Falta vendor/WebDriverAgent. Descárgalo con:" >&2
  echo "  git clone --depth 1 --branch v16.15.3 https://github.com/appium/WebDriverAgent.git vendor/WebDriverAgent" >&2
  exit 1
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VisorIPhone "$APP/Contents/MacOS/VisorIPhone"
rsync -a --exclude .git --exclude xcuserdata vendor/WebDriverAgent "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift Scripts/icon.swift "$ICONSET/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>VisorIPhone</string>
  <key>CFBundleIdentifier</key><string>com.cmoran.visoriphone</string>
  <key>CFBundleName</key><string>Visor iPhone</string>
  <key>CFBundleDisplayName</key><string>Visor iPhone</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>es</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Para ver y controlar el iPhone, la app se conecta a WebDriverAgent en la red local.</string>
  <key>NSCameraUsageDescription</key><string>Para mostrar la pantalla del iPhone conectado por cable, igual que QuickTime.</string>
  <key>NSMicrophoneUsageDescription</key><string>El video del iPhone por cable incluye su audio; la app no lo graba.</string>
</dict>
</plist>
PLIST

if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -v -p codesigning | grep -q "(Y54J9V4XJ6)"; then
  SIGN_IDENTITY="Y54J9V4XJ6"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Listo: $APP (firma: ${SIGN_IDENTITY:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications
  [[ -w "$DEST" ]] || DEST=~/Applications
  mkdir -p "$DEST"
  # Si está abierta, se cierra antes (al cerrar detiene WebDriverAgent).
  if pgrep -qf "Visor iPhone.app/Contents/MacOS/VisorIPhone"; then
    osascript -e 'quit app "Visor iPhone"' 2>/dev/null || true
    sleep 3
  fi
  rm -rf "$DEST/Visor iPhone.app"
  cp -R "$APP" "$DEST/"
  # Que Spotlight y Launchpad vean la copia instalada y no la de build/.
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  "$LSREGISTER" -f "$DEST/Visor iPhone.app"
  echo "Instalado en $DEST/Visor iPhone.app"
fi
