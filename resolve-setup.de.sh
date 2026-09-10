#!/usr/bin/env bash
#
# resolve-setup.de.sh
#
# Installiert und konfiguriert DaVinci Resolve (Free oder Studio) auf
# Debian Testing mit AMD-Grafik. Deckt die Punkte ab, die Resolve auf
# Debian sonst scheitern lassen:
#
#   - fehlende Abhaengigkeiten und der Paketcheck des Installers
#   - die mitgelieferten GLib-/libc++-Bibliotheken, die mit dem
#     System-libpango kollidieren
#   - OpenCL ueber Mesa/Rusticl (RUSTICL_ENABLE=radeonsi), ohne das
#     Resolve keine GPU findet
#   - ein Menueeintrag, der diese Umgebung auch wirklich mitgibt
#
# Aufruf:
#   ./resolve-setup.de.sh                    Installer im Verzeichnis suchen
#   ./resolve-setup.de.sh <datei.run|.zip>   Installer explizit angeben
#
# Optionen:
#   --dry-run          nur anzeigen, was passieren wuerde
#   --check            Zustand pruefen, nichts aendern
#   --undo             Wrapper und eigenen Menueeintrag entfernen
#                      (deinstalliert Resolve NICHT)
#   --restore-libs     verschobene Bibliotheken nach /opt/resolve/libs
#                      zurueckholen
#   --skip-deps        Paketinstallation ueberspringen
#   --skip-install     Resolve nicht installieren, nur konfigurieren
#                      (nach einem Update, das schon eingespielt ist)
#   --gpu-driver NAME  Rusticl-Treiber, Standard: radeonsi
#                      (Intel: iris, Fallback: llvmpipe)
#   -y, --yes          keine Rueckfragen
#
# Nicht mit sudo starten - das Skript ruft sudo selbst auf, wo noetig.

set -euo pipefail

# ------------------------------------------------------------- Konstanten

RESOLVE_ROOT=/opt/resolve
RESOLVE_BIN="$RESOLVE_ROOT/bin/resolve"
RESOLVE_LIBS="$RESOLVE_ROOT/libs"
DISABLED_DIR="$RESOLVE_LIBS/disabled"
WRAPPER=/usr/local/bin/resolve

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPDIR="$DATA_HOME/applications"
BACKUPDIR="$DATA_HOME/resolve-setup/backups"
SYSDIRS=(/usr/share/applications /usr/local/share/applications)

# Bibliotheken, die Resolve mitbringt und die das System besser kann.
# shellcheck disable=SC2034  # via nameref in disable_shadow_libs
SHADOW_LIBS=(libglib-2.0.so libgio-2.0.so libgmodule-2.0.so libgobject-2.0.so)
# shellcheck disable=SC2034  # via nameref in disable_shadow_libs
SHADOW_LIBS_CXX=(libc++.so libc++abi.so)

# Kandidaten. Alternativen mit "|" getrennt - es gewinnt der erste
# Name, den apt wirklich installieren kann, damit ist die t64-Umbenennung
# in beide Richtungen abgedeckt.
PKGS=(
    "libapr1t64|libapr1"
    "libaprutil1t64|libaprutil1"
    "libasound2t64|libasound2"
    "libglib2.0-0t64|libglib2.0-0"
    libxcb-cursor0 libxcb-composite0 libxcb-xinerama0 libxkbcommon-x11-0
    libc++1
    xdg-utils desktop-file-utils unzip
    xwayland
    mesa-opencl-icd ocl-icd-libopencl1 clinfo
    firmware-amd-graphics
)

# ------------------------------------------------------------- Zustand

DRY_RUN=0
ASSUME_YES=0
SKIP_DEPS=0
SKIP_INSTALL=0
MODE=setup
GPU_DRIVER=radeonsi
INSTALLER=""
TMPDIR_CREATED=""
EDITION="DaVinci Resolve"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=; GRN=; YEL=; BLD=; RST=; }

info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "${GRN}  OK${RST}   $*"; }
warn() { printf '%s\n' "${YEL}  !${RST}    $*"; }
die()  { printf '\n%s\n' "${RED}Fehler:${RST} $*" >&2; exit 1; }
step() { printf '\n%s\n' "${BLD}$*${RST}"; }

