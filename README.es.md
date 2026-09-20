<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="Icono de Claude AutoSwitch">
</p>
<h1 align="center">Claude AutoSwitch</h1>
<p align="center">
  Varias suscripciones a Claude, un solo Claude Code. Una app de barra de menús que rota tus cuentas<br>
  automáticamente a medida que se llenan sus límites y muestra la cuota de cada cuenta de un vistazo.
</p>
<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Sin Node, sin CLI que instalar" src="https://img.shields.io/badge/runtime-none%20needed-2ea44f">
  <img alt="7 idiomas" src="https://img.shields.io/badge/languages-7-3b82f6">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>
<p align="center" data-readme-switcher>
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · Español · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/assets/menubar/menubar-item.png" width="440" alt="El elemento de la barra de menús: 3h18m 33% junto a los elementos del sistema">
</p>
<p align="center">
  <img src="docs/assets/menubar/popover-dark.png" width="406" alt="El panel emergente: tabla de cuentas, barras de todas las cuentas, enrutamiento, sesiones y el registro de rotación">
</p>

## El problema

**Un solo plan Max de $200 ya no basta, así que pagas dos o tres.**<br>
Así es como se ve desde dentro.

#### El freelance con dos planes Max

> "Cada tarde, la misma línea: `You've hit your usage limit · resets at 4pm`.<br>
> Navegador, cerrar sesión, iniciar sesión, vuelta a la terminal, buscar dónde me había quedado."

Dos o tres veces al día, cinco minutos cada vez.<br>
Eso es medio día perdido cada mes.

#### El que instaló un conmutador de cuentas

> "Me ahorra un clic. No me dice cuándo hacer clic.<br>
> Sigo vigilando el límite y cambiando a mano."

#### El que ejecuta una TUI que rota

> "Cambiar ya es automático. Ver cuánto queda, no.<br>
> Eso es otra terminal y otro comando, junto a la que de verdad uso para trabajar."

**"¿No puedo simplemente…"**

- **…usar dos cuentas?** Puedes. Cada vez que salta un límite, el conmutador eres tú.
- **…instalar una app conmutadora?** Acorta el cambio a un clic. Saber cuándo cambiar, y a qué cuenta, sigue siendo cosa tuya.
- **…ejecutar una de las TUI que rotan?** Rotan. También guardan el uso en una terminal que tienes que mantener abierta.

**¿Te suena?**

- [ ] Pagas más de un plan Max.
- [ ] Un mensaje de límite te manda directo al navegador.
- [ ] A veces olvidas en qué cuenta está una terminal.
- [ ] Abres una terminal solo para ver cuánto queda.
- [ ] El límite semanal te sorprende cada vez.

Tres o más, y la siguiente sección es para ti.

## La solución

Claude AutoSwitch es un proxy local con una barra de menús.<br>
Inicia sesión con dos o más cuentas de Claude y pon el proxy delante de Claude Code.<br>
Cada petición sale con el token de una cuenta que todavía tiene margen.<br>
Cuando una cuenta alcanza su límite de 5 horas o semanal, la siguiente petición simplemente usa otra.<br>
Claude Code nunca cierra sesión, nunca se reinicia y nunca se entera.<br>
El límite que lee es el de la rotación, no el de una cuenta, así que mientras otra cuenta tenga margen no aparece ningún aviso de límite.<br>
La cuota de cada cuenta está en la barra de menús, así que nunca abres una terminal solo para mirar.

No es un *conmutador* de cuentas: no se intercambia nada en el llavero y no se interrumpe ninguna sesión.<br>
La rotación ocurre por petición, antes de alcanzar el límite, y varias terminales pueden estar en cuentas distintas al mismo tiempo.

## Instalación

Requisitos: macOS 14 Sonoma o posterior y Claude Code.<br>
No hay Node, ni paquete npm, ni otro proxy que instalar.

### Homebrew

```sh
brew install --cask ParkSangGwon/tap/claude-autoswitch
```

Si después macOS se niega a abrir la app, quita la marca de cuarentena: `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"` (o usa Abrir de todos modos, descrito abajo).

### Release de GitHub

