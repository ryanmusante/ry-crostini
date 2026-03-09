#!/usr/bin/env bash
# crostini-setup-duet5.sh — Crostini post-install bootstrap for Lenovo Duet 5 (82QS0001US)
# Version: 2.4.1
# Date:    2026-03-09
# Arch:    aarch64 / arm64 (Qualcomm Snapdragon 7c Gen 2 — SC7180)
# Target:  Debian Bookworm container under ChromeOS Crostini
# Usage:   bash crostini-setup-duet5.sh [--dry-run] [--help] [--version]
#
# Fully automated — no manual GUI steps required. The script uses
# garcon-url-handler to auto-open any ChromeOS settings pages that
# need a toggle, then waits for you to flip them.
#
# WARNING: Steam (x86-only) CANNOT run on this ARM64 device.
#          Use cloud gaming: GeForce NOW, Xbox Cloud Gaming (browser).
# -----------------------------------------------------------------------------

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
readonly SCRIPT_NAME="crostini-setup-duet5.sh"
readonly SCRIPT_VERSION="2.4.1"
readonly EXPECTED_ARCH="aarch64"
_log_ts="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="${HOME}/crostini-setup-${_log_ts}.log"
readonly STEP_FILE="${HOME}/.crostini-setup-checkpoint"
readonly LOCK_FILE="${HOME}/.crostini-setup.lock"
_cros_uid="$(id -u)"
readonly CROS_UID="$_cros_uid"

DRY_RUN=false

# ── Cleanup trap ─────────────────────────────────────────────────────────────
# shellcheck disable=SC2317  # invoked via trap, not direct call
cleanup() {
    local rc=$?
    # Remove temp files
    [[ -n "${_VSCODE_DEB:-}" ]] && rm -f "$_VSCODE_DEB" 2>/dev/null
    # Release lock
    rmdir "$LOCK_FILE" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        warn "Script exited with code $rc. Re-run to resume from checkpoint."
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# ── Colors (respects NO_COLOR) ───────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

# ── Logging (pipefail-safe: write to file and stdout separately) ──────────────
log() {
    local msg
    msg="$(printf '%s [INFO]  %s' "$(date +%T)" "$*")"
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
    printf '%s\n' "$msg"
}
warn() {
    local msg
    msg="$(printf '%s [WARN]  %s' "$(date +%T)" "$*")"
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
    printf '%s\n' "$msg" >&2
}
err() {
    local msg
    msg="$(printf '%s [ERROR] %s' "$(date +%T)" "$*")"
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
    printf '%s\n' "$msg" >&2
}
die()  { err "$*"; exit 1; }

step_banner() {
    local num="$1" title="$2"
    printf '\n%b══════════════════════════════════════════════════════════════%b\n' "$CYAN" "$RESET"
    printf '%b  STEP %s: %s%b\n' "$BOLD" "$num" "$title" "$RESET"
    printf '%b══════════════════════════════════════════════════════════════%b\n\n' "$CYAN" "$RESET"
}

# ── Checkpoint system ────────────────────────────────────────────────────────
get_checkpoint() {
    if [[ -f "$STEP_FILE" ]]; then
        cat "$STEP_FILE"
    else
        echo 0
    fi
}

set_checkpoint() {
    if $DRY_RUN; then
        log "[DRY-RUN] set checkpoint $1"
        return 0
    fi
    echo "$1" > "$STEP_FILE"
}

should_run_step() {
    local step_num="$1"
    local checkpoint
    checkpoint=$(get_checkpoint)
    [[ "$step_num" -gt "$checkpoint" ]]
}

# ── Dry-run wrapper (pipefail-safe: no tee pipes) ────────────────────────────
# run: execute arguments directly (no eval — safe with user input)
run() {
    if $DRY_RUN; then
        log "[DRY-RUN] $*"
        return 0
    fi
    log "[EXEC] $*"
    "$@" >> "$LOG_FILE" 2>&1
    local rc=$?
    [[ $rc -ne 0 ]] && warn "Command exited $rc: $*"
    return $rc
}

# run_shell: execute a string via bash -c (for pipes/redirects only — never user input)
run_shell() {
    if $DRY_RUN; then
        log "[DRY-RUN] $1"
        return 0
    fi
    log "[EXEC] $1"
    bash -c "$1" >> "$LOG_FILE" 2>&1
    local rc=$?
    [[ $rc -ne 0 ]] && warn "Shell command exited $rc: $1"
    return $rc
}

# write_file: write stdin to a file path, respects dry-run
# Usage: write_file /path/to/file <<'EOF' ... EOF
write_file() {
    local dest="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] write $dest"
        cat > /dev/null  # consume stdin
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cat > "$dest"
    log "Wrote $dest"
}

# write_file_sudo: same but via sudo
write_file_sudo() {
    local dest="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] sudo write $dest"
        cat > /dev/null
        return 0
    fi
    sudo mkdir -p "$(dirname "$dest")"
    sudo tee "$dest" > /dev/null
    log "Wrote $dest (sudo)"
}

# ── ChromeOS URL opener ─────────────────────────────────────────────────────
# garcon-url-handler opens URLs in the ChromeOS browser from inside Crostini.
# Falls back to xdg-open, then prints the URL if neither works.
open_chromeos_url() {
    local url="$1"
    if command -v garcon-url-handler &>/dev/null; then
        garcon-url-handler "$url" 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>/dev/null || true
    else
        warn "Cannot auto-open URL. Manually navigate to: $url"
    fi
}

# ── Usage / Help ─────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Crostini post-install bootstrap for Lenovo Duet 5 Chromebook (ARM64)

USAGE:
    bash ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    --dry-run    Print commands without executing
    --help       Show this help message
    --version    Show version
    --reset      Clear checkpoint and start from step 1

STEPS PERFORMED:
     1  Preflight checks (arch, Crostini, disk, network, root)
     2  ChromeOS integration (GPU flag, microphone, USB, folder sharing,
        port forwarding — auto-opens each settings page)
     3  System update and upgrade
     4  Core CLI utilities
     5  Build essentials and development headers
     6  GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)
     7  Audio stack (ALSA, PulseAudio, GStreamer codecs)
     8  Display scaling and HiDPI (sommelier, GTK3/4, Qt, Xft, fontconfig)
     9  GUI applications (Firefox ESR, Thunar, Evince, fonts, screenshots)
    10  Python ecosystem (python3, pip, venv)
    11  Node.js via NodeSource (LTS, arm64)
    12  Rust via rustup (aarch64)
    13  Git configuration
    14  VS Code (arm64 .deb + Wayland flags)
    15  Container resource tuning (sysctl, locale, env, XDG, paths)
    16  Flatpak + Flathub (ARM64 app source)
    17  SSH key generation
    18  Container backup (auto-opens ChromeOS backup page)
    19  Summary and verification

