# resolve-setup

**DaVinci Resolve** unter **Debian** mit **AMD-Grafik** installieren und einrichten, in einem Skript.

Blackmagic unterstützt offiziell nur Rocky Linux. Unter Debian scheitert Resolve an drei vorhersehbaren Stellen: am Paketcheck des Installers, an den mitgelieferten GLib-/libc++-Bibliotheken, die mit dem aktuellen System-libpango kollidieren, und an OpenCL — Resolve zeigt eine leere GPU-Liste und startet nicht. Das Skript deckt alle drei ab und sorgt vor allem dafür, dass auch der **Menüeintrag** funktioniert, nicht nur der Aufruf im Terminal.

*[English version of this document](README.md)*

---

## Was es tatsächlich macht

| Schritt | Was passiert |
|---|---|
| 0 | Prüft sudo, warnt bei einer Wayland-Sitzung |
| 1 | Findet den Installer (`.run` oder `.zip`, Free oder Studio), entpackt Archive |
| 2 | Installiert Abhängigkeiten und überspringt Paketnamen, die es in deinem Debian nicht gibt |
| 3 | Startet den Installer mit `SKIP_PACKAGE_CHECK=1` |
| 4 | Verschiebt die mitgelieferte GLib-Familie nach `libs/disabled/`, prüft mit `ldd -r` und verschiebt auch das mitgelieferte libc++, falls Symbole ungelöst bleiben |
| 5 | Prüft OpenCL über Mesa/Rusticl |
| 6 | Schreibt `/usr/local/bin/resolve` — einen Wrapper, der `RUSTICL_ENABLE` und `QT_QPA_PLATFORM` setzt |
| 7 | Kopiert die Desktop-Datei nach `~/.local/share/applications`, biegt `Exec=` auf den Wrapper um und schaltet `DBusActivatable` ab |

**Warum der Wrapper nötig ist.** Rusticl meldet keine OpenCL-Geräte, solange `RUSTICL_ENABLE` nicht gesetzt ist. Die Variable in die `.bashrc` zu schreiben reicht nicht — das Anwendungsmenü liest deine Shell-Konfiguration nicht. Genau daher der typische Effekt: aus dem Terminal startet Resolve mit GPU, über das Menü mit leerer Liste. `DBusActivatable=true` hat denselben Effekt aus anderer Richtung: damit startet der Session-Bus die Anwendung direkt und `Exec=` wird komplett ignoriert.

## Voraussetzungen

- Debian Testing/Unstable oder ein Derivat (Ubuntu sollte gehen; Paketnamen werden geprüft, nicht angenommen)
- AMD-GPU am Kerneltreiber `amdgpu`
- `mesa-opencl-icd` mit Rusticl — im aktuellen Debian enthält das Paket nur noch Rusticl, Clover ist raus
- `non-free-firmware` in den apt-Quellen aktiviert, wegen `firmware-amd-graphics`. Das Skript warnt, wenn das Paket fehlt, statt es stillschweigend zu überspringen.
- Der Resolve-Installer von Blackmagic (Registrierung nötig, das Skript kann ihn nicht herunterladen)

## Aufruf

Skript neben den heruntergeladenen Installer legen:

```bash
chmod +x resolve-setup.de.sh
./resolve-setup.de.sh --dry-run    # erst anschauen
./resolve-setup.de.sh              # dann ausführen
```

Oder die Datei direkt angeben:

```bash
./resolve-setup.de.sh ~/Downloads/DaVinci_Resolve_Studio_21.1_Linux.zip
```

**Nicht** mit `sudo` starten — das Skript ruft sudo selbst auf, und als root landet der Menüeintrag in `/root`.

### Optionen

| Option | Wirkung |
|---|---|
| `--dry-run` | Zeigt jede Aktion, ändert nichts |
| `--check` | Prüft den Zustand, ändert nichts |
| `--undo` | Entfernt Wrapper und Menüeintrag (deinstalliert Resolve **nicht**) |
| `--restore-libs` | Holt die verschobenen Bibliotheken nach `/opt/resolve/libs` zurück |
| `--skip-deps` | Überspringt die Paketinstallation |
| `--skip-install` | Nur konfigurieren, nach einem selbst eingespielten Update |
| `--gpu-driver NAME` | Rusticl-Treiber, Standard `radeonsi` (Intel: `iris`, Notnagel: `llvmpipe`) |
| `-y`, `--yes` | Keine Rückfragen |

