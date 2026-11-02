# Visor iPhone

App nativa de macOS para ver y controlar un iPhone físico desde la Mac **con la cámara funcionando**.
Device Hub (Xcode 27) bloquea la cámara y el micrófono mientras muestra la pantalla; esta app no.

Tiene el aspecto de Device Hub: barra lateral de dispositivos, el bezel real del modelo (recursos de
DeviceKit de Xcode) y la cápsula flotante con Inicio, captura y rotar.

## Cómo funciona

| Qué | Por dónde |
|---|---|
| Video por cable | El mismo canal que QuickTime («Nueva grabación de película»): 60 fps, poco retraso. |
| Video por Wi-Fi | El stream MJPEG de WebDriverAgent (unos 10 fps). Solo si no hay cable. |
| Toques, gestos, teclado y botones | WebDriverAgent (XCTest), firmado con tu Personal Team. |

Por cable el video aparece en segundos y los toques se activan cuando WebDriverAgent termina de arrancar.

## Requisitos

- Xcode 27 con tu Apple ID en **Xcode › Settings › Apple Accounts** (basta el Personal Team).
- iPhone con el Modo de desarrollador activado y emparejado con la Mac.
- La primera vez, en el iPhone: **Ajustes › General › VPN y gestión de dispositivos › App de desarrollador › Confiar**.
- El iPhone desbloqueado mientras arranca WebDriverAgent.

## Compilar

```bash
./build.sh
```

`./build.sh --install` además la instala en `/Applications` (queda en Launchpad y Spotlight). Todo se compila en
Release: la app con `swift build -c release` y WebDriverAgent con `-configuration Release`. Se firma con el
certificado del Personal Team si está en el llavero, para que macOS recuerde los permisos entre compilaciones.
Si falta `vendor/WebDriverAgent`, el script dice cómo descargarlo.

Al abrirla, macOS pide permiso de **cámara** (para el video por cable, igual que QuickTime) y de **red local**
(para hablar con WebDriverAgent). El equipo de firma y el bundle ID del runner se cambian en Ajustes (icono de controles).

## Uso

- Clic = toque; mantener = toque largo; arrastrar = deslizar; trackpad o rueda = scroll.
- Con el botón de teclado activo, lo que escribes va al iPhone; ⌘V pega el portapapeles de la Mac.
- Los botones del bezel (volumen y lateral) se pueden pulsar.

| Atajo | Acción |
|---|---|
| ⇧⌘H | Inicio |
| ⌘S | Captura de pantalla (al Escritorio) |
| ⌘L | Bloquear o desbloquear |
| ⌘← / ⌘→ | Rotar |
| ⌘↑ / ⌘↓ | Volumen |
| ⌘K | Enviar teclado al iPhone |
| ⇧⌘B | Mostrar u ocultar el bezel |
| ⌘R / ⌘. | Reiniciar / detener WebDriverAgent |

## Seguridad

Mientras la app muestra el iPhone, WebDriverAgent escucha **sin contraseña** en la IP del iPhone (puertos 8100 y 9100):
cualquiera en la misma red podría controlarlo. Al cerrar la app se detiene. Úsala en redes de confianza.

## Parche en WebDriverAgent

`vendor/WebDriverAgent/WebDriverAgentLib/Commands/FBTouchActionCommands.m` agrega `POST /wda/visor/touch` y
`POST /wda/visor/type`: mandan el evento directo a XCTest sin consultar antes la jerarquía de accesibilidad
(WDA lo hace 3 o 4 veces por gesto). Bajan cada toque de ~0,6 s a ~0,35 s. Si se actualiza WDA, hay que reaplicarlo;
sin el parche la app usa los comandos normales.

## Límites

- Cada toque tarda ~0,35 s: es lo mínimo de XCTest, que genera los eventos uno por uno.
- Si el iPhone se bloquea solo, la app avisa y ofrece desbloquearlo. Para que no pase, pon
  **Ajustes › Pantalla y brillo › Bloqueo automático › Nunca** mientras desarrollas.
- La firma con Personal Team dura 7 días; la app la renueva sola al arrancar.
- La rotación es experimental.

Registro de la última sesión: `~/Library/Logs/Visor iPhone.log` (también en el botón de registro).
