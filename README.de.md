<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="Claude AutoSwitch Symbol">
</p>
<h1 align="center">Claude AutoSwitch</h1>
<p align="center">
  Mehrere Claude-Abonnements, ein Claude Code. Eine Menüleisten-App, die Ihre Konten<br>
  automatisch rotiert, wenn ihre Limits voll laufen, und das Kontingent jedes Kontos auf einen Blick zeigt.
</p>
<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Kein Node, keine CLI zu installieren" src="https://img.shields.io/badge/runtime-none%20needed-2ea44f">
  <img alt="7 Sprachen" src="https://img.shields.io/badge/languages-7-3b82f6">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>
<p align="center" data-readme-switcher>
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-CN.md">简体中文</a> · Deutsch · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/assets/menubar/menubar-item.png" width="440" alt="Das Menüleisten-Element: 3h18m 33% neben den Systemelementen">
</p>
<p align="center">
  <img src="docs/assets/menubar/popover-dark.png" width="406" alt="Das Popover: Kontentabelle, Balken aller Konten, Routing, Sitzungen und das Rotationsprotokoll">
</p>

## Das Problem

**Ein Max-Plan für $200 reicht nicht mehr, also zahlen Sie für zwei oder drei.**<br>
So sieht das von innen aus.

#### Der Freelancer mit zwei Max-Plänen

> „Jeden Nachmittag dieselbe Zeile: `You've hit your usage limit · resets at 4pm`.<br>
> Browser, abmelden, anmelden, zurück ins Terminal, wiederfinden, wo ich war.“

Zwei- bis dreimal am Tag, je fünf Minuten.<br>
Das ist jeden Monat ein halber Tag, der einfach weg ist.

#### Der mit dem Konto-Umschalter

> „Er spart mir einen Klick. Wann ich klicken muss, sagt er mir nicht.<br>
> Ich behalte das Limit immer noch im Auge und wechsle von Hand.“

#### Der mit der rotierenden TUI

> „Der Wechsel passiert jetzt von selbst. Zu sehen, was noch übrig ist, nicht.<br>
> Das ist noch ein Terminal und noch ein Befehl, neben dem, in dem ich eigentlich arbeite.“

**„Kann ich nicht einfach…“**

- **…zwei Konten nutzen?** Können Sie. Jedes Mal, wenn ein Limit zuschlägt, sind Sie der Schalter.
- **…eine Umschalter-App installieren?** Sie verkürzt den Wechsel auf einen Klick. Wann Sie wechseln, und auf welches Konto, bleibt an Ihnen hängen.
- **…eine der TUIs laufen lassen, die rotieren?** Sie rotieren. Den Verbrauch halten sie aber in einem Terminal, das Sie offen lassen müssen.

**Kommt Ihnen das bekannt vor?**

- [ ] Sie zahlen für mehr als einen Max-Plan.
- [ ] Eine Limit-Meldung schickt Sie direkt in den Browser.
- [ ] Sie vergessen manchmal, auf welchem Konto ein Terminal gerade läuft.
- [ ] Sie öffnen ein Terminal, nur um zu sehen, wie viel noch übrig ist.
- [ ] Das Wochenlimit überrascht Sie jedes Mal.

Drei oder mehr, und der nächste Abschnitt ist für Sie.

## Die Lösung

Claude AutoSwitch ist ein lokaler Proxy mit Menüleiste.<br>
Melden Sie sich mit zwei oder mehr Claude-Konten an und setzen Sie den Proxy vor Claude Code.<br>
Jede Anfrage geht mit dem Token eines Kontos hinaus, das noch Platz hat.<br>
Erreicht ein Konto sein 5-Stunden- oder Wochenlimit, nutzt die nächste Anfrage einfach ein anderes.<br>
Claude Code meldet sich nie ab, startet nie neu und bekommt nichts davon mit.<br>
Das Kontingent jedes Kontos sitzt in der Menüleiste, sodass Sie nie ein Terminal öffnen, nur um nachzusehen.

Es ist kein Konto-*Umschalter*: Im Schlüsselbund wird nichts ausgetauscht, und keine Sitzung wird unterbrochen.<br>
Die Rotation passiert pro Anfrage, bevor das Limit erreicht ist, und mehrere Terminals können gleichzeitig auf verschiedenen Konten sein.

## Installation

Voraussetzungen: macOS 14 Sonoma oder neuer und Claude Code.<br>
Es gibt kein Node, kein npm-Paket und keinen weiteren Proxy zu installieren.

### Homebrew

```sh
brew install --cask ParkSangGwon/tap/claude-autoswitch
```

Verweigert macOS danach das Öffnen, entfernen Sie das Quarantäne-Attribut: `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"` (oder „Dennoch öffnen“, siehe unten).

### GitHub-Release