CHECKPOINT:
    Progress is saved after each step to ${STEP_FILE}.
    Re-run the script to resume from where it left off.
    Use --reset to start over.

LOG:
    Full output is written to ~/crostini-setup-YYYYMMDD-HHMMSS.log
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help)    usage ;;
        --version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
        --reset)   rm -f "$STEP_FILE"; echo "Checkpoint cleared."; exit 0 ;;
        *)         die "Unknown argument: $arg. Use --help for usage." ;;
    esac
done

# ── Acquire exclusive lock (prevents concurrent runs corrupting checkpoint) ──
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    die "Another instance is already running (lock: ${LOCK_FILE}). Remove it manually if stale."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 1: Preflight checks
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 1; then
    step_banner 1 "Preflight checks"

    # 1a. Architecture
    CURRENT_ARCH="$(uname -m)"
    if [[ "$CURRENT_ARCH" != "$EXPECTED_ARCH" ]]; then
        die "Expected architecture ${EXPECTED_ARCH}, got ${CURRENT_ARCH}. This script is for the Duet 5 (ARM64) only."
    fi
    log "Architecture: ${CURRENT_ARCH} ✓"

    # 1b. Crostini container detection
    if [[ -f /dev/.cros_milestone ]]; then
        CROS_VERSION="$(cat /dev/.cros_milestone)"
        log "ChromeOS milestone: ${CROS_VERSION} ✓"
    elif [[ -d /mnt/chromeos ]]; then
        log "Crostini mount point detected ✓"
    else
        warn "Cannot confirm Crostini environment. Proceeding anyway."
    fi

    # 1c. Debian version
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        log "Container OS: ${PRETTY_NAME:-unknown} ✓"
    fi

    # 1d. Disk space check (need at least 2 GB free)
    AVAIL_KB=$(df --output=avail / | tail -1 | tr -d ' ')
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [[ "$AVAIL_MB" -lt 2048 ]]; then
        die "Insufficient disk space: ${AVAIL_MB} MB available, need at least 2048 MB. Resize: Settings → Developers → Linux → Disk size."
    fi
    log "Available disk: ${AVAIL_MB} MB ✓"

    # 1e. Network connectivity
    if $DRY_RUN; then
        log "[DRY-RUN] skip network check"
    elif curl -fsS --max-time 5 https://deb.debian.org/debian/dists/bookworm/Release.gpg -o /dev/null 2>/dev/null; then
        log "Network connectivity: ✓"
    else
        warn "Cannot reach deb.debian.org. Some steps may fail without network."
    fi

    # 1f. Not running as root
    if [[ "$EUID" -eq 0 ]]; then
        die "Do not run this script as root. Run as your normal user (sudo is used internally where needed)."
    fi
    log "Running as user: $(whoami) ✓"

    # 1g. Sommelier (Wayland bridge) — needed for all GUI apps
    if pgrep -x sommelier &>/dev/null; then
        log "Sommelier (Wayland bridge): running ✓"
    else
        warn "Sommelier not detected. GUI apps may not display until container restarts."
    fi

    set_checkpoint 1
    log "Step 1 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 2: ChromeOS integration — auto-open settings for required toggles
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 2; then
    step_banner 2 "ChromeOS integration (GPU, mic, USB, folders, ports)"

    # ── 2a. GPU acceleration ─────────────────────────────────────────────────
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU acceleration: ALREADY ACTIVE ✓"
    else
        log "GPU acceleration not detected. Opening chrome://flags..."
        printf '%b  → The chrome://flags page is opening in ChromeOS now.%b\n' "$YELLOW" "$RESET"
        printf '%b  → Search for "crostini-gpu-support" and set to "Enabled".%b\n' "$YELLOW" "$RESET"
        printf '%b  → A full Chromebook reboot is required for GPU to activate.%b\n' "$YELLOW" "$RESET"
        printf '%b  → GPU packages will be installed now regardless.%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://flags/#crostini-gpu-support"
        sleep 2
        printf '%bPress Enter after enabling the flag (or to continue)...%b' "$YELLOW" "$RESET"
        read -r _
        if [[ -e /dev/dri/renderD128 ]]; then
            log "GPU acceleration now active ✓"
        else
            warn "GPU not yet active — requires full Chromebook reboot. Continuing."
        fi
    fi

    # ── 2b. Microphone access ────────────────────────────────────────────────
    if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
        log "Microphone capture device: detected ✓"
    else
        log "Microphone not detected. Opening Linux settings..."
        printf '%b  → Toggle "Allow Linux to access your microphone" → On%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini"
        sleep 2
        printf '%bPress Enter after enabling microphone (or to continue)...%b' "$YELLOW" "$RESET"
        read -r _
        if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
            log "Microphone now available ✓"
        else
            warn "Microphone still not detected. May need container restart."
        fi
    fi

    # ── 2c. USB device passthrough ───────────────────────────────────────────
    log "Opening USB device management..."
    printf '%b  → Toggle on any USB devices you need (drives, Arduino, etc.)%b\n\n' "$YELLOW" "$RESET"
    open_chromeos_url "chrome://os-settings/crostini/usbPreferences"
    sleep 2
    printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
    read -r _

    # ── 2d. Shared folders ───────────────────────────────────────────────────
    if [[ -d /mnt/chromeos ]]; then
        SHARED_COUNT=$(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d 2>/dev/null | wc -l)
        if [[ "$SHARED_COUNT" -gt 0 ]]; then
            log "Shared ChromeOS folders: ${SHARED_COUNT} detected ✓"
        else
            log "No shared folders. Opening shared paths settings..."
            printf '%b  → Click "Share folder" to make ChromeOS folders visible at /mnt/chromeos/%b\n\n' "$YELLOW" "$RESET"
            open_chromeos_url "chrome://os-settings/crostini/sharedPaths"
            sleep 2
            printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
            read -r _
        fi
    fi

    # ── 2e. Port forwarding ──────────────────────────────────────────────────
    log "Opening port forwarding settings..."
    printf '%b  → Add any dev server ports (3000, 5000, 8080, etc.)%b\n' "$YELLOW" "$RESET"
    printf '%b  → Crostini also auto-detects listening ports in most cases.%b\n\n' "$YELLOW" "$RESET"
    open_chromeos_url "chrome://os-settings/crostini/portForwarding"
    sleep 2
    printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
    read -r _

    # ── 2f. Disk size check ──────────────────────────────────────────────────
    AVAIL_MB_NOW=$(($(df --output=avail / | tail -1 | tr -d ' ') / 1024))
    if [[ "$AVAIL_MB_NOW" -lt 10240 ]]; then
        log "Disk under 10 GB free. Opening disk resize settings..."
        printf '%b  → Consider increasing Linux disk allocation (20–30 GB recommended).%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini"
        sleep 2
        printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r _
    else
        log "Disk space: ${AVAIL_MB_NOW} MB free — adequate"
    fi

    set_checkpoint 2
    log "Step 2 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 3: System update and upgrade
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 3; then
    step_banner 3 "System update and upgrade"

    run sudo apt update || warn "apt update failed"
    run sudo apt upgrade -y || warn "apt upgrade had issues"
    run sudo apt autoremove -y || true

    set_checkpoint 3
    log "Step 3 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 4: Core CLI utilities
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 4; then
    step_banner 4 "Core CLI utilities"

    CORE_PKGS=(
        # Navigation and file management
        file tree zip unzip p7zip-full rsync rename

        # Text processing
        nano vim less jq

        # Network utilities
        curl wget dnsutils netcat-openbsd openssh-client
        ca-certificates gnupg

        # System monitoring
        htop ncdu lsof strace

        # Search and filtering
        ripgrep fd-find fzf bat

        # Misc
        tmux screen man-db bash-completion locales
        software-properties-common
    )

    run sudo apt install -y "${CORE_PKGS[@]}" || warn "Some core packages failed to install — continuing"

    # Create common symlinks for renamed Debian packages
    if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        run sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
        log "Symlinked fdfind → fd"
    fi
    if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        run sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
        log "Symlinked batcat → bat"
    fi

    set_checkpoint 4
    log "Step 4 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 5: Build essentials and development headers
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 5; then
    step_banner 5 "Build essentials and development headers"

    DEV_PKGS=(
        build-essential gcc g++ make cmake pkg-config
        autoconf automake libtool
        libssl-dev libffi-dev zlib1g-dev libbz2-dev
        libreadline-dev libsqlite3-dev libncurses-dev
        libxml2-dev libxslt1-dev liblzma-dev libgdbm-dev
    )

    run sudo apt install -y "${DEV_PKGS[@]}" || warn "Some dev packages failed to install — continuing"

    set_checkpoint 5
    log "Step 5 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 6: GPU + graphics stack
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 6; then
    step_banner 6 "GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)"

    GPU_PKGS=(
        # Mesa drivers — virgl is the paravirtualized GPU Crostini uses
        mesa-utils
        mesa-vulkan-drivers
        libgl1-mesa-dri
        libgl1                  # replaces transitional libgl1-mesa-glx
        libegl1-mesa
        libgles2-mesa

        # Vulkan loader + tools
        libvulkan1
        vulkan-tools

        # Wayland client libs (Crostini uses Wayland via sommelier)
        libwayland-client0
        libwayland-egl1

        # X11 compatibility — sommelier provides XWayland, so do NOT install
        # the standalone xwayland package (it conflicts with sommelier's bridge).
        x11-utils
        x11-xserver-utils
        xdg-desktop-portal
        xdg-desktop-portal-gtk

        # GL benchmark/test tools
        glmark2
        glmark2-wayland
        glmark2-es2-wayland
    )

    # Install what's available — some packages differ across Debian versions
    for pkg in "${GPU_PKGS[@]}"; do
        run sudo apt install -y "$pkg" || warn "Skipped unavailable: $pkg"
    done

    # Verify GPU
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU render node: /dev/dri/renderD128 ✓"
        if command -v glxinfo &>/dev/null; then
            GL_VENDOR="$(glxinfo 2>/dev/null | grep "OpenGL vendor" | head -1 | cut -d: -f2 | xargs || true)"
            GL_RENDERER="$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1 | cut -d: -f2 | xargs || true)"
            GL_VERSION="$(glxinfo 2>/dev/null | grep "OpenGL version" | head -1 | cut -d: -f2 | xargs || true)"
            log "GL vendor:   ${GL_VENDOR:-unknown}"
            log "GL renderer: ${GL_RENDERER:-unknown}"
            log "GL version:  ${GL_VERSION:-unknown}"
        fi
    else
        warn "GPU render node not present. Requires chrome://flags toggle + full reboot."
        warn "Packages are installed — GPU will work automatically after reboot."
    fi

    # GPU environment variables
    GPU_ENV_FILE="${HOME}/.config/environment.d/gpu.conf"
    if [[ ! -f "$GPU_ENV_FILE" ]]; then
        write_file "$GPU_ENV_FILE" <<'EOF'