# Kopfkommentar bis zur ersten Nicht-Kommentarzeile ausgeben, statt
# feste Zeilennummern zu raten.
show_help() {
    local line
    while IFS= read -r line; do
        [[ $line == '#!'* ]] && continue
        [[ $line == '#'* || -z $line ]] || break
        printf '%s\n' "${line###}" | sed 's/^ //'
    done < "$0"
}

run() {
    if (( DRY_RUN )); then
        printf '%s\n' "  [dry-run] $*"
    else
        "$@"
    fi
}

cleanup() {
    [[ -n $TMPDIR_CREATED && -d $TMPDIR_CREATED ]] && rm -rf "$TMPDIR_CREATED"
    return 0
}
trap cleanup EXIT

confirm() {
    (( ASSUME_YES )) && return 0
    (( DRY_RUN )) && return 0
    local answer
    read -r -p "  $1 [j/N] " answer
    [[ $answer =~ ^([jJ]|[yY])$ ]]
}

# ------------------------------------------------------------- Argumente

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --check)        MODE=check ;;
        --undo)         MODE=undo ;;
        --restore-libs) MODE=restore ;;
        --skip-deps)    SKIP_DEPS=1 ;;
        --skip-install) SKIP_INSTALL=1 ;;
        --gpu-driver)   [[ ${2:-} && ${2:-} != -* ]] \
                            || die "--gpu-driver braucht einen Wert, z.B. --gpu-driver radeonsi"
                        GPU_DRIVER="$2"; shift ;;
        -y|--yes)       ASSUME_YES=1 ;;
        -h|--help)      show_help; exit 0 ;;
        -*)             die "Unbekannte Option: $1" ;;
        *)              INSTALLER="$1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] && die "Bitte als normaler Benutzer starten, nicht mit sudo.
        Das Skript ruft sudo selbst auf, wo es gebraucht wird.
        Als root landet der Menueeintrag sonst in /root."

# ============================================================== Funktionen

have() { command -v "$1" >/dev/null 2>&1; }

# Root-Rechte werden fuer /opt/resolve, /usr/local/bin und apt gebraucht.
# Lieber sofort abbrechen als nach der halben Arbeit.
require_sudo() {
    (( DRY_RUN )) && return 0
    have sudo || die "sudo ist nicht installiert.
        Als root nachinstallieren:  apt install sudo
        und den Benutzer $USER der Gruppe sudo hinzufuegen."
    if ! sudo -v; then
        die "Keine sudo-Rechte fuer $USER."
    fi
}

# --- Installer finden -------------------------------------------------