### Nach einem Resolve-Update

Der Installer stellt seine mitgelieferten Bibliotheken wieder her und überschreibt die System-Desktop-Datei. Deine Kopie in `~/.local/share/applications` bleibt bestehen, also:

```bash
./resolve-setup.de.sh                              # neuer Installer liegt bereit
./resolve-setup.de.sh --skip-install --skip-deps   # schon manuell aktualisiert
```

## Kontrolle

```bash
./resolve-setup.de.sh --check
```

Bei laufendem Resolve liest das direkt `/proc/<pid>/environ` und sagt dir, ob `RUSTICL_ENABLE` wirklich im Prozess angekommen ist. Das ist der einzige Test, der zählt — alles andere ist Vermutung.

In Resolve: **Preferences → System → Memory and GPU**. Die GPU muss dort auftauchen.

## Fehlersuche

**GPU-Liste bleibt leer.** Erst prüfen, ob OpenCL überhaupt da ist:

```bash
RUSTICL_ENABLE=radeonsi clinfo | head -30
```

Es braucht eine `rusticl`-Plattform, dein Gerät und `Image support: Yes`. Ohne Image support lehnt Resolve das Gerät ab, dann hilft keine Umgebungsvariable mehr. Danach nachsehen, was Resolve selbst gefunden hat:

```bash
grep -iE 'gpuconfig|opencl' ~/.local/share/DaVinciResolve/logs/ResolveDebug.txt | tail -20
```

**clinfo sieht gut aus, Liste trotzdem leer.** Resolve bringt eine eigene `libOpenCL.so.1` mit, die `/etc/OpenCL/vendors/` unter Umständen nicht kennt. `--check` warnt, wenn sie vorhanden ist. Wegschieben:

```bash
sudo mv /opt/resolve/libs/libOpenCL.so* /opt/resolve/libs/disabled/
```

**Resolve startet gar nicht.** Direkt starten, um die Meldung zu sehen:

```bash
/usr/local/bin/resolve
```

Ein `symbol lookup error` mit libpango oder libc++ heißt, dass eine mitgelieferte Bibliothek noch eine System-Bibliothek verdeckt. `--check` führt `ldd -r` aus und meldet ungelöste Symbole.

**Wayland.** Resolve läuft nicht nativ unter Wayland. Der Wrapper setzt `QT_QPA_PLATFORM=xcb` und schickt es damit über Xwayland (das Paket `xwayland` installiert das Skript mit). Eine X11-Sitzung ist der zuverlässige Weg.

**Kein H.264/H.265 und kein AAC.** Der kostenlosen Version fehlt das unter Linux aus Lizenzgründen. Vorher wandeln:

```bash
ffmpeg -i in.mp4 -c:v dnxhd -profile:v dnxhr_hq -c:a pcm_s16le -pix_fmt yuv422p out.mov
```

## Was am System verändert wird

- `/opt/resolve/libs/disabled/` — die verschobenen Bibliotheken (rückgängig mit `--restore-libs`)
- `/usr/local/bin/resolve` — der Wrapper
- `~/.local/share/applications/*.desktop` — dein Menüeintrag; die Systemdatei unter `/usr/share/applications` wird **nie** verändert
- `~/.local/share/resolve-setup/backups/` — frühere Fassungen deiner Desktop-Datei

`--undo` nimmt Wrapper und Menüeintrag zurück. Resolve selbst bleibt unangetastet und wird mit `/opt/resolve/installer -u` deinstalliert.

## Reichweite und Tests