# Crostini GPU acceleration environment
# Prefer Wayland for GTK apps (sommelier handles the bridge)
GDK_BACKEND=wayland,x11
# Do NOT set MESA_LOADER_DRIVER_OVERRIDE — the driver name varies
# across Crostini versions (virtio_gpu vs virtio-gpu). Let Mesa
# auto-detect the correct driver from /dev/dri.
# Enable DRI3
LIBGL_DRI3_DISABLE=0
# Wayland EGL
EGL_PLATFORM=wayland
EOF
    else
        log "GPU env already exists — skipping"
    fi

    set_checkpoint 6
    log "Step 6 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 7: Audio stack
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 7; then
    step_banner 7 "Audio stack (ALSA, PulseAudio, GStreamer codecs)"

    AUDIO_PKGS=(
        # ALSA
        alsa-utils
        libasound2
        libasound2-plugins

        # PulseAudio CLIENT only — Crostini bridges audio from the ChromeOS
        # host via a PulseAudio socket. Do NOT install the pulseaudio daemon
        # package; it would start a conflicting server inside the container.
        pulseaudio-utils
        pavucontrol             # GUI volume mixer

        # GStreamer codecs and media support
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-pulseaudio
        gstreamer1.0-alsa
        libavcodec-extra
    )

    for pkg in "${AUDIO_PKGS[@]}"; do
        run sudo apt install -y "$pkg" || warn "Skipped unavailable: $pkg"
    done

    # PulseAudio config — point to Crostini host socket
    PA_CLIENT="${HOME}/.config/pulse/client.conf"
    if [[ ! -f "$PA_CLIENT" ]]; then
        write_file "$PA_CLIENT" <<EOF