find_installer() {
    local here candidates=() d f
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -n $INSTALLER ]]; then
        printf '%s\n' "$(readlink -f "$INSTALLER")"
        return 0
    fi

    for d in "$PWD" "$here"; do
        while IFS= read -r f; do
            candidates+=("$f")
        done < <(find "$d" -maxdepth 1 -type f \
                    \( -name 'DaVinci_Resolve*_Linux.run' \
                       -o -name 'DaVinci_Resolve*_Linux.zip' \) 2>/dev/null | sort -u)
    done

    # Duplikate raus (PWD und Skriptverzeichnis koennen identisch sein)
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk 'NF' | sort -u)

    (( ${#candidates[@]} == 0 )) && return 1

    if (( ${#candidates[@]} > 1 )); then
        # Neueste Version gewinnt: Versionsnummer aus dem Dateinamen sortieren.
        # Liegen Free und Studio nebeneinander, gewinnt Studio - in dem Fall
        # den gewuenschten Installer besser als Argument angeben.
        mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -V)
        {
            printf '%s\n' "  Mehrere Installer gefunden:"
            printf '       %s\n' "${candidates[@]##*/}"
        } >&2
    fi
    printf '%s\n' "${candidates[-1]}"
}

# --- .zip auspacken, .run herausholen ---------------------------------

# Setzt RUN_FILE global. Bewusst KEINE Ausgabe ueber stdout mit
# Command-Substitution - sonst liefe die Funktion in einer Subshell und
# TMPDIR_CREATED erreichte den Cleanup-Trap nicht.
extract_run() {
    local src="$1"
    if [[ $src == *.run ]]; then
        RUN_FILE="$src"
        return 0
    fi

    have unzip || die "unzip fehlt. Erst installieren: sudo apt install unzip"
    TMPDIR_CREATED="$(mktemp -d)"
    info "Entpacke $(basename "$src") ..."
    unzip -q -o "$src" -d "$TMPDIR_CREATED" \
        || die "Konnte $src nicht entpacken."
    RUN_FILE="$(find "$TMPDIR_CREATED" -maxdepth 2 -name '*.run' -type f | head -1)"
    [[ -n $RUN_FILE ]] || die "Im Archiv ist keine .run-Datei enthalten."
    chmod +x "$RUN_FILE"
    info "Entpackt: $(basename "$RUN_FILE")"
}

detect_edition() {
    if [[ $(basename "$1") == *Studio* ]]; then
        EDITION="DaVinci Resolve Studio"
    else
        EDITION="DaVinci Resolve"
    fi
}

# --- Pakete -----------------------------------------------------------

# apt-cache show meldet auch bei rein virtuellen Paketen Erfolg - etwa
# libasound2 nach der t64-Umbenennung - die sich dann nicht installieren
# lassen. Nur ein echter Installationskandidat zaehlt.
pkg_installable() {
    local cand
    cand="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: //p')"
    [[ -n $cand && $cand != "(none)" ]]
}

install_deps() {
    local available=() skipped=() alts=() entry chosen p
    have apt-get || { warn "Kein apt gefunden - Paketschritt uebersprungen."; return 0; }

    for entry in "${PKGS[@]}"; do
        chosen=""
        IFS='|' read -r -a alts <<< "$entry"
        for p in "${alts[@]}"; do
            if pkg_installable "$p"; then chosen="$p"; break; fi
        done
        if [[ -n $chosen ]]; then
            available+=("$chosen")
        else
            skipped+=("${alts[0]}")
        fi
    done
    # Dass ausnahmslos jedes Paket fehlt, ist unplausibel - das ist ein
    # Erkennungsfehler, keine Realitaet. Dann die Liste trotzdem an apt
    # geben und das entscheiden lassen.
    if (( ${#available[@]} == 0 )); then
        warn "Kein Paket schien installierbar - das ist fast sicher ein"
        warn "Erkennungsproblem, nicht dein System. Ueberlasse es jetzt apt."
        for entry in "${PKGS[@]}"; do
            IFS='|' read -r -a alts <<< "$entry"
            available+=("${alts[0]}")
        done
        skipped=()
    fi

    if (( ${#skipped[@]} )); then
        info "Nicht in deinen Quellen, uebersprungen: ${skipped[*]}"
        # Bei AMD entscheidend: ohne die Firmware bekommt der Kerneltreiber
        # die GPU unter Umstaenden gar nicht hoch.
        if [[ " ${skipped[*]} " == *" firmware-amd-graphics "* ]]; then
            warn "firmware-amd-graphics fehlt. Unter Debian liegt das Paket in"
            warn "der Komponente non-free-firmware - diese in den Quellen"
            warn "aktivieren, sonst kommt die GPU moeglicherweise nicht hoch."
        fi
    fi

    info "Installiere: ${available[*]}"
    if ! run sudo apt-get update -qq; then
        warn "apt-get update fehlgeschlagen - arbeite mit dem vorhandenen Index weiter."
    fi

    if (( DRY_RUN )); then
        info "[dry-run] sudo apt-get install -y ${available[*]}"
        return 0
    fi

    # Erst alles zusammen. Scheitert das an einem einzelnen Namen
    # (rein virtuelles Paket, Umbenennung), einzeln nachziehen, damit
    # der Rest trotzdem ankommt.
    if sudo apt-get install -y "${available[@]}"; then
        ok "Pakete installiert"
        return 0
    fi

    warn "Sammelinstallation fehlgeschlagen - versuche einzeln."
    local failed=()
    for p in "${available[@]}"; do
        sudo apt-get install -y "$p" >/dev/null 2>&1 || failed+=("$p")
    done
    if (( ${#failed[@]} )); then
        warn "Nicht installierbar: ${failed[*]}"
        warn "Wenn Resolve spaeter startet, ist das meist unkritisch."
    else
        ok "Pakete installiert"
    fi
}

# --- Resolve installieren ---------------------------------------------

install_resolve() {
    local run_file="$1"
    info "Starte den Installer. Der Paketcheck wird uebergangen"
    info "(SKIP_PACKAGE_CHECK=1), die Lizenzabfrage erscheint als Fenster."
    run sudo env SKIP_PACKAGE_CHECK=1 "$run_file" -i
    [[ -x $RESOLVE_BIN ]] || (( DRY_RUN )) \
        || die "Nach dem Installer fehlt $RESOLVE_BIN - Installation abgebrochen?"
}

# --- Mitgelieferte Bibliotheken entschaerfen --------------------------

disable_shadow_libs() {
    local -n libs=$1
    local pattern moved=0 f
    for pattern in "${libs[@]}"; do
        shopt -s nullglob
        for f in "$RESOLVE_LIBS/$pattern"*; do
            [[ -f $f || -L $f ]] || continue
            (( moved )) || run sudo mkdir -p "$DISABLED_DIR"
            run sudo mv "$f" "$DISABLED_DIR/"
            info "verschoben: $(basename "$f")"
            moved=1
        done
        shopt -u nullglob
    done
    return $(( moved ? 0 : 1 ))
}

# ldd -r loest auch Relocations auf und meldet damit genau die
# "undefined symbol"-Faelle, an denen Resolve sonst beim Start stirbt.
undefined_symbols() {
    [[ -x $RESOLVE_BIN ]] || return 0
    LC_ALL=C ldd -r "$RESOLVE_BIN" 2>&1 | grep -i 'undefined symbol' || true
}

fix_libraries() {
    if [[ ! -d $RESOLVE_LIBS ]]; then
        (( DRY_RUN )) && { info "[dry-run] $RESOLVE_LIBS existiert noch nicht"; return 0; }
        warn "$RESOLVE_LIBS nicht gefunden - uebersprungen."
        return 0
    fi

    info "GLib-Familie aus $RESOLVE_LIBS entfernen"
    disable_shadow_libs SHADOW_LIBS || info "nichts zu verschieben (schon erledigt)"

    local undef
    undef="$(undefined_symbols)"
    if [[ -n $undef ]]; then
        warn "Noch ungeloeste Symbole:"
        printf '%s\n' "$undef" | head -5 | sed 's/^/       /'
        if grep -qi 'libc++\|__cxa\|_ZNSt\|_ZNKSt' <<<"$undef"; then
            info "Sieht nach den mitgelieferten libc++-Bibliotheken aus, verschiebe die auch."
            disable_shadow_libs SHADOW_LIBS_CXX || true
            undef="$(undefined_symbols)"
            if [[ -z $undef ]]; then
                ok "Symbole jetzt sauber aufloesbar"
            else
                warn "Es bleiben ungeloeste Symbole:"
                printf '%s\n' "$undef" | head -5 | sed 's/^/       /'
            fi
        fi
    else
        ok "Alle Symbole aufloesbar"
    fi
}

# --- OpenCL -----------------------------------------------------------

check_opencl() {
    if ! have clinfo; then
        warn "clinfo nicht installiert - OpenCL nicht pruefbar."
        return 1
    fi
    local out
    out="$(RUSTICL_ENABLE=$GPU_DRIVER LC_ALL=C clinfo 2>/dev/null || true)"

    if ! grep -qi 'rusticl' <<<"$out"; then
        warn "Rusticl meldet mit RUSTICL_ENABLE=$GPU_DRIVER keine Plattform."
        warn "Ohne das findet Resolve keine GPU. Pruefen:"
        warn "  RUSTICL_ENABLE=$GPU_DRIVER clinfo | head -30"
        return 1
    fi
    ok "Rusticl-Plattform vorhanden"

    local dev
    dev="$(grep -m1 -i 'Device Name' <<<"$out" | sed 's/.*Device Name *//')"
    [[ -n $dev ]] && info "Geraet: $dev"

    if grep -qi 'Image support.*Yes' <<<"$out"; then
        ok "Mindestens ein Geraet meldet Image support"
    else
        warn "Kein Geraet meldet Image support - Resolve lehnt solche"
        warn "Geraete in der Regel ab. Vollstaendig pruefen mit:"
        warn "  RUSTICL_ENABLE=$GPU_DRIVER clinfo | grep -i 'image support'"
    fi
    return 0
}

# --- Wrapper ----------------------------------------------------------

create_wrapper() {
    if (( DRY_RUN )); then
        info "[dry-run] wuerde $WRAPPER schreiben (RUSTICL_ENABLE=$GPU_DRIVER)"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064  # $tmp soll jetzt expandiert werden
    trap "rm -f '$tmp'; cleanup" EXIT
    cat > "$tmp" <<WRAPPER_EOF
#!/bin/sh
# Startet DaVinci Resolve mit der Umgebung, die es unter Debian mit
# AMD-Grafik braucht. Erzeugt von resolve-setup.de.sh.
#
#   RUSTICL_ENABLE  meldet die GPU ueber Mesa/Rusticl an OpenCL an
#   QT_QPA_PLATFORM Resolve laeuft nicht nativ unter Wayland
export RUSTICL_ENABLE=$GPU_DRIVER
export QT_QPA_PLATFORM=xcb
exec "$RESOLVE_BIN" "\$@"
WRAPPER_EOF
    sudo install -m 0755 "$tmp" "$WRAPPER"
    rm -f "$tmp"
    trap cleanup EXIT
    ok "$WRAPPER angelegt (RUSTICL_ENABLE=$GPU_DRIVER)"
}

# --- Menueeintrag -----------------------------------------------------

find_desktop_files() {
    local d
    for d in "${SYSDIRS[@]}"; do
        [[ -d $d ]] || continue
        grep -rlF "$RESOLVE_BIN" "$d" --include='*.desktop' 2>/dev/null || true
    done
}

setup_desktop() {
    local files=() src base dst bak
    mapfile -t files < <(find_desktop_files | sort -u)

    if (( ${#files[@]} == 0 )); then
        warn "Keine Desktop-Datei gefunden, die auf $RESOLVE_BIN zeigt - lege eine an."
        if (( DRY_RUN )); then
            info "[dry-run] wuerde $APPDIR/davinci-resolve.desktop erstellen"
            return 0
        fi
        mkdir -p "$APPDIR"
        cat > "$APPDIR/davinci-resolve.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$EDITION
Comment=Video editing and color grading
Exec=$WRAPPER %u
Icon=$RESOLVE_ROOT/graphics/DV_Resolve.png
Terminal=false
Categories=AudioVideo;Video;AudioVideoEditing;
EOF
        ok "Neu erstellt: $APPDIR/davinci-resolve.desktop"
        return 0
    fi

    run mkdir -p "$APPDIR"
    for src in "${files[@]}"; do
        base="$(basename "$src")"
        dst="$APPDIR/$base"
        info "Quelle: $src"

        if [[ -e $dst ]]; then
            bak="$BACKUPDIR/$base.$(date +%Y%m%d%H%M%S)"
            run mkdir -p "$BACKUPDIR"
            run cp -a "$dst" "$bak"
            info "gesichert nach $BACKUPDIR"
        fi

        run cp "$src" "$dst"

        if (( DRY_RUN )); then
            info "[dry-run] wuerde Exec= und DBusActivatable= anpassen"
            continue
        fi

        chmod u+w "$dst"
        # Ein "env VAR=..."-Praefix faellt weg, Feldcodes wie %u bleiben.
        sed -i -E "s#^Exec=.*${RESOLVE_BIN}#Exec=${WRAPPER}#" "$dst"
        # D-Bus-Aktivierung umgeht Exec= komplett.
        sed -i -E 's#^DBusActivatable=true#DBusActivatable=false#' "$dst"

        if grep -qE "^Exec=${WRAPPER}" "$dst"; then
            ok "Angepasst: $dst"
            grep -E '^Exec=' "$dst" | sed 's/^/       /'
        else
            warn "Exec= zeigt nicht auf den Wrapper - bitte manuell pruefen:"
            grep -E '^Exec=' "$dst" | sed 's/^/       /'
        fi
    done

    if have update-desktop-database; then
        run update-desktop-database "$APPDIR"
    else
        warn "desktop-file-utils fehlt - Menue erscheint ggf. erst nach Neuanmeldung."
    fi
}

# ============================================================== Modi

do_check() {
    step "Zustand"

    # Den tatsaechlich eingetragenen Treiber verwenden, nicht den Standard.
    if [[ -r $WRAPPER ]]; then
        local from_wrapper
        from_wrapper="$(sed -n 's/^export RUSTICL_ENABLE=//p' "$WRAPPER" | head -1)"
        [[ -n $from_wrapper ]] && GPU_DRIVER="$from_wrapper"
    fi

    if [[ -x $RESOLVE_BIN ]]; then
        ok "Resolve installiert: $RESOLVE_BIN"
    else
        warn "Resolve nicht unter $RESOLVE_BIN"
    fi

    if [[ -x $WRAPPER ]]; then
        ok "Wrapper: $WRAPPER"
        grep -E '^export' "$WRAPPER" | sed 's/^/       /'
    else
        warn "Kein Wrapper unter $WRAPPER"
    fi

    if [[ -d $DISABLED_DIR ]]; then
        ok "Deaktivierte Bibliotheken: $(find "$DISABLED_DIR" -type f | wc -l) Datei(en)"
    else
        warn "Kein $DISABLED_DIR - mitgelieferte Bibliotheken evtl. noch aktiv"
    fi

    local undef
    undef="$(undefined_symbols)"
    if [[ -z $undef ]]; then
        ok "Keine ungeloesten Symbole"
    else
        warn "Ungeloeste Symbole:"
        printf '%s\n' "$undef" | head -5 | sed 's/^/       /'
    fi

    check_opencl || true

    if compgen -G "$RESOLVE_LIBS/libOpenCL*" >/dev/null 2>&1; then
        warn "Resolve bringt einen eigenen ICD-Loader mit:"
        find "$RESOLVE_LIBS" -maxdepth 1 -name 'libOpenCL*' | sed 's/^/       /'
        warn "Solange die GPU erkannt wird, ist das egal. Bleibt die Liste"
        warn "in Resolve leer, diese Dateien nach $DISABLED_DIR verschieben."
    fi

    step "Menueeintrag"
    local found=0 f
    shopt -s nullglob
    for f in "$APPDIR"/*.desktop; do
        grep -qF "$WRAPPER" "$f" 2>/dev/null || continue
        found=1
        ok "$f"
        grep -E '^Exec=|^DBusActivatable=' "$f" | sed 's/^/       /'
    done
    shopt -u nullglob
    (( found )) || warn "Keine eigene Desktop-Datei unter $APPDIR"

    step "Laufender Prozess"
    local pid
    pid="$(pgrep -u "$(id -u)" -f "$RESOLVE_BIN" 2>/dev/null | head -1 || true)"
    if [[ -n $pid && -r /proc/$pid/environ ]]; then
        local envout
        envout="$(tr '\0' '\n' < "/proc/$pid/environ" \
                    | grep -E '^(RUSTICL_ENABLE|QT_QPA_PLATFORM)=' || true)"
        if [[ -n $envout ]]; then
            printf '%s\n' "$envout" | sed 's/^/       /'
            ok "Die Umgebung ist im laufenden Prozess angekommen."
        else
            warn "Resolve laeuft, aber ohne RUSTICL_ENABLE - am Wrapper vorbei gestartet."
        fi
    else
        info "Resolve laeuft gerade nicht."
    fi
}

do_restore_libs() {
    step "Bibliotheken zurueckschieben"
    if [[ ! -d $DISABLED_DIR ]]; then
        warn "$DISABLED_DIR existiert nicht - nichts zu tun."
        return 0
    fi
    local f count=0
    shopt -s nullglob
    for f in "$DISABLED_DIR"/*; do
        run sudo mv "$f" "$RESOLVE_LIBS/"
        info "zurueck: $(basename "$f")"
        count=$((count + 1))
    done
    shopt -u nullglob
    (( count )) || info "Verzeichnis war leer."
    warn "Resolve startet damit unter Debian sehr wahrscheinlich nicht mehr."
    warn "Rueckgaengig: dieses Skript mit --skip-install --skip-deps erneut laufen lassen."
}

do_undo() {
    step "Rueckbau (Resolve selbst bleibt installiert)"
    local f
    shopt -s nullglob
    for f in "$APPDIR"/*.desktop; do
        grep -qF "$WRAPPER" "$f" 2>/dev/null || continue
        run rm -v "$f"
    done
    shopt -u nullglob
    [[ -e $WRAPPER ]] && run sudo rm -v "$WRAPPER"
    if have update-desktop-database && [[ -d $APPDIR ]]; then
        run update-desktop-database "$APPDIR"
    fi
    info "Backups bleiben unter $BACKUPDIR."
    info "Bibliotheken in $DISABLED_DIR wurden nicht zurueckgeschoben."
    ok "Fertig."
}

# ============================================================== Ablauf

case $MODE in
    check)   do_check;        exit 0 ;;
    undo)    do_undo;         exit 0 ;;
    restore) do_restore_libs; exit 0 ;;
esac

step "DaVinci Resolve - Einrichtung fuer Debian mit AMD-Grafik"
(( DRY_RUN )) && warn "Trockenlauf - es wird nichts veraendert."

# --- Umgebung pruefen

step "0. Umgebung"

require_sudo
(( DRY_RUN )) || ok "sudo-Rechte vorhanden"

if [[ ${XDG_SESSION_TYPE:-} == wayland ]]; then
    warn "Wayland-Session erkannt. Resolve laeuft nur ueber Xwayland"
    warn "(QT_QPA_PLATFORM=xcb, wird gesetzt). Bei Problemen X11-Sitzung waehlen."
else
    ok "Session: ${XDG_SESSION_TYPE:-unbekannt}"
fi

if have glxinfo; then
    renderer="$(LC_ALL=C glxinfo -B 2>/dev/null | grep -m1 'OpenGL renderer' || true)"
    [[ -n $renderer ]] && info "${renderer#*: }"
fi

# --- Installer bestimmen

RUN_FILE=""
if (( SKIP_INSTALL )); then
    info "Installation uebersprungen (--skip-install)."
    [[ -x $RESOLVE_BIN ]] || die "Resolve ist nicht installiert - ohne --skip-install starten."
    # Die Edition laesst sich einer fertigen Installation nicht sicher
    # ansehen - im Zweifel nichts behaupten.
    if grep -qri 'Resolve Studio' "$RESOLVE_ROOT" "${SYSDIRS[0]}" \
            --include='*.desktop' 2>/dev/null; then
        EDITION="DaVinci Resolve Studio"
    else
        EDITION="DaVinci Resolve"
    fi
else
    step "1. Installer suchen"
    [[ -z $INSTALLER || -f $INSTALLER ]] \
        || die "Datei nicht gefunden: $INSTALLER"
    if ! src="$(find_installer)"; then
        die "Kein Installer gefunden.
        Lege die Datei DaVinci_Resolve[_Studio]_<version>_Linux.run oder .zip
        neben dieses Skript, oder gib sie als Argument an:
            $0 ~/Downloads/DaVinci_Resolve_Studio_21.1_Linux.zip"
    fi
    detect_edition "$src"
    ok "Gefunden: $(basename "$src")"
    info "Edition: $EDITION"

    extract_run "$src"

    if [[ -x $RESOLVE_BIN ]]; then
        warn "Unter $RESOLVE_ROOT ist bereits eine Version installiert."
        confirm "Ueber die bestehende Installation installieren?" \
            || die "Abgebrochen."
    fi
fi

# --- Pakete

if (( SKIP_DEPS )); then
    info "Paketinstallation uebersprungen (--skip-deps)."
else
    step "2. Abhaengigkeiten"
    install_deps
fi

# --- Installation

if (( ! SKIP_INSTALL )); then
    step "3. Resolve installieren"
    install_resolve "$RUN_FILE"
    [[ -x $RESOLVE_BIN ]] && ok "Installiert nach $RESOLVE_ROOT"
fi

# --- Bibliotheken

step "4. Mitgelieferte Bibliotheken entschaerfen"
fix_libraries

# --- OpenCL

step "5. OpenCL / Rusticl"
check_opencl || warn "Weiter - der Menueeintrag wird trotzdem eingerichtet."

# --- Wrapper und Menue

step "6. Startwrapper"
create_wrapper

step "7. Menueeintrag"
setup_desktop

case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) warn "/usr/local/bin liegt nicht in deinem PATH - der Menueeintrag"
       warn "funktioniert trotzdem, im Terminal aber $WRAPPER voll angeben." ;;
esac

# --- Abschluss

step "Fertig"
cat <<EOF
  $EDITION ist eingerichtet.

  Starten:
      resolve                      (Terminal)
      oder ueber das Anwendungsmenue

  Danach pruefen, ob die GPU wirklich erkannt wird:
      $0 --check
      In Resolve: Preferences -> System -> Memory and GPU

  Wenn die GPU-Liste leer bleibt:
      RUSTICL_ENABLE=$GPU_DRIVER $RESOLVE_BIN
      grep -iE 'gpuconfig|opencl' ~/.local/share/DaVinciResolve/logs/ResolveDebug.txt | tail -20

  Hinweis zur Free-Version: kein H.264/H.265-Import und kein AAC.
  Material vorher wandeln, zum Beispiel:
      ffmpeg -i in.mp4 -c:v dnxhd -profile:v dnxhr_hq -c:a pcm_s16le \\
             -pix_fmt yuv422p out.mov
EOF