Entwickelt und benutzt unter Debian Testing mit einem **Ryzen 7 7735HS / Radeon 680M** (RDNA2, gfx1035) unter Budgie. Die Logik des Skripts selbst — Installer-Erkennung, Entpacken, Bibliotheksbehandlung inklusive libc++-Fallback, Wrapper, Desktop-Anpassung, `--check`, `--undo`, `--restore-libs`, wiederholte Läufe — ist gegen eine nachgebaute Installation getestet. Shellcheck-sauber auf `style`-Ebene.

Nicht getestet: andere AMD-Generationen, Intel-GPUs (`--gpu-driver iris` ist plausibel, aber unverifiziert), andere Desktop-Umgebungen, andere Distributionen. RDNA2 über Rusticl ist der gut dokumentierte Weg; ältere GCN-Karten und RDNA4 haben eigene Probleme. Rückmeldungen von anderer Hardware sind willkommen.

Rusticl auf einer integrierten GPU ist funktional, nicht schnell. Für 4K solltest du mit Proxies oder optimierten Medien arbeiten.

## Lizenz

Das Skript steht unter MIT. DaVinci Resolve selbst ist proprietäre Software von Blackmagic Design, wird hier weder mitgeliefert noch weitergegeben — du lädst es selbst herunter und akzeptierst deren Lizenz.




# resolve-setup

Install and configure **DaVinci Resolve** on **Debian** with **AMD graphics**, in one script.

Blackmagic only supports Rocky Linux. On Debian, Resolve fails in three predictable places: the installer's package check, the bundled GLib/libc++ libraries that collide with the modern system libpango, and OpenCL — Resolve shows an empty GPU list and refuses to start. This script handles all three and, importantly, makes the **application menu entry** work, not just a terminal command.

*[Deutsche Version dieser Anleitung](README.de.md)*

---

## What it actually does

| Step | What happens |
|---|---|
| 0 | Checks sudo and warns about a Wayland session |
| 1 | Finds the installer (`.run` or `.zip`, Free or Studio), unpacks archives |
| 2 | Installs dependencies, skipping package names your Debian doesn't have |
| 3 | Runs the installer with `SKIP_PACKAGE_CHECK=1` |
| 4 | Moves the bundled GLib family to `libs/disabled/`, verifies with `ldd -r`, and moves the bundled libc++ too if unresolved symbols remain |
| 5 | Verifies OpenCL through Mesa/Rusticl |
| 6 | Writes `/usr/local/bin/resolve`, a wrapper that sets `RUSTICL_ENABLE` and `QT_QPA_PLATFORM` |
| 7 | Copies the desktop file to `~/.local/share/applications`, points `Exec=` at the wrapper and disables `DBusActivatable` |

**Why the wrapper matters.** Rusticl advertises no OpenCL devices unless `RUSTICL_ENABLE` is set. Setting it in `.bashrc` is not enough — the desktop menu does not read your shell config. That is why Resolve starts fine from a terminal and shows an empty GPU list from the menu. `DBusActivatable=true` matters for the same reason: with it, the session bus launches the app directly and `Exec=` is ignored entirely.

## Requirements

- Debian Testing/Unstable or a derivative (Ubuntu should work; package names are probed, not assumed)
- An AMD GPU on the `amdgpu` kernel driver
- `mesa-opencl-icd` providing Rusticl — on current Debian this package contains only Rusticl, Clover is gone
- `non-free-firmware` enabled in your apt sources, for `firmware-amd-graphics`. The script warns if the package is unavailable rather than skipping it silently.
- The Resolve installer, downloaded from Blackmagic (registration required, the script cannot fetch it for you)

## Usage

Put the script next to the downloaded installer:

```bash
chmod +x resolve-setup.sh
./resolve-setup.sh --dry-run    # see what it would do
./resolve-setup.sh              # do it
```

Or point at the file:

```bash
./resolve-setup.sh ~/Downloads/DaVinci_Resolve_Studio_21.1_Linux.zip
```

Do **not** run it with `sudo` — it calls sudo itself, and as root the menu entry would land in `/root`.

### Options