# Crostini PulseAudio — connect to host audio server
default-server = unix:/run/user/${CROS_UID}/pulse/native
autospawn = no
EOF
    else
        log "PulseAudio client config already exists"
    fi

    # Verify audio
    if [[ -d /dev/snd ]]; then
        SND_DEVICES=$(find /dev/snd -maxdepth 1 -not -name snd 2>/dev/null | wc -l)
        log "Audio devices in /dev/snd: ${SND_DEVICES} ✓"
        if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
            log "Microphone capture device: detected ✓"
        else
            warn "No capture device. Enable mic: Settings → Developers → Linux → Microphone"
        fi
    else
        warn "/dev/snd not found. Audio may not work until container restart."
    fi

    # Audio environment
    AUDIO_ENV_FILE="${HOME}/.config/environment.d/audio.conf"
    if [[ ! -f "$AUDIO_ENV_FILE" ]]; then
        write_file "$AUDIO_ENV_FILE" <<EOF
# Crostini audio environment
PULSE_SERVER=unix:/run/user/${CROS_UID}/pulse/native
EOF
    else
        log "Audio env already exists — skipping"
    fi

    set_checkpoint 7
    log "Step 7 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 8: Display scaling and HiDPI configuration
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 8; then
    step_banner 8 "Display scaling and HiDPI (sommelier, GTK, Qt, Xft, fontconfig)"

    # The Duet 5 has a 13.3" 1920x1080 OLED. At that size, the default
    # Linux DPI (96) makes everything tiny. We configure every rendering
    # layer: sommelier, GTK3, GTK4, Qt, Xft, and fontconfig.

    # ── 8a. Sommelier environment (controls Linux app scaling) ───────────────
    SOMMELIER_ENV="${HOME}/.config/environment.d/sommelier.conf"
    # write_file handles mkdir
    if [[ ! -f "$SOMMELIER_ENV" ]]; then
        write_file "$SOMMELIER_ENV" <<'EOF'
# Sommelier display scaling for Crostini
# SOMMELIER_SCALE adjusts Linux app window scaling:
#   1.0 = native (let ChromeOS handle scaling — recommended for FHD)
#   0.5 = 2x magnification (for 4K displays)
SOMMELIER_SCALE=1.0

# Do NOT hardcode DISPLAY or WAYLAND_DISPLAY here —
# Crostini/sommelier sets these dynamically and overriding
# them can break GUI apps if the display number changes.
EOF
    else
        log "Sommelier env already exists — skipping"
    fi

    # ── 8b. GTK 3 settings ──────────────────────────────────────────────────
    GTK3_DIR="${HOME}/.config/gtk-3.0"
    GTK3_SETTINGS="${GTK3_DIR}/settings.ini"
    # write_file handles mkdir
    if [[ ! -f "$GTK3_SETTINGS" ]]; then
        write_file "$GTK3_SETTINGS" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Noto Sans 11
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=none
gtk-overlay-scrolling=1
EOF
    else
        log "GTK 3 settings.ini already exists — skipping"
    fi

    # ── 8c. GTK 4 settings ──────────────────────────────────────────────────
    GTK4_DIR="${HOME}/.config/gtk-4.0"
    GTK4_SETTINGS="${GTK4_DIR}/settings.ini"
    # write_file handles mkdir
    if [[ ! -f "$GTK4_SETTINGS" ]]; then
        write_file "$GTK4_SETTINGS" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Noto Sans 11
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=none
EOF
    else
        log "GTK 4 settings.ini already exists — skipping"
    fi

    # ── 8d. GTK 2 settings (legacy apps) ─────────────────────────────────────
    GTK2_RC="${HOME}/.gtkrc-2.0"
    if [[ ! -f "$GTK2_RC" ]]; then
        write_file "$GTK2_RC" <<'EOF'
# GTK 2 theme settings for legacy apps
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Adwaita"
gtk-font-name="Noto Sans 11"
gtk-cursor-theme-name="Adwaita"
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle="hintslight"
gtk-xft-rgba="none"
EOF
    else
        log ".gtkrc-2.0 already exists — skipping"
    fi

    # ── 8e. Qt scaling and theming ───────────────────────────────────────────
    QT_ENV="${HOME}/.config/environment.d/qt.conf"
    # write_file handles mkdir
    if [[ ! -f "$QT_ENV" ]]; then
        write_file "$QT_ENV" <<'EOF'
# Qt HiDPI and theming
QT_AUTO_SCREEN_SCALE_FACTOR=1
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
QT_QPA_PLATFORMTHEME=gtk3
EOF
    else
        log "Qt env already exists — skipping"
    fi

    # Install Qt5 GTK platform theme so Qt apps follow GTK dark theme
    run sudo apt install -y qt5ct || true
    run sudo apt install -y qt5-gtk-platformtheme || \
        run sudo apt install -y qt5-style-plugins || \
        warn "Qt GTK theme package not available — Qt apps may not follow dark theme"

    # ── 8f. Xft / Xresources (for pure X11 apps) ────────────────────────────
    XRESOURCES="${HOME}/.Xresources"
    if [[ ! -f "$XRESOURCES" ]]; then
        write_file "$XRESOURCES" <<'EOF'
