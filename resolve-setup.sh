#!/usr/bin/env bash
#
# resolve-setup.sh
#
# Installs and configures DaVinci Resolve (Free or Studio) on
# Debian Testing with AMD graphics. Covers the things that otherwise
# make Resolve fail on Debian:
#
#   - missing dependencies and the installer's package check
#   - the bundled GLib/libc++ libraries that collide with the
#     system libpango
#   - OpenCL via Mesa/Rusticl (RUSTICL_ENABLE=radeonsi), without which
#     Resolve finds no GPU
#   - a menu entry that actually passes that environment along
#
# Usage:
#   ./resolve-setup.sh                    look for an installer next to the script
#   ./resolve-setup.sh <file.run|.zip>   point at an installer explicitly
#
# Options:
#   --dry-run          show what would happen, change nothing
#   --check            inspect current state, change nothing
#   --undo             remove wrapper and personal menu entry
#                      (does NOT uninstall Resolve)
#   --restore-libs     move the disabled libraries back into
#                      /opt/resolve/libs
#   --skip-deps        skip package installation
#   --skip-install     do not install Resolve, only configure it
#                      (after an update you already installed)
#   --gpu-driver NAME  Rusticl driver, default: radeonsi
#                      (Intel: iris, fallback: llvmpipe)
#   -y, --yes          assume yes, no prompts
#
# Do not run with sudo - the script calls sudo itself where needed.

set -euo pipefail

# ------------------------------------------------------------- Constants

RESOLVE_ROOT=/opt/resolve
RESOLVE_BIN="$RESOLVE_ROOT/bin/resolve"
RESOLVE_LIBS="$RESOLVE_ROOT/libs"
DISABLED_DIR="$RESOLVE_LIBS/disabled"
WRAPPER=/usr/local/bin/resolve

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPDIR="$DATA_HOME/applications"
BACKUPDIR="$DATA_HOME/resolve-setup/backups"
SYSDIRS=(/usr/share/applications /usr/local/share/applications)

# Libraries Resolve ships that the system does better.
# shellcheck disable=SC2034  # via nameref in disable_shadow_libs
SHADOW_LIBS=(libglib-2.0.so libgio-2.0.so libgmodule-2.0.so libgobject-2.0.so)
# shellcheck disable=SC2034  # via nameref in disable_shadow_libs
SHADOW_LIBS_CXX=(libc++.so libc++abi.so)

# Candidates. Alternatives are separated by "|" - the first one apt
# can actually install wins, so the t64 rename is handled either way.
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

# ------------------------------------------------------------- State

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
die()  { printf '\n%s\n' "${RED}Error:${RST} $*" >&2; exit 1; }
step() { printf '\n%s\n' "${BLD}$*${RST}"; }

# Print the header comment up to the first non-comment line instead
# of guessing fixed line numbers.
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
    read -r -p "  $1 [y/N] " answer
    [[ $answer =~ ^[yY]$ ]]
}

# ------------------------------------------------------------- Arguments

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --check)        MODE=check ;;
        --undo)         MODE=undo ;;
        --restore-libs) MODE=restore ;;
        --skip-deps)    SKIP_DEPS=1 ;;
        --skip-install) SKIP_INSTALL=1 ;;
        --gpu-driver)   [[ ${2:-} && ${2:-} != -* ]] \
                            || die "--gpu-driver needs a value, e.g. --gpu-driver radeonsi"
                        GPU_DRIVER="$2"; shift ;;
        -y|--yes)       ASSUME_YES=1 ;;
        -h|--help)      show_help; exit 0 ;;
        -*)             die "Unknown option: $1" ;;
        *)              INSTALLER="$1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] && die "Please run as a normal user, not with sudo.
        The script calls sudo itself where it is needed.
        As root the menu entry would end up in /root."

# ============================================================== Functions

have() { command -v "$1" >/dev/null 2>&1; }