Descarga `Claude-AutoSwitch-vX.Y.Z.zip` desde la [última release](https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest).<br>
Descomprímelo y arrastra **Claude AutoSwitch.app** a `/Applications`.

### Desde el código fuente

```sh
git clone https://github.com/ParkSangGwon/claude-account-autoswitch
cd claude-account-autoswitch
make install          # builds dist/Claude AutoSwitch.app and copies it to /Applications
```

La app está firmada ad hoc, no notarizada.<br>
En el primer arranque macOS puede decir que no puede verificar el desarrollador.<br>
Abre **Ajustes del Sistema → Privacidad y seguridad** y pulsa **Abrir de todos modos**, o haz clic derecho en la app → **Abrir**.

## Configuración en tres pasos

1. **Añade cuentas.** Ajustes → Cuentas → *Añadir cuenta…*
   - Inicia sesión desde el navegador.
   - Pega un código cuando el navegador no llega a este Mac.
   - Importa el inicio de sesión que Claude Code ya tiene (llavero).
2. **Pon el proxy delante de Claude Code.** Una sola línea, con un botón Copiar bajo Ajustes → Proxy:
   ```sh
   [ -f "$HOME/Library/Application Support/Claude AutoSwitch/env.sh" ] && source "$HOME/Library/Application Support/Claude AutoSwitch/env.sh"
   ```
   Ponla en tu perfil de shell o usa *Abrir Terminal con Claude Code*.
   Para un editor o lanzador que ejecute el binario directamente, apúntalo a `claude-autoswitch` en la misma carpeta en lugar de a `claude`.
3. **Activa Abrir al iniciar sesión** (Ajustes → General) para que el proxy esté ahí siempre que Claude Code lo esté.

Eso es toda la configuración.<br>
Claude Code conserva su propio inicio de sesión y sigue hablando con `api.anthropic.com`, así que el control remoto, los ajustes gestionados y la política de la organización siguen funcionando.<br>
El proxy sustituye el token al salir y deja intacto todo lo demás de la petición.

## El certificado

El proxy se sitúa delante de `api.anthropic.com`, lo que significa que tiene que terminar el TLS de ese host, y eso significa que necesita un certificado que Claude Code acepte.<br>
La app crea una autoridad de certificación en este Mac y apunta solo a Claude Code hacia ella, mediante la variable `NODE_EXTRA_CA_CERTS` del archivo de configuración.<br>
**No** se añade al llavero del sistema: ningún navegador, ninguna otra app y ninguna otra herramienta confía en ella, y por omisión no hay nada apuntando a ella.<br>
Mientras Claude Code confíe en ella, el proxy descifra y vuelve a cifrar el tráfico de la API de Claude de ese proceso: ese es el mecanismo con el que sustituye el token, y las versiones con `ANTHROPIC_BASE_URL` ya veían esas mismas peticiones en claro.<br>
Cualquiera que tenga la **clave privada** de la CA podría emitir certificados que Claude Code aceptaría, así que esa clave nunca se escribe en disco; la renovación regenera la cadena entera y el único secreto almacenado es una clave leaf para un solo host.<br>
Borra la carpeta de la app y la confianza se va con ella, sin dejar nada en el llavero del sistema.

## Qué obtienes

- **Un elemento de la barra de menús que se lee como uso.**
  - `1h12m 42%` es la ventana de 5 horas de todas las cuentas: el tiempo hasta que se reinicia y después cuánto se ha usado. Las barras de debajo son la de 5 horas y la semanal.
  - Naranja cuando una barra va por delante de su ventana, rojo en el umbral de cambio o cuando nada puede servir.
  - `→ par` durante seis segundos tras una rotación, `—` cuando el proxy no está escuchando.
- **Todas las cuentas de un vistazo.**
  - Barras de sesión, semanal y por familia (Fable, Sonnet), con el número y el reinicio bajo cada una.
  - Nivel, prioridad, cuentas atrás de limitación y las sesiones fijadas a la cuenta.
  - Un menú por fila: usar como actual, activar, omitir un rato, prioridad, eliminar.