! Font rendering for X11 apps on Duet 5 (13.3" 1920x1080 OLED)
! OLED has no LCD subpixel stripe — use grayscale AA (rgba=none)
Xft.dpi: 120
Xft.antialias: true
Xft.hinting: true
Xft.hintstyle: hintslight
Xft.rgba: none
! Cursor
Xcursor.size: 24
Xcursor.theme: Adwaita
EOF
    else
        log ".Xresources already exists — skipping"
    fi
    # Apply Xresources
    if command -v xrdb &>/dev/null; then
        run xrdb -merge "$XRESOURCES" || true
        log "Xresources merged"
    fi

    # ── 8g. Fontconfig (grayscale AA for OLED, Noto defaults) ────────────────
    FC_LOCAL="${HOME}/.config/fontconfig/fonts.conf"
    # write_file handles mkdir
    if [[ ! -f "$FC_LOCAL" ]]; then
        write_file "$FC_LOCAL" <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- Grayscale antialiasing for OLED display (no LCD subpixel stripe) -->
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>none</const></edit>
  </match>
  <!-- Default sans-serif -->
  <alias>
    <family>sans-serif</family>
    <prefer><family>Noto Sans</family></prefer>
  </alias>
  <!-- Default serif -->
  <alias>
    <family>serif</family>
    <prefer><family>Noto Serif</family></prefer>
  </alias>
  <!-- Default monospace -->
  <alias>
    <family>monospace</family>
    <prefer><family>Fira Code</family><family>Noto Sans Mono</family></prefer>
  </alias>
</fontconfig>
FCEOF
    else
        log "Fontconfig already exists — skipping"
    fi
    if command -v fc-cache &>/dev/null; then
        run fc-cache -f 2>/dev/null || true
        log "Font cache rebuilt"
    fi

    # ── 8h. Cursor theme (ensure consistency across toolkits) ────────────────
    CURSOR_DIR="${HOME}/.icons/default"
    # write_file handles mkdir
    if [[ ! -f "${CURSOR_DIR}/index.theme" ]]; then
        write_file "${CURSOR_DIR}/index.theme" <<'EOF'
[Icon Theme]
Inherits=Adwaita
EOF
    else
        log "Cursor theme already exists — skipping"
    fi

    set_checkpoint 8
    log "Step 8 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 9: GUI application essentials
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 9; then
    step_banner 9 "GUI applications (Firefox, Thunar, fonts, screenshots)"

    GUI_PKGS=(
        firefox-esr
        thunar                  # Lightweight file manager
        thunar-archive-plugin   # Archive support in Thunar
        tumbler                 # Thumbnail service for Thunar
        evince                  # PDF viewer
        eog                     # Image viewer (Eye of GNOME)
        gnome-calculator
        gnome-screenshot        # Screenshot tool
        gnome-disk-utility      # Disk management
        file-roller             # Archive manager
        xdg-utils
        dbus-x11                # D-Bus for X11 session
        at-spi2-core            # Accessibility (suppresses GTK warnings)
        libnotify-bin           # Desktop notifications (notify-send)

        # Fonts — comprehensive set for international content
        fonts-noto
        fonts-noto-cjk
        fonts-noto-color-emoji
        fonts-noto-mono
        fonts-liberation
        fonts-firacode
        fonts-hack
        adwaita-icon-theme
    )

    for pkg in "${GUI_PKGS[@]}"; do
        run sudo apt install -y "$pkg" || warn "Skipped unavailable: $pkg"
    done

    # Try to install full icon theme (may not exist on all versions)
    run sudo apt install -y adwaita-icon-theme-full || true

    # Set Firefox ESR as default browser
    if command -v firefox-esr &>/dev/null; then
        run sudo update-alternatives --set x-www-browser /usr/bin/firefox-esr 2>/dev/null || true
        log "Firefox ESR set as default browser"
    fi

    # Set default file manager
    if command -v thunar &>/dev/null; then
        run xdg-mime default thunar.desktop inode/directory 2>/dev/null || true
        log "Thunar set as default file manager"
    fi

    # Set default PDF viewer
    if command -v evince &>/dev/null; then
        run xdg-mime default org.gnome.Evince.desktop application/pdf 2>/dev/null || true
        log "Evince set as default PDF viewer"
    fi

    # Set default image viewer
    if command -v eog &>/dev/null; then
        run xdg-mime default org.gnome.eog.desktop image/png 2>/dev/null || true
        run xdg-mime default org.gnome.eog.desktop image/jpeg 2>/dev/null || true
        log "Eye of GNOME set as default image viewer"
    fi

    # Ensure desktop applications directory exists (garcon integration)
    run mkdir -p "${HOME}/.local/share/applications"
    log "Desktop applications directory: ${HOME}/.local/share/applications ✓"

    set_checkpoint 9
    log "Step 9 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 10: Python ecosystem
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 10; then
    step_banner 10 "Python ecosystem"

    run sudo apt install -y python3 python3-pip python3-venv python3-dev python3-setuptools python3-wheel \
        || warn "Some Python packages failed — continuing"

    run mkdir -p "${HOME}/.local/bin"

    log "Python version: $(python3 --version 2>&1)"
    log "pip version: $(python3 -m pip --version 2>&1)"

    set_checkpoint 10
    log "Step 10 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 11: Node.js via NodeSource (LTS, arm64)
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 11; then
    step_banner 11 "Node.js LTS (arm64)"

    if command -v node &>/dev/null; then
        log "Node.js already installed: $(node --version)"
    else
        readonly NODE_MAJOR=22
        log "Installing Node.js ${NODE_MAJOR}.x LTS from NodeSource..."

        run sudo mkdir -p /etc/apt/keyrings
        run_shell "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg"
        run_shell "echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main' | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null"
        run sudo apt update  || warn "apt update failed"
        run sudo apt install -y nodejs || die "nodejs install failed — check NodeSource repo setup above"
    fi

    # Configure npm global prefix to avoid sudo for global installs
    NPM_GLOBAL="${HOME}/.npm-global"
    if command -v npm &>/dev/null; then
        run mkdir -p "$NPM_GLOBAL"
        run npm config set prefix "${NPM_GLOBAL}"
        log "npm global prefix set to ${NPM_GLOBAL}"
    fi

    log "Node version: $(node --version 2>&1 || echo 'not installed')"
    log "npm version: $(npm --version 2>&1 || echo 'not installed')"

    set_checkpoint 11
    log "Step 11 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 12: Rust via rustup (aarch64)
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 12; then
    step_banner 12 "Rust toolchain (aarch64)"

    if command -v rustc &>/dev/null; then
        log "Rust already installed: $(rustc --version)"
    else
        log "Installing Rust via rustup (non-interactive)..."
        run_shell "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable"

        if [[ -f "${HOME}/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "${HOME}/.cargo/env"
        fi
    fi

    log "rustc version: $(rustc --version 2>&1 || echo 'not installed')"
    log "cargo version: $(cargo --version 2>&1 || echo 'not installed')"

    set_checkpoint 12
    log "Step 12 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 13: Git configuration
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 13; then
    step_banner 13 "Git configuration"

    run sudo apt install -y git git-lfs || warn "git install had issues"

    CURRENT_NAME="$(git config --global user.name 2>/dev/null || true)"
    CURRENT_EMAIL="$(git config --global user.email 2>/dev/null || true)"

    if [[ -z "$CURRENT_NAME" ]]; then
        printf '%bEnter your Git name (e.g. Ryan Musante): %b' "$YELLOW" "$RESET"
        read -r GIT_NAME
        if [[ -n "$GIT_NAME" ]]; then
            run git config --global user.name "${GIT_NAME}"
        fi
    else
        log "Git user.name already set: ${CURRENT_NAME}"
    fi

    if [[ -z "$CURRENT_EMAIL" ]]; then
        printf '%bEnter your Git email: %b' "$YELLOW" "$RESET"
        read -r GIT_EMAIL
        if [[ -n "$GIT_EMAIL" ]]; then
            run git config --global user.email "${GIT_EMAIL}"
        fi
    else
        log "Git user.email already set: ${CURRENT_EMAIL}"
    fi

    run git config --global init.defaultBranch main
    run git config --global pull.rebase true
    run git config --global core.autocrlf input
    run git config --global core.editor vim
    run git config --global color.ui auto
    run git config --global push.autoSetupRemote true
    run git lfs install

    log "Git version: $(git --version 2>&1)"

    set_checkpoint 13
    log "Step 13 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 14: VS Code (arm64 .deb)
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 14; then
    step_banner 14 "Visual Studio Code (arm64)"

    if command -v code &>/dev/null; then
        log "VS Code already installed: $(code --version 2>&1 | head -1)"
    else
        log "Downloading VS Code arm64 .deb..."
        _VSCODE_DEB="$(mktemp /tmp/vscode-arm64-XXXXXX.deb)"
        run curl -fSL "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-arm64" -o "${_VSCODE_DEB}"

        if [[ -f "$_VSCODE_DEB" ]]; then
            run sudo dpkg -i "$_VSCODE_DEB" || run sudo apt install -f -y
            run rm -f "$_VSCODE_DEB"
            log "VS Code installed ✓"
        else
            warn "VS Code download failed. Install manually:"
            warn "  https://code.visualstudio.com/download (select ARM64 .deb)"
        fi
    fi

    # VS Code Wayland flags for better rendering on Crostini
    VSCODE_FLAGS="${HOME}/.config/code-flags.conf"
    if [[ ! -f "$VSCODE_FLAGS" ]]; then
        write_file "$VSCODE_FLAGS" <<'EOF'
--enable-features=UseOzonePlatform,WaylandWindowDecorations
--ozone-platform=wayland
EOF
    else
        log "VS Code flags already exist"
    fi

    set_checkpoint 14
    log "Step 14 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 15: Container resource tuning
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 15; then
    step_banner 15 "Container resource tuning (sysctl, locale, env, paths)"

    # 15a. Increase inotify watchers (VS Code and file-heavy tools need this)
    readonly SYSCTL_CONF="/etc/sysctl.d/99-crostini-tuning.conf"
    if [[ ! -f "$SYSCTL_CONF" ]]; then
        run_shell "echo 'fs.inotify.max_user_watches=524288' | sudo tee '${SYSCTL_CONF}' > /dev/null"
        run sudo sysctl --system || warn "sysctl apply failed"
        log "inotify watchers increased to 524288"
    else
        log "sysctl tuning already applied"
    fi

    # 15b. Set locale to en_US.UTF-8
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        run sudo sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
        run sudo locale-gen || warn "locale-gen failed"
        log "en_US.UTF-8 locale generated"
    else
        log "en_US.UTF-8 locale already available"
    fi

    # 15c. Master environment profile (shell-agnostic via /etc/profile.d)
    PROFILE_D="/etc/profile.d/crostini-env.sh"
    if [[ ! -f "$PROFILE_D" ]]; then
        write_file_sudo "$PROFILE_D" <<'ENVEOF'
# Crostini environment defaults — managed by crostini-setup-duet5.sh
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export EDITOR="vim"
export VISUAL="vim"
export PAGER="less"
export LESS="-R -F -X"

# Cargo/Rust
if [ -d "$HOME/.cargo/bin" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
fi

# Local bin (pip, user scripts)
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# npm global
if [ -d "$HOME/.npm-global/bin" ]; then
    export PATH="$HOME/.npm-global/bin:$PATH"
fi
ENVEOF
        run sudo chmod 644 "$PROFILE_D"
        log "Environment defaults written to ${PROFILE_D}"
    else
        log "Environment profile already exists"
    fi

    # 15d. Memory tuning for 4 GB device
    # NOTE: vm.swappiness, vm.vfs_cache_pressure, vm.dirty_ratio, and
    # vm.dirty_background_ratio are NOT namespace-aware. In Crostini's
    # unprivileged LXC container they are read-only — only the termina
    # VM kernel can change them. We test writability before applying.
    MEM_CONF="/etc/sysctl.d/99-crostini-memory.conf"
    if [[ ! -f "$MEM_CONF" ]]; then
        if [[ -w /proc/sys/vm/swappiness ]]; then
            write_file_sudo "$MEM_CONF" <<'MEMEOF'
# Memory tuning for 4 GB Duet 5 — managed by crostini-setup-duet5.sh
# Lower swappiness: prefer keeping pages in RAM over swapping
vm.swappiness=10
# More aggressive page cache reclaim under memory pressure
vm.vfs_cache_pressure=150
# Lower dirty ratio thresholds — flush writes earlier on low-RAM device
vm.dirty_ratio=10
vm.dirty_background_ratio=5
MEMEOF
            run sudo chmod 644 "$MEM_CONF"
            run sudo sysctl --system || warn "memory sysctl apply failed"
        else
            warn "vm.swappiness is read-only in this container (expected in Crostini)"
            warn "Memory tuning requires host-level (termina VM) access — skipping"
        fi
    else
        log "Memory tuning config already exists"
    fi

    # 15e. Ensure XDG dirs exist
    run mkdir -p "${HOME}/.local/share" "${HOME}/.local/bin" "${HOME}/.config" "${HOME}/.cache"
    if command -v xdg-user-dirs-update &>/dev/null; then
        run xdg-user-dirs-update
        log "XDG user directories updated"
    fi

    set_checkpoint 15
    log "Step 15 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 16: Flatpak + Flathub
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 16; then
    step_banner 16 "Flatpak + Flathub (ARM64 app source)"

    run sudo apt install -y flatpak || warn "flatpak install failed"
    run sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    log "Flatpak installed with Flathub remote."
    log "Install apps: flatpak install flathub <app-id>"

    set_checkpoint 16
    log "Step 16 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 17: SSH key generation
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 17; then
    step_banner 17 "SSH key generation"

    SSH_KEY="${HOME}/.ssh/id_ed25519"
    if [[ -f "$SSH_KEY" ]]; then
        log "SSH key already exists at ${SSH_KEY}"
    else
        printf '%bGenerate an Ed25519 SSH key? [Y/n]: %b' "$YELLOW" "$RESET"
        read -r GEN_SSH

        if [[ "${GEN_SSH,,}" != "n" ]]; then
            printf '%bEmail for SSH key comment (blank for none): %b' "$YELLOW" "$RESET"
            read -r SSH_COMMENT

            run mkdir -p "${HOME}/.ssh"
            run chmod 700 "${HOME}/.ssh"

            if [[ -n "$SSH_COMMENT" ]]; then
                run ssh-keygen -t ed25519 -C "${SSH_COMMENT}" -f "$SSH_KEY" -N ""
            else
                run ssh-keygen -t ed25519 -f "$SSH_KEY" -N ""
            fi

            if [[ -f "$SSH_KEY" ]]; then
                run chmod 600 "$SSH_KEY"
                run chmod 644 "${SSH_KEY}.pub"

                log "SSH public key:"
                tee -a "$LOG_FILE" < "${SSH_KEY}.pub"
                printf '\n'
                log "Add to GitHub/GitLab/servers as needed."
            fi
        else
            log "Skipping SSH key generation"
        fi
    fi

    set_checkpoint 17
    log "Step 17 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 18: Container backup — auto-opens ChromeOS backup page
# ═════════════════════════════════════════════════════════════════════════════
if should_run_step 18; then
    step_banner 18 "Container backup"

    log "Opening ChromeOS backup page to snapshot this fresh setup..."
    printf '%b  → Click "Backup" to save your Linux container state.%b\n' "$YELLOW" "$RESET"
    printf '%b  → Do this periodically after major changes.%b\n\n' "$YELLOW" "$RESET"
    open_chromeos_url "chrome://os-settings/crostini/exportImport"
    sleep 2
    printf '%bPress Enter after backup completes (or to skip)...%b' "$YELLOW" "$RESET"
    read -r _

    set_checkpoint 18
    log "Step 18 complete."
fi


# ═════════════════════════════════════════════════════════════════════════════
#  STEP 19: Summary and verification
# ═════════════════════════════════════════════════════════════════════════════
step_banner 19 "Summary and verification"

printf '%b┌──────────────────────────────────────────────────────────┐%b\n' "$GREEN" "$RESET"
printf '%b│              CROSTINI SETUP COMPLETE                     │%b\n' "$GREEN" "$RESET"
printf '%b└──────────────────────────────────────────────────────────┘%b\n' "$GREEN" "$RESET"
printf '\n'

# ── System ───────────────────────────────────────────────────────────────────
printf '%bSystem:%b\n' "$BOLD" "$RESET"
printf '  Architecture:  %s\n' "$(uname -m)"
printf '  Kernel:        %s\n' "$(uname -r)"
printf '  OS:            %s\n' "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
printf '  Disk free:     %s MB\n' "$(($(df --output=avail / | tail -1 | tr -d ' ') / 1024))"
printf '\n'

# ── GPU ──────────────────────────────────────────────────────────────────────
printf '%bGPU / Graphics:%b\n' "$BOLD" "$RESET"
if [[ -e /dev/dri/renderD128 ]]; then
    printf '  Render node:   %b✓%b /dev/dri/renderD128\n' "$GREEN" "$RESET"
    if command -v glxinfo &>/dev/null; then
        GL_VENDOR="$(glxinfo 2>/dev/null | grep "OpenGL vendor" | head -1 | cut -d: -f2 | xargs || true)"
        GL_RENDERER="$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1 | cut -d: -f2 | xargs || true)"
        GL_VERSION="$(glxinfo 2>/dev/null | grep "OpenGL version" | head -1 | cut -d: -f2 | xargs || true)"
        [[ -n "$GL_VENDOR" ]]   && printf '  GL vendor:     %s\n' "$GL_VENDOR"
        [[ -n "$GL_RENDERER" ]] && printf '  GL renderer:   %s\n' "$GL_RENDERER"
        [[ -n "$GL_VERSION" ]]  && printf '  GL version:    %s\n' "$GL_VERSION"
    fi
    if command -v vulkaninfo &>/dev/null; then
        VK_GPU="$(vulkaninfo --summary 2>/dev/null | grep "GPU name" | head -1 | cut -d= -f2 | xargs || true)"
        VK_API="$(vulkaninfo --summary 2>/dev/null | grep "apiVersion" | head -1 | cut -d= -f2 | xargs || true)"
        if [[ -n "$VK_GPU" ]]; then
            printf '  Vulkan GPU:    %s\n' "$VK_GPU"
            [[ -n "$VK_API" ]] && printf '  Vulkan API:    %s\n' "$VK_API"
        else
            printf '  Vulkan:        not available (virgl does not support Vulkan)\n'
        fi
    fi
elif [[ -d /dev/dri ]]; then
    printf '  Render node:   %b⚠ PARTIAL%b (/dev/dri exists, renderD128 missing)\n' "$YELLOW" "$RESET"
else
    printf '  Render node:   %b✗ NOT ACTIVE%b\n' "$RED" "$RESET"
    printf '  Fix:           chrome://flags/#crostini-gpu-support → Enabled → Reboot\n'
fi
printf '\n'

# ── Display ──────────────────────────────────────────────────────────────────
printf '%bDisplay / Wayland:%b\n' "$BOLD" "$RESET"
if pgrep -x sommelier &>/dev/null; then
    printf '  Sommelier:     %b✓%b running\n' "$GREEN" "$RESET"
else
    printf '  Sommelier:     %b✗%b not running — restart terminal\n' "$RED" "$RESET"
fi
printf '  DISPLAY:       %s\n' "${DISPLAY:-not set}"
printf '  WAYLAND:       %s\n' "${WAYLAND_DISPLAY:-not set}"
printf '  GTK theme:     %s\n' "$(grep gtk-theme-name "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | cut -d= -f2 || echo 'default')"
printf '  Xft DPI:       %s\n' "$(grep 'Xft.dpi' "${HOME}/.Xresources" 2>/dev/null | awk '{print $2}' || echo 'default')"
printf '  Font:          %s\n' "$(grep gtk-font-name "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | cut -d= -f2 || echo 'default')"
printf '\n'

# ── Audio ────────────────────────────────────────────────────────────────────
printf '%bAudio:%b\n' "$BOLD" "$RESET"
if [[ -d /dev/snd ]]; then
    SND_DEV_COUNT=$(find /dev/snd -maxdepth 1 -not -name snd 2>/dev/null | wc -l)
    printf '  ALSA devices:  %b✓%b %s device(s)\n' "$GREEN" "$RESET" "$SND_DEV_COUNT"
else
    printf '  ALSA devices:  %b✗%b /dev/snd not found\n' "$RED" "$RESET"
fi
if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
    printf '  Microphone:    %b✓%b capture device present\n' "$GREEN" "$RESET"
else
    printf '  Microphone:    %b✗%b not detected — enable in ChromeOS Linux settings\n' "$YELLOW" "$RESET"
fi
if command -v pactl &>/dev/null; then
    PA_STATUS="$(pactl info 2>/dev/null | grep "Server Name" | cut -d: -f2 | xargs || true)"
    if [[ -n "$PA_STATUS" ]]; then
        printf '  PulseAudio:    %b✓%b %s\n' "$GREEN" "$RESET" "$PA_STATUS"
    else
        printf '  PulseAudio:    %b⚠%b installed but not responding\n' "$YELLOW" "$RESET"
    fi
fi
printf '\n'

# ── ChromeOS integration ────────────────────────────────────────────────────
printf '%bChromeOS integration:%b\n' "$BOLD" "$RESET"
if [[ -d /mnt/chromeos ]]; then
    SHARED_DIRS=$(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d 2>/dev/null)
    SHARED_N=$(echo "$SHARED_DIRS" | grep -c . 2>/dev/null || echo 0)
    if [[ "$SHARED_N" -gt 0 ]]; then
        printf '  Shared dirs:   %b✓%b %s folder(s)\n' "$GREEN" "$RESET" "$SHARED_N"
        echo "$SHARED_DIRS" | while read -r d; do
            [[ -n "$d" ]] && printf '                 └ %s\n' "$d"
        done
    else
        printf '  Shared dirs:   none — share via Files app → right-click → Share with Linux\n'
    fi
fi
printf '\n'

# ── Installed tools ──────────────────────────────────────────────────────────
printf '%bInstalled tools:%b\n' "$BOLD" "$RESET"

check_tool() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>&1 | head -1)
        printf '  %-14s %b✓%b  %s\n' "$name" "$GREEN" "$RESET" "$ver"
    else
        printf '  %-14s %b✗%b  not found\n' "$name" "$RED" "$RESET"
    fi
}