| Option | Effect |
|---|---|
| `--dry-run` | Show every action, change nothing |
| `--check` | Inspect the current state, change nothing |
| `--undo` | Remove the wrapper and your menu entry (does **not** uninstall Resolve) |
| `--restore-libs` | Move the disabled libraries back into `/opt/resolve/libs` |
| `--skip-deps` | Skip package installation |
| `--skip-install` | Only configure; use after an update you installed yourself |
| `--gpu-driver NAME` | Rusticl driver, default `radeonsi` (Intel: `iris`, fallback: `llvmpipe`) |
| `-y`, `--yes` | No prompts |

### After a Resolve update

The installer restores its bundled libraries and overwrites the system desktop file. Your copy in `~/.local/share/applications` survives, so:

```bash
./resolve-setup.sh                        # new installer present
./resolve-setup.sh --skip-install --skip-deps   # already updated manually
```

## Verifying it worked

```bash
./resolve-setup.sh --check
```

With Resolve running, this reads `/proc/<pid>/environ` directly and tells you whether `RUSTICL_ENABLE` actually reached the process. That is the only test that counts — everything else is inference.

In Resolve: **Preferences → System → Memory and GPU**. The GPU must be listed.

## Troubleshooting

**GPU list is empty.** First confirm OpenCL exists at all:

```bash
RUSTICL_ENABLE=radeonsi clinfo | head -30
```

You need a `rusticl` platform, your device, and `Image support: Yes`. Without image support Resolve rejects the device and no environment variable will help. Then check what Resolve itself saw:

```bash
grep -iE 'gpuconfig|opencl' ~/.local/share/DaVinciResolve/logs/ResolveDebug.txt | tail -20
```

**Still empty, but clinfo is fine.** Resolve ships its own `libOpenCL.so.1`, which may not read `/etc/OpenCL/vendors/`. `--check` warns when it is present. Move it aside:

```bash
sudo mv /opt/resolve/libs/libOpenCL.so* /opt/resolve/libs/disabled/
```

**Resolve won't start at all.** Run it directly to see the error:

```bash
/usr/local/bin/resolve
```

A `symbol lookup error` naming libpango or libc++ means a bundled library is still shadowing a system one. `--check` runs `ldd -r` and reports unresolved symbols.

**Wayland.** Resolve does not run on native Wayland. The wrapper sets `QT_QPA_PLATFORM=xcb`, which routes it through Xwayland (the script installs the `xwayland` package). An X11 session is the reliable option.

**No H.264/H.265 or AAC.** The free edition lacks these on Linux for licensing reasons. Transcode first:

```bash
ffmpeg -i in.mp4 -c:v dnxhd -profile:v dnxhr_hq -c:a pcm_s16le -pix_fmt yuv422p out.mov
```

## What it changes on your system

- `/opt/resolve/libs/disabled/` — bundled libraries moved here (reversible with `--restore-libs`)
- `/usr/local/bin/resolve` — the wrapper
- `~/.local/share/applications/*.desktop` — your menu entry; the system file under `/usr/share/applications` is **never** modified
- `~/.local/share/resolve-setup/backups/` — previous versions of your desktop file

`--undo` reverses the wrapper and the menu entry. Resolve itself is untouched; uninstall it with `/opt/resolve/installer -u`.

## Scope and testing

Developed and used on Debian Testing with a **Ryzen 7 7735HS / Radeon 680M** (RDNA2, gfx1035) under Budgie. The script's own logic — installer discovery, archive extraction, library handling including the libc++ fallback, wrapper, desktop patching, `--check`, `--undo`, `--restore-libs`, idempotent re-runs — is tested against a mock installation. Shellcheck-clean at `style` level.

Untested elsewhere: other AMD generations, Intel GPUs (`--gpu-driver iris` is plausible but unverified), other desktop environments, other distributions. RDNA2 through Rusticl is the well-documented path; older GCN cards and RDNA4 have their own problems. Reports from other hardware are welcome.

Rusticl on an integrated GPU is functional, not fast. Expect to work with proxies or optimized media for 4K.

## License

The script is MIT-licensed. DaVinci Resolve itself is proprietary software by Blackmagic Design and is neither included nor redistributed here — you download it yourself and accept their licence.