Laden Sie `Claude-AutoSwitch-vX.Y.Z.zip` aus dem [neuesten Release](https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest) herunter.<br>
Entpacken Sie es und ziehen Sie **Claude AutoSwitch.app** nach `/Applications`.

### Aus dem Quellcode

```sh
git clone https://github.com/ParkSangGwon/claude-account-autoswitch
cd claude-account-autoswitch
make install          # builds dist/Claude AutoSwitch.app and copies it to /Applications
```

Die App ist ad-hoc signiert, nicht notarisiert.<br>
Beim ersten Start meldet macOS möglicherweise, dass der Entwickler nicht verifiziert werden kann.<br>
Öffnen Sie **Systemeinstellungen → Datenschutz & Sicherheit** und klicken Sie auf **Dennoch öffnen**, oder Rechtsklick auf die App → **Öffnen**.

## Einrichtung in drei Schritten

1. **Konten hinzufügen.** Einstellungen → Konten → *Konto hinzufügen…*
   - Melden Sie sich über den Browser an.
   - Fügen Sie einen Code ein, wenn der Browser diesen Mac nicht erreicht.
   - Importieren Sie die Anmeldung, die Claude Code bereits hat (Schlüsselbund).
2. **Den Proxy vor Claude Code setzen.** Eine Zeile, mit Kopieren-Button angezeigt unter Einstellungen → Proxy:
   ```sh
   [ -f "$HOME/Library/Application Support/Claude AutoSwitch/env.sh" ] && source "$HOME/Library/Application Support/Claude AutoSwitch/env.sh"
   ```
   Tragen Sie sie in Ihr Shell-Profil ein, oder nutzen Sie *Terminal mit Claude Code öffnen*.
   Für einen Editor oder Launcher, der die Binary direkt startet, geben Sie `claude-autoswitch` aus demselben Ordner an statt `claude`.
3. **Bei der Anmeldung öffnen einschalten** (Einstellungen → Allgemein), damit der Proxy immer da ist, wenn Claude Code es ist.

Das ist die ganze Einrichtung.<br>
Claude Code behält seine eigene Anmeldung und spricht weiterhin mit `api.anthropic.com`, sodass Remote Control, verwaltete Einstellungen und Organisationsrichtlinien weiter funktionieren.<br>
Der Proxy ersetzt beim Senden das Token und lässt alles andere in der Anfrage unangetastet.

## Das Zertifikat

Der Proxy steht vor `api.anthropic.com`, muss also das TLS für diesen Host terminieren und braucht damit ein Zertifikat, das Claude Code akzeptiert.<br>
Die App erzeugt auf diesem Mac eine Zertifizierungsstelle und richtet über die Variable `NODE_EXTRA_CA_CERTS` in der Setup-Datei allein Claude Code darauf aus.<br>
Sie wird **nicht** in den Systemschlüsselbund aufgenommen: kein Browser, keine andere App und kein anderes Werkzeug vertraut ihr, und standardmäßig ist überhaupt nichts auf sie ausgerichtet.<br>
Solange Claude Code ihr vertraut, entschlüsselt und verschlüsselt der Proxy den Claude-API-Verkehr dieses Prozesses erneut — genau dadurch tauscht er das Token aus, und die Versionen mit `ANTHROPIC_BASE_URL` sahen dieselben Anfragen ebenfalls im Klartext.<br>
Wer den **privaten Schlüssel** der CA besitzt, könnte Zertifikate ausstellen, die Claude Code akzeptiert; deshalb wird dieser Schlüssel nie auf die Festplatte geschrieben. Erneuert wird, indem die ganze Kette neu erzeugt wird, und das einzige gespeicherte Geheimnis ist ein Leaf-Schlüssel für einen Host.<br>
Löschen Sie den Ordner der App, verschwindet damit auch das Vertrauen, und im Systemschlüsselbund bleibt nichts zurück.

## Was Sie bekommen

- **Ein Menüleisten-Element, das sich als Verbrauch liest.**
  - `1h12m 42%` ist das 5-Stunden-Fenster aller Konten: Zeit bis zur Zurücksetzung, dann wie viel verbraucht ist. Die Balken darunter sind 5 Stunden und Woche.
  - Orange, wenn ein Balken seinem Fenster vorausläuft, rot am Wechsel-Schwellenwert oder wenn nichts bedienen kann.
  - `→ par` für sechs Sekunden bei einer Rotation, `—`, wenn der Listener aus ist.
- **Jedes Konto auf einen Blick.**
  - Sitzungs-, Wochen- und Modellfamilien-Balken (Fable, Sonnet), mit Zahl und Zurücksetzung darunter.
  - Stufe, Priorität, Drossel-Countdowns und die an das Konto angehefteten Sitzungen.
  - Ein Zeilenmenü: Als aktuell festlegen, Aktivieren, Eine Weile überspringen, Priorität, Entfernen.