check_tool "git"         git
check_tool "python3"     python3
check_tool "pip"         pip3
check_tool "node"        node
check_tool "npm"         npm
check_tool "rustc"       rustc
check_tool "cargo"       cargo
check_tool "vim"         vim
check_tool "curl"        curl
check_tool "ripgrep"     rg
check_tool "fd"          fd
check_tool "fzf"         fzf
check_tool "bat"         bat
check_tool "tmux"        tmux
check_tool "jq"          jq
check_tool "glxinfo"     glxinfo
check_tool "glmark2"     glmark2
check_tool "vulkaninfo"  vulkaninfo
check_tool "pactl"       pactl
check_tool "pavucontrol" pavucontrol
check_tool "flatpak"     flatpak
check_tool "code"        code
check_tool "firefox-esr" firefox-esr
check_tool "thunar"      thunar
check_tool "evince"      evince
check_tool "eog"         eog
check_tool "file-roller" file-roller
check_tool "gnome-screenshot" gnome-screenshot
printf '\n'

# ── Config files ─────────────────────────────────────────────────────────────
printf '%bConfig files written:%b\n' "$BOLD" "$RESET"

check_config() {
    local path="$1" desc="$2"
    if [[ -f "$path" ]]; then
        printf '  %b✓%b  %-44s %s\n' "$GREEN" "$RESET" "$desc" "$path"
    else
        printf '  %b✗%b  %-44s %s\n' "$RED" "$RESET" "$desc" "$path"
    fi
}