- **Adónde va la siguiente petición, y por qué.**
  - El motivo de la cuenta anterior, una prioridad mejor o "se queda en ted".
- **Totales de todas las cuentas y la línea de tiempo de reinicios.**
  - Agregados ponderados por nivel que solo cuentan las cuentas que aún pueden usar la ventana.
  - Cada reinicio de ventana que se acerca, con `↑` en los que devuelven una cuenta a la rotación.
- **Rotación que cubre los casos reales.**
  - Un 429 que nombra una ventana cerrada limita la cuenta durante su retry-after.
  - Un 429 que no nombra ninguna ventana solo pasa la petición a la siguiente cuenta y deja la cuenta en la rotación; solo las repeticiones la apartan.
  - Un token caducado se refresca una vez y se reintenta.
  - 403 y 5xx hacen failover.
  - Cuando todas las cuentas están agotadas, las peticiones pueden esperar un tiempo configurable en lugar de fallar.
  - Un reinicio retoma donde la rotación lo dejó, en vez de mandar la primera petición a una cuenta ya agotada.
- **Sesiones.**
  - Cada sesión de Claude Code se queda en su cuenta por bucket semanal.
  - La distribución uniforme opcional reparte las sesiones nuevas hacia la cuenta menos cargada.
- **Cuando algo va mal, lo dice.**
  - Un archivo de configuración que no puede leer nunca se sobrescribe, y el error nombra la clave que hay que arreglar.
  - Un puerto ocupado nombra el programa que lo tiene y ofrece uno libre; un proxy con el que nadie habla lo dice.
- **Cambia desde cualquier sitio.**
  - El menú de cuentas del panel emergente, el menú de clic derecho o `⌃⌥⌘N` para la siguiente cuenta que pueda servir.
  - `⌃⌥⌘T` abre el panel emergente.
- **Notificaciones con sentido.**
  - Umbrales de todas las cuentas, una rotación con su motivo, una cuenta que sale o vuelve a la rotación.
  - Una cuenta que necesita iniciar sesión de nuevo, el sondeo fallando, una retención, facturación de excedente.
  - Páusalas durante una hora.
- **Siete días de historial.**
  - Una muestra por minuto mientras la app se ejecuta: sparklines de todas las cuentas y una franja de estado por cuenta, guardadas localmente.
- **Habla tu idioma.**
  - English, 한국어, 日本語, 简体中文, Español, Deutsch, Français.
  - Sigue la lista de idiomas del Mac y se puede cambiar en el momento.

## Galería

#### Cuentas
<img src="docs/assets/menubar/settings-accounts.png" width="780" alt="Panel de Cuentas">

#### Rotación
<img src="docs/assets/menubar/settings-rotation.png" width="780" alt="Panel de Rotación: umbral de cambio, umbrales por bucket, distribución de sesiones, retención">

#### Proxy
<img src="docs/assets/menubar/settings-proxy.png" width="780" alt="Panel de Proxy: estado del listener y la línea que Claude Code necesita">

#### General
<img src="docs/assets/menubar/settings-general.png" width="780" alt="Panel General: estilo de la barra de menús, idioma, actualización, atajos, notificaciones">

## El elemento de la barra de menús

| Título | Significado |
| --- | --- |
| `1h12m 42%` | La ventana de 5 horas de todas las cuentas se reinicia en 1h12m y está al 42% de uso. Las barras de debajo son la de 5 horas (arriba) y la semanal (abajo). |
| `ted 1h12m 42%` | Fijado a la cuenta actual (Ajustes → General): su etiqueta de tres letras encabeza el título. |
| `1h12m 42% · 3d12h 61%` | El estilo *Barras + 5h · 7d*: también la ventana semanal. |
| `1h12m 93%!` | Crítico: en el umbral de cambio, o nada puede servir. |
| `→ par` | Acaba de ocurrir una rotación; se muestra durante seis segundos. |
| `—` | El proxy no está escuchando (normalmente el puerto está ocupado). |
| `0%` | Aún no hay cuentas. |

## Atajos