- **Wohin die nächste Anfrage geht, und warum.**
  - Der Grund des alten Kontos, eine bessere Priorität oder „bleibt bei ted“.
- **Summen aller Konten und die Zeitleiste der Zurücksetzungen.**
  - Nach Stufe gewichtete Aggregate, die nur Konten zählen, die das Fenster noch nutzen können.
  - Jede kommende Fenster-Zurücksetzung, mit `↑` bei denen, die ein Konto zurückbringen.
- **Rotation, die die echten Fälle abdeckt.**
  - Ein 429, das ein geschlossenes Fenster nennt, drosselt das Konto für sein Retry-After.
  - Ein 429, das kein Fenster nennt, schickt nur die Anfrage weiter und lässt das Konto in der Rotation; erst Wiederholungen stellen es beiseite.
  - Ein abgelaufenes Token wird einmal aufgefrischt und erneut versucht.
  - Bei 403 und 5xx wird auf ein anderes Konto gewechselt.
  - Wenn jedes Konto erschöpft ist, können Anfragen für eine konfigurierbare Zeit gehalten werden, statt fehlzuschlagen.
  - Ein Neustart setzt dort an, wo die Rotation aufgehört hat, statt die erste Anfrage an ein bereits erschöpftes Konto zu schicken.
- **Sitzungen.**
  - Jede Claude-Code-Sitzung bleibt pro Wochen-Bucket auf ihrem Konto.
  - Die optionale Gleichverteilung verteilt neue Sitzungen auf das am wenigsten belastete Konto.
- **Wenn etwas nicht stimmt, sagt die App es.**
  - Eine Konfigurationsdatei, die sie nicht lesen kann, wird nie überschrieben, und der Fehler nennt den Schlüssel, der zu korrigieren ist.
  - Ein belegter Port nennt das Programm, das ihn hält, und bietet einen freien an; ein Proxy, mit dem niemand spricht, sagt das.
- **Wechseln von überall.**
  - Das Kontomenü im Popover, das Rechtsklick-Menü oder `⌃⌥⌘N` für das nächste Konto, das bedienen kann.
  - `⌃⌥⌘T` öffnet das Popover.
- **Mitteilungen, die etwas bedeuten.**
  - Schwellenwerte aller Konten, eine Rotation mit ihrem Grund, ein Konto, das die Rotation verlässt oder zurückkehrt.
  - Eine nötige erneute Anmeldung, eine fehlschlagende Abfrage, eine Sperre, Abrechnung von Mehrverbrauch.
  - Pausieren Sie sie für eine Stunde.
- **Sieben Tage Verlauf.**
  - Ein Messwert pro Minute, solange die App läuft: Sparklines aller Konten und ein Zustandsstreifen pro Konto, lokal gehalten.
- **Spricht Ihre Sprache.**
  - English, 한국어, 日本語, 简体中文, Español, Deutsch, Français.
  - Folgt der Sprachenliste des Mac und ist direkt umschaltbar.

## Galerie

#### Konten
<img src="docs/assets/menubar/settings-accounts.png" width="780" alt="Bereich Konten">

#### Rotation
<img src="docs/assets/menubar/settings-rotation.png" width="780" alt="Bereich Rotation: Wechsel-Schwellenwert, Schwellenwerte pro Bucket, Sitzungsverteilung, Warten bei Erschöpfung">

#### Proxy
<img src="docs/assets/menubar/settings-proxy.png" width="780" alt="Bereich Proxy: Listener-Zustand und die Zeile, die Claude Code braucht">

#### Allgemein
<img src="docs/assets/menubar/settings-general.png" width="780" alt="Bereich Allgemein: Menüleisten-Stil, Sprache, Aktualisierung, Tastaturkurzbefehle, Mitteilungen">

## Das Menüleisten-Element

| Titel | Bedeutung |
| --- | --- |
| `1h12m 42%` | Das 5-Stunden-Fenster aller Konten wird in 1h12m zurückgesetzt und ist zu 42% verbraucht. Die Balken darunter sind 5 Stunden (oben) und Woche (unten). |
| `ted 1h12m 42%` | An das aktuelle Konto angeheftet (Einstellungen → Allgemein): seine dreistellige Kennung steht vorn. |
| `1h12m 42% · 3d12h 61%` | Der Stil *Balken + 5h · 7d*: dazu das Wochenfenster. |
| `1h12m 93%!` | Kritisch: am Wechsel-Schwellenwert, oder nichts kann bedienen. |
| `→ par` | Gerade ist eine Rotation passiert; sechs Sekunden lang angezeigt. |
| `—` | Der Listener ist aus (meist ist der Port belegt). |
| `0%` | Noch keine Konten. |

## Tastaturkurzbefehle