check_config "${HOME}/.config/environment.d/gpu.conf"       "GPU env"
check_config "${HOME}/.config/environment.d/audio.conf"      "Audio env"
check_config "${HOME}/.config/environment.d/sommelier.conf"  "Sommelier scaling"
check_config "${HOME}/.config/environment.d/qt.conf"         "Qt scaling/theming"
check_config "${HOME}/.config/gtk-3.0/settings.ini"          "GTK 3 theme + fonts"
check_config "${HOME}/.config/gtk-4.0/settings.ini"          "GTK 4 theme + fonts"
check_config "${HOME}/.gtkrc-2.0"                            "GTK 2 theme (legacy)"
check_config "${HOME}/.Xresources"                           "Xft DPI + rendering"
check_config "${HOME}/.config/fontconfig/fonts.conf"         "Fontconfig OLED AA"
check_config "${HOME}/.icons/default/index.theme"            "Cursor theme"
check_config "${HOME}/.config/pulse/client.conf"             "PulseAudio client"
check_config "/etc/profile.d/crostini-env.sh"                "Shell env + PATH"
check_config "/etc/sysctl.d/99-crostini-tuning.conf"         "inotify watchers"
if [[ -f "/etc/sysctl.d/99-crostini-memory.conf" ]]; then
    check_config "/etc/sysctl.d/99-crostini-memory.conf"     "Memory tuning (4 GB)"