| Teclas | Dónde | Acción |
| --- | --- | --- |
| `⌃⌥⌘N` | en cualquier sitio | Cambiar a la siguiente cuenta disponible |
| `⌃⌥⌘T` | en cualquier sitio | Mostrar u ocultar el panel emergente |
| `⌘R` `⌘T` `⌘,` `⌘Q` | panel emergente | Actualizar · Abrir Terminal con Claude Code · Ajustes · Salir |
| clic derecho en el elemento | barra de menús | Cambiar, actualizar, recargar configuración, pausar notificaciones |

## Cómo funciona

- La app ejecuta un proxy en `127.0.0.1` (SwiftNIO) y Claude Code llega a él a través de `HTTPS_PROXY`.
- Termina `CONNECT api.anthropic.com:443` ella misma y reenvía cada petición con la cabecera `Authorization` de la cuenta elegida en lugar de la del cliente; cualquier otro host se tuneliza sin tocarlo.
- El resto de cabeceras pasan tal cual, y `metadata.user_id` nombra la cuenta cuyo token salió.
- Las respuestas se transmiten en streaming a medida que llegan.
- Las cuentas se eligen por prioridad y después por la ventana semanal que se reinicia antes.
- Se salta cualquier cuenta desactivada, limitada, en su tope de uso, en error o en su umbral para la familia de modelos de la petición.
- Las cabeceras `anthropic-ratelimit-*` de cada respuesta mantienen al día las ventanas de cada cuenta.
- Un sondeo en segundo plano del endpoint de uso rellena las inactivas.
- Los tokens se refrescan cinco minutos antes de caducar.
- La configuración vive en `~/Library/Application Support/Claude AutoSwitch/config.json`, escrita de forma atómica con permisos `0600`.
- Los tokens están en ese archivo y en ningún otro sitio.

La referencia del archivo de configuración, el endpoint de salud y las reglas de rotación está en [docs/reference.md](docs/reference.md).

## Privacidad

Solo se contactan dos hosts: la API de Claude (tus peticiones, el sondeo de uso, el refresco de tokens) y, durante el inicio de sesión, claude.ai / platform.claude.com.<br>
El tráfico hacia cualquier otro host atraviesa el proxy sin ser descifrado.<br>
Sin telemetría, sin comprobaciones de actualizaciones.<br>
La exportación de diagnóstico sustituye todos los secretos antes de escribir.

## Una nota sobre los términos de servicio

Rotar peticiones entre varias suscripciones personales puede quedar fuera de lo que pretenden los términos de consumo de Anthropic.<br>
Este proyecto te muestra la cuota de tus propias cuentas y te deja decidir cómo usarlas.<br>
Lee los términos que aplican a tu plan.

## Documentación

- [docs/troubleshooting.md](docs/troubleshooting.md): Gatekeeper, un puerto ocupado, iniciar sesión de nuevo, tokens compartidos con otras herramientas.
- [docs/reference.md](docs/reference.md): el archivo de configuración, el endpoint de salud, las reglas de rotación.
- [CHANGELOG.md](CHANGELOG.md): qué cambió en cada release.

## Desarrollo

```sh
swift build
swift test            # engine tests run against loopback stand-ins for the Claude API
make app              # dist/Claude AutoSwitch.app
AUTOSWITCH_DEBUG_DEMO_QUOTA=1 CLAUDE_AUTOSWITCH_CONFIG=/tmp/demo.json swift run ClaudeAutoSwitch
```

- `AutoSwitchCore`: el modelo (cuentas, ventanas, bloqueos), las reglas (planificación, ritmo, totales de todas las cuentas), la localización y el documento de configuración.
- `AutoSwitchEngine`: el proxy, con cuentas, OAuth, cuota, rotación y el listener.
- `ClaudeAutoSwitch`: la app.
- Las cadenas viven en `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings`, con el texto en inglés como clave.
- Un test falla si una cadena de las fuentes no tiene fila allí.
- `AUTOSWITCH_DEBUG_WINDOW=<section>` y `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` abren un panel de ajustes y el panel emergente para capturas de pantalla.
- `README.md` y las seis traducciones que lo acompañan cambian juntos; `scripts/check-readmes.sh` falla cuando su estructura se desvía.

## Licencia

MIT.