| Tasten | Wo | Aktion |
| --- | --- | --- |
| `⌃⌥⌘N` | überall | Zum nächsten Konto wechseln, das bedienen kann |
| `⌃⌥⌘T` | überall | Popover ein- oder ausblenden |
| `⌘R` `⌘T` `⌘,` `⌘Q` | Popover | Aktualisieren · Terminal mit Claude Code öffnen · Einstellungen · Beenden |
| Rechtsklick auf das Element | Menüleiste | Wechseln, aktualisieren, Konfiguration neu laden, Mitteilungen pausieren |

## So funktioniert es

- Die App betreibt einen Proxy auf `127.0.0.1` (SwiftNIO), den Claude Code über `HTTPS_PROXY` erreicht.
- `CONNECT api.anthropic.com:443` terminiert sie selbst und leitet jede Anfrage mit der `Authorization` des gewählten Kontos anstelle der des Clients nach oben weiter; jeder andere Host wird unangetastet getunnelt.
- Jeder andere Header geht durch, und `metadata.user_id` nennt das Konto, dessen Token hinausging.
- Antworten werden gestreamt, sobald sie eintreffen.
- Konten werden nach Priorität gewählt, dann nach dem Wochenfenster, das am frühesten zurückgesetzt wird.
- Übersprungen wird jedes Konto, das deaktiviert, gedrosselt, an der Obergrenze, im Fehlerzustand oder für die Modellfamilie der Anfrage an seinem Schwellenwert ist.
- Die `anthropic-ratelimit-*`-Header jeder Antwort halten die Fenster jedes Kontos aktuell.
- Eine Hintergrundabfrage des Usage-Endpunkts füllt die inaktiven auf.
- Tokens werden fünf Minuten vor Ablauf aufgefrischt.
- Die Konfiguration liegt in `~/Library/Application Support/Claude AutoSwitch/config.json`, atomar geschrieben mit `0600`-Rechten.
- Tokens stehen in dieser Datei und nirgends sonst.

Die Referenz zur Konfigurationsdatei, zum Health-Endpunkt und zu den Rotationsregeln steht in [docs/reference.md](docs/reference.md).

## Datenschutz

Es werden überhaupt nur zwei Hosts kontaktiert: die Claude API (Ihre Anfragen, die Kontingentabfrage, Token-Refresh) und, während der Anmeldung, claude.ai / platform.claude.com.<br>
Verkehr zu jedem anderen Host läuft unentschlüsselt durch den Proxy.<br>
Keine Telemetrie, keine Update-Prüfungen.<br>
Der Diagnose-Export ersetzt jedes Geheimnis vor dem Schreiben.

## Ein Hinweis zu den Nutzungsbedingungen

Anfragen über mehrere persönliche Abonnements zu rotieren, liegt möglicherweise außerhalb dessen, was Anthropics Verbraucherbedingungen vorsehen.<br>
Dieses Projekt zeigt Ihnen das Kontingent Ihrer eigenen Konten und lässt Sie entscheiden, wie Sie es nutzen.<br>
Lesen Sie die Bedingungen, die für Ihren Plan gelten.

## Dokumentation

- [docs/troubleshooting.md](docs/troubleshooting.md): Gatekeeper, ein belegter Port, erneute Anmeldung, mit anderen Tools geteilte Tokens.
- [docs/reference.md](docs/reference.md): die Konfigurationsdatei, der Health-Endpunkt, die Rotationsregeln.
- [CHANGELOG.md](CHANGELOG.md): was sich in jedem Release geändert hat.

## Entwicklung

```sh
swift build
swift test            # engine tests run against loopback stand-ins for the Claude API
make app              # dist/Claude AutoSwitch.app
AUTOSWITCH_DEBUG_DEMO_QUOTA=1 CLAUDE_AUTOSWITCH_CONFIG=/tmp/demo.json swift run ClaudeAutoSwitch
```

- `AutoSwitchCore`: das Modell (Konten, Fenster, Blocker), die Regeln (Scheduling, Tempo, Summen aller Konten), Lokalisierung und das Konfigurationsdokument.
- `AutoSwitchEngine`: der Proxy, mit Konten, OAuth, Kontingent, Rotation und Listener.
- `ClaudeAutoSwitch`: die App.
- Strings liegen in `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings`, mit dem englischen Text als Schlüssel.
- Ein Test schlägt fehl, wenn ein String aus den Quellen dort keine Zeile hat.
- `AUTOSWITCH_DEBUG_WINDOW=<section>` und `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` öffnen einen Einstellungsbereich und das Popover für Screenshots.
- `README.md` und die sechs Übersetzungen daneben ändern sich gemeinsam; `scripts/check-readmes.sh` schlägt fehl, wenn ihre Struktur auseinanderläuft.

## Lizenz

MIT.