else
    printf '  %b⚠%b  %-44s %s\n' "$YELLOW" "$RESET" "Memory tuning (4 GB)" "skipped (vm.* read-only in container)"
fi
if command -v code &>/dev/null; then
    check_config "${HOME}/.config/code-flags.conf"           "VS Code Wayland"
fi
printf '\n'

# ── Quick-test commands ──────────────────────────────────────────────────────
printf '%bQuick-test commands:%b\n' "$BOLD" "$RESET"
printf '  GPU:     glxgears / glmark2-es2-wayland / vulkaninfo --summary\n'
printf '  Audio:   pactl info / speaker-test -t wav -c 2 / pavucontrol\n'
printf '  Display: xdpyinfo | grep resolution / xrandr\n'
printf '  Fonts:   fc-match sans-serif / fc-match monospace\n'
printf '\n'

# ── Reminders ────────────────────────────────────────────────────────────────
printf '%bReminders:%b\n' "$YELLOW" "$RESET"
printf '  • Steam is x86-only — will NOT work on this ARM64 device\n'
printf '  • Cloud gaming: GeForce NOW / Xbox Cloud Gaming in ChromeOS browser\n'
printf '  • Manual .deb downloads: always get the arm64 variant\n'
printf '  • Flatpak apps: flatpak install flathub <app-id>\n'
printf '  • If GPU not active: reboot entire Chromebook (not just container)\n'
printf '\n'

printf '%bLog file:%b %s\n' "$BOLD" "$RESET" "$LOG_FILE"

# Clean up checkpoint
if $DRY_RUN; then
    log "[DRY-RUN] would remove checkpoint file"
else
    rm -f "$STEP_FILE"
    log "Checkpoint file removed. Setup fully complete."
fi

printf '\n%bRestart the Terminal app to apply all environment changes.%b\n\n' "$CYAN" "$RESET"

exit 0