# Root is needed for /opt/resolve, /usr/local/bin and apt. Better to
# bail out now than halfway through the work.
require_sudo() {
    (( DRY_RUN )) && return 0
    have sudo || die "sudo is not installed.
        Install it as root:  apt install sudo
        and add user $USER to the sudo group."
    if ! sudo -v; then
        die "No sudo privileges for $USER."
    fi
}

# --- Locate the installer ---------------------------------------------

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

    # Drop duplicates (PWD and script dir can be the same)
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | awk 'NF' | sort -u)

    (( ${#candidates[@]} == 0 )) && return 1

    if (( ${#candidates[@]} > 1 )); then
        # Highest version wins, sorted by the version in the filename.
        # With Free and Studio side by side Studio wins - in that case pass
        # the installer you want as an argument.
        mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -V)
        {
            printf '%s\n' "  Multiple installers found:"
            printf '       %s\n' "${candidates[@]##*/}"
        } >&2
    fi
    printf '%s\n' "${candidates[-1]}"
}

# --- Unpack .zip, get at the .run -------------------------------------

# Sets RUN_FILE globally. Deliberately does NOT return via stdout and
# command substitution - that would run this in a subshell and
# TMPDIR_CREATED would never reach the cleanup trap.
extract_run() {
    local src="$1"
    if [[ $src == *.run ]]; then
        RUN_FILE="$src"
        return 0
    fi

    have unzip || die "unzip is missing. Install it first: sudo apt install unzip"
    TMPDIR_CREATED="$(mktemp -d)"
    info "Extracting $(basename "$src") ..."
    unzip -q -o "$src" -d "$TMPDIR_CREATED" \
        || die "Could not extract $src."
    RUN_FILE="$(find "$TMPDIR_CREATED" -maxdepth 2 -name '*.run' -type f | head -1)"
    [[ -n $RUN_FILE ]] || die "The archive contains no .run file."
    chmod +x "$RUN_FILE"
    info "Extracted: $(basename "$RUN_FILE")"
}

detect_edition() {
    if [[ $(basename "$1") == *Studio* ]]; then
        EDITION="DaVinci Resolve Studio"
    else
        EDITION="DaVinci Resolve"
    fi
}

# --- Packages ---------------------------------------------------------

# apt-cache show also succeeds for purely virtual packages such as
# libasound2 after the t64 rename, which then fail to install. Only a
# real installation candidate counts.
pkg_installable() {
    local cand
    cand="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: //p')"
    [[ -n $cand && $cand != "(none)" ]]
}

install_deps() {
    local available=() skipped=() alts=() entry chosen p
    have apt-get || { warn "No apt found - skipping the package step."; return 0; }

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
    # Every single package unavailable is implausible - that is a
    # detection failure, not reality. Hand the list to apt anyway and
    # let it decide.
    if (( ${#available[@]} == 0 )); then
        warn "No package looked installable - that is almost certainly a"
        warn "detection problem, not your system. Letting apt decide instead."
        for entry in "${PKGS[@]}"; do
            IFS='|' read -r -a alts <<< "$entry"
            available+=("${alts[0]}")
        done
        skipped=()
    fi

    if (( ${#skipped[@]} )); then
        info "Not offered by your sources, skipped: ${skipped[*]}"
        # This one matters on AMD: without the firmware the kernel driver
        # may not bring the GPU up at all.
        if [[ " ${skipped[*]} " == *" firmware-amd-graphics "* ]]; then
            warn "firmware-amd-graphics is missing. On Debian it lives in the"
            warn "non-free-firmware component - enable it in your sources and"
            warn "install the package, otherwise the GPU may not initialise."
        fi
    fi

    info "Installing: ${available[*]}"
    if ! run sudo apt-get update -qq; then
        warn "apt-get update failed - continuing with the existing index."
    fi

    if (( DRY_RUN )); then
        info "[dry-run] sudo apt-get install -y ${available[*]}"
        return 0
    fi

    # Everything at once first. If that trips over a single name
    # (purely virtual package, a rename), retry one by one so the
    # rest still gets installed.
    if sudo apt-get install -y "${available[@]}"; then
        ok "Packages installed"
        return 0
    fi

    warn "Bulk install failed - retrying one by one."
    local failed=()
    for p in "${available[@]}"; do
        sudo apt-get install -y "$p" >/dev/null 2>&1 || failed+=("$p")
    done
    if (( ${#failed[@]} )); then
        warn "Not installable: ${failed[*]}"
        warn "If Resolve starts later on, this is usually harmless."
    else
        ok "Packages installed"
    fi
}

# --- Install Resolve --------------------------------------------------

install_resolve() {
    local run_file="$1"
    info "Launching the installer. The package check is bypassed"
    info "(SKIP_PACKAGE_CHECK=1); the licence dialog appears as a window."
    run sudo env SKIP_PACKAGE_CHECK=1 "$run_file" -i
    [[ -x $RESOLVE_BIN ]] || (( DRY_RUN )) \
        || die "$RESOLVE_BIN is missing after the installer - was it cancelled?"
}

# --- Defuse the bundled libraries -------------------------------------

disable_shadow_libs() {
    local -n libs=$1
    local pattern moved=0 f
    for pattern in "${libs[@]}"; do
        shopt -s nullglob
        for f in "$RESOLVE_LIBS/$pattern"*; do
            [[ -f $f || -L $f ]] || continue
            (( moved )) || run sudo mkdir -p "$DISABLED_DIR"
            run sudo mv "$f" "$DISABLED_DIR/"
            info "moved: $(basename "$f")"
            moved=1
        done
        shopt -u nullglob
    done
    return $(( moved ? 0 : 1 ))
}

# ldd -r resolves relocations too and therefore reports exactly the
# "undefined symbol" cases that kill Resolve on startup.
undefined_symbols() {
    [[ -x $RESOLVE_BIN ]] || return 0
    LC_ALL=C ldd -r "$RESOLVE_BIN" 2>&1 | grep -i 'undefined symbol' || true
}

fix_libraries() {
    if [[ ! -d $RESOLVE_LIBS ]]; then
        (( DRY_RUN )) && { info "[dry-run] $RESOLVE_LIBS does not exist yet"; return 0; }
        warn "$RESOLVE_LIBS not found - skipped."
        return 0
    fi

    info "Removing the GLib family from $RESOLVE_LIBS"
    disable_shadow_libs SHADOW_LIBS || info "nothing to move (already done)"

    local undef
    undef="$(undefined_symbols)"
    if [[ -n $undef ]]; then
        warn "Still unresolved symbols:"
        printf '%s\n' "$undef" | head -5 | sed 's/^/       /'
        if grep -qi 'libc++\|__cxa\|_ZNSt\|_ZNKSt' <<<"$undef"; then
            info "Looks like the bundled libc++ libraries, moving those as well."
            disable_shadow_libs SHADOW_LIBS_CXX || true
            undef="$(undefined_symbols)"
            if [[ -z $undef ]]; then
                ok "Symbols resolve cleanly now"
            else
                warn "Unresolved symbols remain:"
                printf '%s\n' "$undef" | head -5 | sed 's/^/       /'
            fi
        fi
    else
        ok "All symbols resolve"
    fi
}

# --- OpenCL -----------------------------------------------------------

check_opencl() {
    if ! have clinfo; then
        warn "clinfo not installed - cannot verify OpenCL."
        return 1
    fi
    local out
    out="$(RUSTICL_ENABLE=$GPU_DRIVER LC_ALL=C clinfo 2>/dev/null || true)"

    if ! grep -qi 'rusticl' <<<"$out"; then
        warn "Rusticl reports no platform with RUSTICL_ENABLE=$GPU_DRIVER."
        warn "Without it Resolve finds no GPU. Check with:"
        warn "  RUSTICL_ENABLE=$GPU_DRIVER clinfo | head -30"
        return 1
    fi
    ok "Rusticl platform present"

    local dev
    dev="$(grep -m1 -i 'Device Name' <<<"$out" | sed 's/.*Device Name *//')"
    [[ -n $dev ]] && info "Device: $dev"

    if grep -qi 'Image support.*Yes' <<<"$out"; then
        ok "At least one device reports image support"
    else
        warn "No device reports image support - Resolve usually rejects"
        warn "such devices. Check in full with:"
        warn "  RUSTICL_ENABLE=$GPU_DRIVER clinfo | grep -i 'image support'"
    fi
    return 0
}

# --- Wrapper ----------------------------------------------------------

create_wrapper() {
    if (( DRY_RUN )); then
        info "[dry-run] would write $WRAPPER (RUSTICL_ENABLE=$GPU_DRIVER)"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064  # $tmp must expand now
    trap "rm -f '$tmp'; cleanup" EXIT
    cat > "$tmp" <<WRAPPER_EOF
#!/bin/sh
# Starts DaVinci Resolve with the environment it needs on Debian
# with AMD graphics. Generated by resolve-setup.sh.
#
#   RUSTICL_ENABLE  exposes the GPU to OpenCL via Mesa/Rusticl
#   QT_QPA_PLATFORM Resolve does not run on native Wayland
export RUSTICL_ENABLE=$GPU_DRIVER
export QT_QPA_PLATFORM=xcb
exec "$RESOLVE_BIN" "\$@"
WRAPPER_EOF
    sudo install -m 0755 "$tmp" "$WRAPPER"
    rm -f "$tmp"
    trap cleanup EXIT
    ok "$WRAPPER created (RUSTICL_ENABLE=$GPU_DRIVER)"
}

# --- Menu entry -------------------------------------------------------

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
        warn "No desktop file points at $RESOLVE_BIN - creating one."
        if (( DRY_RUN )); then
            info "[dry-run] would create $APPDIR/davinci-resolve.desktop"
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
        ok "Created: $APPDIR/davinci-resolve.desktop"
        return 0
    fi

    run mkdir -p "$APPDIR"
    for src in "${files[@]}"; do
        base="$(basename "$src")"
        dst="$APPDIR/$base"
        info "Source: $src"

        if [[ -e $dst ]]; then
            bak="$BACKUPDIR/$base.$(date +%Y%m%d%H%M%S)"
            run mkdir -p "$BACKUPDIR"
            run cp -a "$dst" "$bak"
            info "backed up to $BACKUPDIR"
        fi

        run cp "$src" "$dst"

        if (( DRY_RUN )); then
            info "[dry-run] would patch Exec= and DBusActivatable="
            continue
        fi

        chmod u+w "$dst"
        # An "env VAR=..." prefix is dropped, field codes like %u survive.
        sed -i -E "s#^Exec=.*${RESOLVE_BIN}#Exec=${WRAPPER}#" "$dst"
        # D-Bus activation bypasses Exec= entirely.
        sed -i -E 's#^DBusActivatable=true#DBusActivatable=false#' "$dst"

        if grep -qE "^Exec=${WRAPPER}" "$dst"; then
            ok "Patched: $dst"
            grep -E '^Exec=' "$dst" | sed 's/^/       /'
        else
            warn "Exec= does not point at the wrapper - please check manually:"
            grep -E '^Exec=' "$dst" | sed 's/^/       /'
        fi
    done

    if have update-desktop-database; then
        run update-desktop-database "$APPDIR"
    else
        warn "desktop-file-utils missing - the menu may only update after re-login."
    fi
}

# ============================================================== Modes

do_check() {
    step "State"

    # Use the driver actually recorded in the wrapper, not the default.
    if [[ -r $WRAPPER ]]; then
        local from_wrapper
        from_wrapper="$(sed -n 's/^export RUSTICL_ENABLE=//p' "$WRAPPER" | head -1)"
        [[ -n $from_wrapper ]] && GPU_DRIVER="$from_wrapper"
    fi

    if [[ -x $RESOLVE_BIN ]]; then
        ok "Resolve installed: $RESOLVE_BIN"
    else
        warn "No Resolve at $RESOLVE_BIN"
    fi

    if [[ -x $WRAPPER ]]; then
        ok "Wrapper: $WRAPPER"
        grep -E '^export' "$WRAPPER" | sed 's/^/       /'
    else
        warn "No wrapper at $WRAPPER"
    fi

    if [[ -d $DISABLED_DIR ]]; then
        ok "Disabled libraries: $(find "$DISABLED_DIR" -type f | wc -l) file(s)"
    else
        warn "No $DISABLED_DIR - bundled libraries may still be active"
    fi

    local undef
    undef="$(undefined_symbols)"
    if [[ -z $undef ]]; then
        ok "No unresolved symbols"
    else
        warn "Unresolved symbols:"
        printf '%s\n' "$undef" | head -5 | sed 's/^/       /'
    fi

    check_opencl || true

    if compgen -G "$RESOLVE_LIBS/libOpenCL*" >/dev/null 2>&1; then
        warn "Resolve ships its own ICD loader:"
        find "$RESOLVE_LIBS" -maxdepth 1 -name 'libOpenCL*' | sed 's/^/       /'
        warn "Harmless as long as the GPU is detected. If the list in Resolve"
        warn "stays empty, move these files to $DISABLED_DIR."
    fi

    step "Menu entry"
    local found=0 f
    shopt -s nullglob
    for f in "$APPDIR"/*.desktop; do
        grep -qF "$WRAPPER" "$f" 2>/dev/null || continue
        found=1
        ok "$f"
        grep -E '^Exec=|^DBusActivatable=' "$f" | sed 's/^/       /'
    done
    shopt -u nullglob
    (( found )) || warn "No personal desktop file under $APPDIR"

    step "Running process"
    local pid
    pid="$(pgrep -u "$(id -u)" -f "$RESOLVE_BIN" 2>/dev/null | head -1 || true)"
    if [[ -n $pid && -r /proc/$pid/environ ]]; then
        local envout
        envout="$(tr '\0' '\n' < "/proc/$pid/environ" \
                    | grep -E '^(RUSTICL_ENABLE|QT_QPA_PLATFORM)=' || true)"
        if [[ -n $envout ]]; then
            printf '%s\n' "$envout" | sed 's/^/       /'
            ok "The environment reached the running process."
        else
            warn "Resolve is running without RUSTICL_ENABLE - started around the wrapper."
        fi
    else
        info "Resolve is not running right now."
    fi
}

do_restore_libs() {
    step "Moving libraries back"
    if [[ ! -d $DISABLED_DIR ]]; then
        warn "$DISABLED_DIR does not exist - nothing to do."
        return 0
    fi
    local f count=0
    shopt -s nullglob
    for f in "$DISABLED_DIR"/*; do
        run sudo mv "$f" "$RESOLVE_LIBS/"
        info "restored: $(basename "$f")"
        count=$((count + 1))
    done
    shopt -u nullglob
    (( count )) || info "Directory was empty."
    warn "Resolve will most likely stop starting on Debian now."
    warn "To undo: run this script again with --skip-install --skip-deps."
}

do_undo() {
    step "Teardown (Resolve itself stays installed)"
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
    info "Backups remain in $BACKUPDIR."
    info "Libraries in $DISABLED_DIR were not moved back."
    ok "Done."
}

# ============================================================== Main flow

case $MODE in
    check)   do_check;        exit 0 ;;
    undo)    do_undo;         exit 0 ;;
    restore) do_restore_libs; exit 0 ;;
esac

step "DaVinci Resolve - setup for Debian with AMD graphics"
(( DRY_RUN )) && warn "Dry run - nothing will be changed."

# --- Umgebung pruefen

step "0. Environment"

require_sudo
(( DRY_RUN )) || ok "sudo privileges available"

if [[ ${XDG_SESSION_TYPE:-} == wayland ]]; then
    warn "Wayland session detected. Resolve only runs through Xwayland"
    warn "(QT_QPA_PLATFORM=xcb is set). If it misbehaves, pick an X11 session."
else
    ok "Session: ${XDG_SESSION_TYPE:-unknown}"
fi

if have glxinfo; then
    renderer="$(LC_ALL=C glxinfo -B 2>/dev/null | grep -m1 'OpenGL renderer' || true)"
    [[ -n $renderer ]] && info "${renderer#*: }"
fi

# --- Installer bestimmen

RUN_FILE=""
if (( SKIP_INSTALL )); then
    info "Installation skipped (--skip-install)."
    [[ -x $RESOLVE_BIN ]] || die "Resolve is not installed - run without --skip-install."
    # You cannot reliably tell the edition from an existing install -
    # when in doubt, claim nothing.
    if grep -qri 'Resolve Studio' "$RESOLVE_ROOT" "${SYSDIRS[0]}" \
            --include='*.desktop' 2>/dev/null; then
        EDITION="DaVinci Resolve Studio"
    else
        EDITION="DaVinci Resolve"
    fi
else
    step "1. Locating the installer"
    [[ -z $INSTALLER || -f $INSTALLER ]] \
        || die "File not found: $INSTALLER"
    if ! src="$(find_installer)"; then
        die "No installer found.
        Put DaVinci_Resolve[_Studio]_<version>_Linux.run or .zip next to
        this script, or pass it as an argument:
            $0 ~/Downloads/DaVinci_Resolve_Studio_21.1_Linux.zip"
    fi
    detect_edition "$src"
    ok "Found: $(basename "$src")"
    info "Edition: $EDITION"

    extract_run "$src"

    if [[ -x $RESOLVE_BIN ]]; then
        warn "A version is already installed under $RESOLVE_ROOT."
        confirm "Install over the existing installation?" \
            || die "Aborted."
    fi
fi

# --- Pakete

if (( SKIP_DEPS )); then
    info "Package installation skipped (--skip-deps)."
else
    step "2. Dependencies"
    install_deps
fi

# --- Installation

if (( ! SKIP_INSTALL )); then
    step "3. Installing Resolve"
    install_resolve "$RUN_FILE"
    [[ -x $RESOLVE_BIN ]] && ok "Installed into $RESOLVE_ROOT"
fi

# --- Bibliotheken

step "4. Defusing the bundled libraries"
fix_libraries

# --- OpenCL

step "5. OpenCL / Rusticl"
check_opencl || warn "Continuing - the menu entry is set up regardless."

# --- Wrapper and menu

step "6. Launch wrapper"
create_wrapper

step "7. Menu entry"
setup_desktop

case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) warn "/usr/local/bin is not in your PATH - the menu entry works"
       warn "anyway, but in a terminal give the full path $WRAPPER." ;;
esac

# --- Abschluss

step "Done"
cat <<EOF
  $EDITION is set up.

  Start it:
      resolve                      (terminal)
      or from the application menu

  Then verify the GPU is actually detected:
      $0 --check
      In Resolve: Preferences -> System -> Memory and GPU

  If the GPU list stays empty:
      RUSTICL_ENABLE=$GPU_DRIVER $RESOLVE_BIN
      grep -iE 'gpuconfig|opencl' ~/.local/share/DaVinciResolve/logs/ResolveDebug.txt | tail -20

  Note on the free edition: no H.264/H.265 import and no AAC.
  Transcode your footage first, for example:
      ffmpeg -i in.mp4 -c:v dnxhd -profile:v dnxhr_hq -c:a pcm_s16le \\
             -pix_fmt yuv422p out.mov
EOF
