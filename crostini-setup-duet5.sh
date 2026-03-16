#!/usr/bin/env bash
# crostini-setup-duet5.sh — Crostini post-install bootstrap for Lenovo Duet 5 (82QS0001US)
# Version: 3.3.5
# Date:    2026-03-16
# Arch:    aarch64 / arm64 (Qualcomm Snapdragon 7c Gen 2 — SC7180)
# Target:  Debian Bookworm container under ChromeOS Crostini
# Usage:   bash crostini-setup-duet5.sh [--dry-run] [--interactive] [--minimal]
#              [--from-step=N] [--verify] [--reset] [--help] [--version]
#              [--git-name=NAME] [--git-email=EMAIL] [--ssh-comment=TXT]
#              [--ssh-passphrase=PASS]
# Fully unattended by default — use --interactive for ChromeOS toggle prompts.
# WARNING: Steam is x86-only; box64/box86 community translation exists but is unusable on 4 GB RAM / virgl.

set -euo pipefail
umask 077  # Restrict tempfiles/logs to owner-only by default

# Constants
readonly SCRIPT_NAME="crostini-setup-duet5.sh"
readonly SCRIPT_VERSION="3.3.5"
readonly EXPECTED_ARCH="aarch64"
_log_ts="$(date +%Y%m%d-%H%M%S)" || { printf 'FATAL: date failed\n' >&2; exit 1; }
readonly LOG_FILE="${HOME}/crostini-setup-${_log_ts}.log"
readonly STEP_FILE="${HOME}/.crostini-setup-checkpoint"
readonly LOCK_FILE="${HOME}/.crostini-setup.lock"
readonly NODE_MAJOR=22
readonly NODESOURCE_GPG_FP="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
readonly SYSCTL_CONF="/etc/sysctl.d/99-crostini-tuning.conf"
_cros_uid="$(id -u)" || { printf 'FATAL: cannot determine UID\n' >&2; exit 1; }
readonly CROS_UID="$_cros_uid"
unset _log_ts _cros_uid

# Create log file with restrictive permissions before any writes
if ! touch "$LOG_FILE" || ! chmod 600 "$LOG_FILE"; then
    printf 'FATAL: cannot create log file %s\n' "$LOG_FILE" >&2
    exit 1
fi

DRY_RUN=false
UNATTENDED=true
MINIMAL=false
_GIT_NAME=""
_GIT_EMAIL=""
_SSH_COMMENT=""
_SSH_PASSPHRASE=""
_DEFERRED_CHECKPOINT=""
_DEFERRED_CHECKPOINT_MSG=""

# Cleanup trap
# shellcheck disable=SC2317,SC2329
cleanup() {
    local rc=$?
    # Remove temp files
    [[ -n "${_VSCODE_DEB:-}" ]] && rm -f "$_VSCODE_DEB" 2>/dev/null
    [[ -n "${_ns_key:-}" ]] && rm -f "$_ns_key" 2>/dev/null
    [[ -n "${_ns_gpg:-}" ]] && sudo rm -f "$_ns_gpg" 2>/dev/null
    [[ -n "${_rustup_tmp:-}" ]] && rm -f "$_rustup_tmp" 2>/dev/null
    # Release lock
    [[ -n "${LOCK_FILE:-}" ]] && rm -rf "$LOCK_FILE" 2>/dev/null || true
    if [[ $rc -ne 0 ]]; then
        warn "Script exited with code $rc. Re-run to resume from checkpoint."
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# Colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

# Logging
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
    printf '\n%bSTEP %s: %s%b\n\n' "$BOLD" "$num" "$title" "$RESET"
}

# Checkpoint system
get_checkpoint() {
    if [[ -f "$STEP_FILE" ]]; then
        local val
        val="$(cat "$STEP_FILE")"
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "$val"
        else
            warn "Corrupted checkpoint file (got '${val}'). Use --reset to clear."
            echo 0
        fi
    else
        echo 0
    fi
}

set_checkpoint() {
    if $DRY_RUN; then
        log "[DRY-RUN] set checkpoint $1"
        return 0
    fi
    # Non-atomic write accepted — data is 1-2 digits; partial write
    echo "$1" > "$STEP_FILE"
}

should_run_step() {
    local step_num="$1"
    local checkpoint
    checkpoint=$(get_checkpoint)
    [[ "$step_num" -gt "$checkpoint" ]]
}

# run: execute "$@" directly; respects dry-run; wait flushes async tee.
run() {
    if $DRY_RUN; then
        log "[DRY-RUN] $*"
        return 0
    fi
    log "[EXEC] $*"
    local rc=0
    "$@" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2) || rc=$?
    # Flush tee subprocesses before checking exit code
    wait
    [[ $rc -ne 0 ]] && warn "Command exited $rc: $*"
    return $rc
}

# run_shell: execute hardcoded string via bash -c; respects dry-run; tee to terminal+log.
run_shell() {
    if $DRY_RUN; then
        log "[DRY-RUN] $1"
        return 0
    fi
    log "[EXEC] $1"
    local rc=0
    bash -c "set -euo pipefail; $1" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2) || rc=$?
    # Flush tee subprocesses before checking exit code
    wait
    [[ $rc -ne 0 ]] && warn "Shell command exited $rc: $1"
    return $rc
}

# write_file: atomic write stdin to path, respects dry-run
write_file() {
    local dest="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] write $dest"
        # Consume stdin so heredoc doesn't error
        cat > /dev/null
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || die "Cannot create parent dir for $dest"
    local tmp
    tmp="$(mktemp "$(dirname "$dest")/.tmp_XXXXXXXX")" || die "Cannot create tmpfile for $dest"
    cat > "$tmp" || { rm -f "$tmp"; die "Cannot write $dest"; }
    mv "$tmp" "$dest" || { rm -f "$tmp"; die "Cannot move $dest into place"; }
    log "Wrote $dest"
}

# write_file_sudo: atomic write via sudo, respects dry-run
write_file_sudo() {
    local dest="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] sudo write $dest"
        cat > /dev/null
        return 0
    fi
    sudo mkdir -p "$(dirname "$dest")" || die "Cannot create parent dir for $dest"
    local tmp
    tmp="$(sudo mktemp "$(dirname "$dest")/.tmp_XXXXXXXX")" || die "Cannot create tmpfile for $dest"
    sudo tee "$tmp" > /dev/null || { sudo rm -f "$tmp"; die "Cannot write $dest"; }
    sudo mv "$tmp" "$dest" || { sudo rm -f "$tmp"; die "Cannot move $dest into place"; }
    log "Wrote $dest (sudo)"
}

# Open URL in ChromeOS browser
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

check_tool() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1) || true
        logprintf '  %-14s %b✓%b  %s\n' "$name" "$GREEN" "$RESET" "$ver"
    else
        logprintf '  %-14s %b✗%b  not found\n' "$name" "$RED" "$RESET"
    fi
}

check_config() {
    local path="$1" desc="$2"
    if [[ -f "$path" ]]; then
        logprintf '  %b✓%b  %-44s %s\n' "$GREEN" "$RESET" "$desc" "$path"
    else
        logprintf '  %b✗%b  %-44s %s\n' "$RED" "$RESET" "$desc" "$path"
    fi
}

# logprintf: printf to both stdout and log file (for verification output)
logprintf() {
    # shellcheck disable=SC2059
    printf "$@"
    # Strip ANSI escapes for the log file
    # shellcheck disable=SC2059
    printf "$@" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null || true
}

# Usage / Help
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Crostini post-install bootstrap for Lenovo Duet 5 Chromebook (ARM64)

USAGE:
    bash ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    --dry-run    Print commands without executing
    --interactive  Prompt for ChromeOS toggles, git config, SSH key (default: unattended)
    --git-name=NAME    Git user.name (unattended mode; ignored with --interactive)
    --git-email=EMAIL  Git user.email (unattended mode; ignored with --interactive)
    --ssh-comment=TXT  SSH key comment (unattended mode; default: none)
    --ssh-passphrase=PASS  SSH key passphrase (unattended mode; default: empty/none)
    --from-step=N  Start (or restart) from step N (1–20)
    --verify       Run only step 20 (summary and verification)
    --minimal      Skip heavy optional packages (e.g. gnome-disk-utility)
    --help       Show this help message
    --version    Show version
    --reset      Clear checkpoint and start from step 1

STEPS PERFORMED:
     1  Preflight checks (arch, Crostini, disk, network, root, sommelier)
     2  ChromeOS integration (GPU flag, microphone, USB, folder sharing,
        port forwarding, disk — opens settings pages with --interactive)
     3  System update and upgrade
     4  Core CLI utilities
     5  Build essentials and development headers
     6  GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)
     7  Audio stack (ALSA, PulseAudio, GStreamer codecs)
     8  Display scaling and HiDPI (sommelier, GTK 2/3/4, Qt, Xft, fontconfig, cursor)
     9  GUI applications (Firefox ESR, Thunar, Evince, fonts, screenshots, MIME defaults)
    10  Python ecosystem (python3, pip, venv)
    11  Node.js via NodeSource (LTS, arm64)
    12  Rust via rustup (aarch64)
    13  Git configuration
    14  VS Code (arm64 .deb + Wayland flags)
    15  Container resource tuning (sysctl, locale, env, XDG, paths)
    16  Flatpak + Flathub (ARM64 app source)
    17  Gaming packages (DOSBox, ScummVM, RetroArch)
    18  SSH key generation
    19  Container backup (opens ChromeOS backup page with --interactive)
    20  Summary and verification

CHECKPOINT:
    Progress is saved after each step to ${STEP_FILE}.
    Re-run the script to resume from where it left off.
    Use --reset to start over.

LOG:
    Full output is written to ~/crostini-setup-YYYYMMDD-HHMMSS.log
EOF
    exit 0
}

# Argument parsing
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --interactive) UNATTENDED=false ;;
        --git-name=*)  _GIT_NAME="${arg#*=}" ;;
        --git-email=*) _GIT_EMAIL="${arg#*=}" ;;
        --ssh-comment=*) _SSH_COMMENT="${arg#*=}" ;;
        --ssh-passphrase=*) _SSH_PASSPHRASE="${arg#*=}" ;;
        --from-step=*)
            _from="${arg#*=}"
            if [[ ! "$_from" =~ ^[0-9]+$ ]] || [[ "$_from" -lt 1 ]] || [[ "$_from" -gt 20 ]]; then
                die "--from-step requires a number 1–20 (got '${_from}')"
            fi
            # Defer checkpoint write until after lock acquisition (#2)
            _DEFERRED_CHECKPOINT="$((_from - 1))"
            _DEFERRED_CHECKPOINT_MSG="Checkpoint set to step $((_from - 1)); will resume from step ${_from}."
            unset _from
            ;;
        --verify)
            # Defer checkpoint write until after lock acquisition (#2)
            _DEFERRED_CHECKPOINT="19"
            _DEFERRED_CHECKPOINT_MSG="Checkpoint set to 19; running verification only."
            ;;
        --minimal) MINIMAL=true ;;
        --help)    usage ;;
        --version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
        --reset)   rm -f "$STEP_FILE"; echo "Checkpoint cleared."; exit 0 ;;
        *)         die "Unknown argument: $arg. Use --help for usage." ;;
    esac
done

# Acquire exclusive lock (PID-based stale detection for crash recovery)
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    _old_pid="$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")"
    if [[ -z "$_old_pid" ]]; then
        # PID file missing/empty (crash between mkdir and PID write) — treat as stale
        warn "Removing stale lock (no PID file — likely prior crash)"
        rm -rf "$LOCK_FILE"
        mkdir "$LOCK_FILE" || die "Cannot re-acquire lock after stale removal"
    elif ! kill -0 "$_old_pid" 2>/dev/null; then
        warn "Removing stale lock from dead PID $_old_pid"
        rm -rf "$LOCK_FILE"
        mkdir "$LOCK_FILE" || die "Cannot re-acquire lock after stale removal"
    else
        die "Another instance (PID ${_old_pid}) is running (lock: ${LOCK_FILE}). Remove manually if stale."
    fi
    unset _old_pid
fi
_pid_tmp="$(mktemp "$LOCK_FILE/.pid_XXXXXXXX")" \
    || die "Cannot create PID tmpfile"
printf '%s\n' $$ > "$_pid_tmp"
mv "$_pid_tmp" "$LOCK_FILE/pid" \
    || { rm -f "$_pid_tmp"; die "Cannot write PID file"; }
unset _pid_tmp

# Apply deferred checkpoint (must be inside lock — fix #2)
if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
    if ! echo "$_DEFERRED_CHECKPOINT" > "$STEP_FILE" 2>/dev/null; then
        die "Cannot write checkpoint file ${STEP_FILE} — is \$HOME writable?"
    fi
    echo "$_DEFERRED_CHECKPOINT_MSG"
fi
unset _DEFERRED_CHECKPOINT _DEFERRED_CHECKPOINT_MSG

# Set noninteractive globally so it persists on checkpoint resume.
export DEBIAN_FRONTEND=noninteractive
# Step 1: Preflight checks
if should_run_step 1; then
    step_banner 1 "Preflight checks"

    # 1a. Architecture
    CURRENT_ARCH="$(uname -m)"
    if [[ "$CURRENT_ARCH" != "$EXPECTED_ARCH" ]]; then
        if $DRY_RUN; then
            warn "[DRY-RUN] Architecture mismatch: expected ${EXPECTED_ARCH}, got ${CURRENT_ARCH}. Continuing for preview."
        else
            die "Expected architecture ${EXPECTED_ARCH}, got ${CURRENT_ARCH}. This script is for the Duet 5 (ARM64) only."
        fi
    fi
    log "Architecture: ${CURRENT_ARCH} ✓"

    # 1b. Crostini container detection
    if [[ -f /dev/.cros_milestone ]]; then
        log "ChromeOS milestone: $(cat /dev/.cros_milestone) ✓"
    elif [[ -d /mnt/chromeos ]]; then
        log "Crostini mount point detected ✓"
    else
        warn "Cannot confirm Crostini environment. Proceeding anyway."
    fi

    # 1c. Debian version
    if [[ -f /etc/os-release ]]; then
        _os_pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
        log "Container OS: ${_os_pretty} ✓"
        unset _os_pretty
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
        if $DRY_RUN; then
            warn "[DRY-RUN] Running as root. Would abort in live mode."
        else
            die "Do not run this script as root. Run as your normal user (sudo is used internally where needed)."
        fi
    fi
    log "Running as user: $(whoami) ✓"

    # 1g. Sommelier (Wayland bridge) — needed for all GUI apps
    if pgrep -x sommelier &>/dev/null; then
        log "Sommelier (Wayland bridge): running ✓"
    else
        warn "Sommelier not detected. GUI apps may not display until container restarts."
    fi

    unset CURRENT_ARCH AVAIL_KB AVAIL_MB
    set_checkpoint 1
    log "Step 1 complete."
fi
# Step 2: ChromeOS integration — open settings for required toggles (--interactive)
if should_run_step 2; then
    step_banner 2 "ChromeOS integration (GPU, mic, USB, folders, ports, disk)"

    # 2a. GPU acceleration
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU acceleration: ALREADY ACTIVE ✓"
    else
        log "GPU acceleration not detected."
        if ! $DRY_RUN; then
            if ! $UNATTENDED; then
                printf '%b  → The chrome://flags page is opening in ChromeOS now.%b\n' "$YELLOW" "$RESET"
                printf '%b  → Search for "crostini-gpu-support" and set to "Enabled".%b\n' "$YELLOW" "$RESET"
                printf '%b  → A full Chromebook reboot is required for GPU to activate.%b\n' "$YELLOW" "$RESET"
                printf '%b  → GPU packages will be installed now regardless.%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://flags/#crostini-gpu-support"
                sleep 2
                printf '%bPress Enter after enabling the flag (or to continue)...%b' "$YELLOW" "$RESET"
                read -r _
            fi
            if [[ -e /dev/dri/renderD128 ]]; then
                log "GPU acceleration now active ✓"
            else
                warn "GPU not yet active — requires full Chromebook reboot. Continuing."
            fi
        else
            log "[DRY-RUN] would open chrome://flags/#crostini-gpu-support"
        fi
    fi

    # 2b. Microphone access
    if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
        log "Microphone capture device: detected ✓"
    else
        log "Microphone not detected."
        if ! $DRY_RUN; then
            if ! $UNATTENDED; then
                printf '%b  → Toggle "Allow Linux to access your microphone" → On%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://os-settings/crostini"
                sleep 2
                printf '%bPress Enter after enabling microphone (or to continue)...%b' "$YELLOW" "$RESET"
                read -r _
            fi
            if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
                log "Microphone now available ✓"
            else
                warn "Microphone still not detected. May need container restart."
            fi
        else
            log "[DRY-RUN] would open chrome://os-settings/crostini for mic toggle"
        fi
    fi

    # 2c. USB device passthrough
    if ! $DRY_RUN && ! $UNATTENDED; then
        log "Opening USB device management..."
        printf '%b  → Toggle on any USB devices you need (drives, Arduino, etc.)%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/usbPreferences"
        sleep 2
        printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r _
    elif $DRY_RUN; then
        log "[DRY-RUN] would open chrome://os-settings/crostini/usbPreferences"
    fi

    # 2d. Shared folders
    if [[ -d /mnt/chromeos ]]; then
        SHARED_COUNT=$(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d 2>/dev/null | wc -l)
        if [[ "$SHARED_COUNT" -gt 0 ]]; then
            log "Shared ChromeOS folders: ${SHARED_COUNT} detected ✓"
        else
            log "No shared folders."
            if ! $DRY_RUN && ! $UNATTENDED; then
                printf '%b  → Click "Share folder" to make ChromeOS folders visible at /mnt/chromeos/%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://os-settings/crostini/sharedPaths"
                sleep 2
                printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
                read -r _
            elif $DRY_RUN; then
                log "[DRY-RUN] would open chrome://os-settings/crostini/sharedPaths"
            fi
        fi
        unset SHARED_COUNT
    fi

    # 2e. Port forwarding
    if ! $DRY_RUN && ! $UNATTENDED; then
        log "Opening port forwarding settings..."
        printf '%b  → Add any dev server ports (3000, 5000, 8080, etc.)%b\n' "$YELLOW" "$RESET"
        printf '%b  → Crostini also auto-detects listening ports in most cases.%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/portForwarding"
        sleep 2
        printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r _
    elif $DRY_RUN; then
        log "[DRY-RUN] would open chrome://os-settings/crostini/portForwarding"
    fi

    # 2f. Disk size check
    AVAIL_MB_NOW=$(($(df --output=avail / | tail -1 | tr -d ' ') / 1024))
    if [[ "$AVAIL_MB_NOW" -lt 10240 ]]; then
        log "Disk under 10 GB free."
        if ! $DRY_RUN && ! $UNATTENDED; then
            printf '%b  → Consider increasing Linux disk allocation (20–30 GB recommended).%b\n\n' "$YELLOW" "$RESET"
            open_chromeos_url "chrome://os-settings/crostini"
            sleep 2
            printf '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
            read -r _
        elif $DRY_RUN; then
            log "[DRY-RUN] would open chrome://os-settings/crostini for disk resize"
        fi
    else
        log "Disk space: ${AVAIL_MB_NOW} MB free — adequate"
    fi

    unset AVAIL_MB_NOW
    set_checkpoint 2
    log "Step 2 complete."
fi
# Step 3: System update and upgrade
if should_run_step 3; then
    step_banner 3 "System update and upgrade"

    run sudo apt-get update || warn "apt update failed"
    run sudo apt-get upgrade -y || warn "apt upgrade had issues"
    run sudo apt-get full-upgrade -y || warn "apt-get full-upgrade had issues"
    run sudo apt-get autoremove -y || true

    set_checkpoint 3
    log "Step 3 complete."
fi
# Step 4: Core CLI utilities
if should_run_step 4; then
    step_banner 4 "Core CLI utilities"

    CORE_PKGS=(
        # Navigation and file management
        file tree zip unzip p7zip-full rsync rename

        # Text processing
        nano vim less jq

        # Network utilities
        curl wget dnsutils openssh-client
        ca-certificates gnupg

        # System monitoring
        htop ncdu lsof strace

        # Search and filtering
        ripgrep fd-find fzf bat

        # Misc
        tmux screen man-db bash-completion locales
        software-properties-common
    )

    run sudo apt-get install -y "${CORE_PKGS[@]}" || warn "Some core packages failed to install — continuing"

    # Create common symlinks for renamed Debian packages
    if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        run sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd || true
        $DRY_RUN || log "Symlinked fdfind → fd"
    fi
    if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        run sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat || true
        $DRY_RUN || log "Symlinked batcat → bat"
    fi

    unset CORE_PKGS
    set_checkpoint 4
    log "Step 4 complete."
fi
# Step 5: Build essentials and development headers
if should_run_step 5; then
    step_banner 5 "Build essentials and development headers"

    DEV_PKGS=(
        build-essential gcc g++ make cmake pkg-config
        autoconf automake libtool
        libssl-dev libffi-dev zlib1g-dev libbz2-dev
        libreadline-dev libsqlite3-dev libncurses-dev
        libxml2-dev libxslt1-dev liblzma-dev libgdbm-dev
    )

    run sudo apt-get install -y "${DEV_PKGS[@]}" || warn "Some dev packages failed to install — continuing"

    unset DEV_PKGS
    set_checkpoint 5
    log "Step 5 complete."
fi
# Step 6: GPU + graphics stack
if should_run_step 6; then
    step_banner 6 "GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)"

    # Stable packages — names consistent across Debian Bookworm
    GPU_STABLE_PKGS=(
        mesa-utils
        libgl1-mesa-dri
        libegl1-mesa
        libgles2-mesa
        libvulkan1
        libwayland-client0
        libwayland-egl1
        x11-utils
        x11-xserver-utils
        xdg-desktop-portal
        xdg-desktop-portal-gtk
    )

    run sudo apt-get install -y "${GPU_STABLE_PKGS[@]}" || warn "Some stable GPU packages failed — continuing"

    # Volatile packages — names may differ across Debian versions
    # libgl1 replaces the transitional libgl1-mesa-glx
    GPU_VOLATILE_PKGS=(
        mesa-vulkan-drivers
        libgl1
        vulkan-tools
        glmark2-wayland
        glmark2-es2-wayland
    )

    # Per-package loop for volatile names — GPU package names change between
    for pkg in "${GPU_VOLATILE_PKGS[@]}"; do
        run sudo apt-get install -y "$pkg" || warn "Skipped unavailable: $pkg"
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
# Prefer Wayland for GTK apps (sommelier handles the bridge).
# NOTE: Some Electron apps (Slack, Discord) may ignore this or need
# GDK_BACKEND unset.  VS Code uses --ozone-platform-hint=auto instead.
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

    unset GL_VENDOR GL_RENDERER GL_VERSION GPU_ENV_FILE GPU_STABLE_PKGS GPU_VOLATILE_PKGS
    set_checkpoint 6
    log "Step 6 complete."
fi
# Step 7: Audio stack
if should_run_step 7; then
    step_banner 7 "Audio stack (ALSA, PulseAudio, GStreamer codecs)"

    AUDIO_PKGS=(
        # ALSA
        alsa-utils
        libasound2
        libasound2-plugins

        # PulseAudio client only — do NOT install the daemon (conflicts with host)
        # pavucontrol = GUI volume mixer
        pulseaudio-utils
        pavucontrol

        # GStreamer codecs and media support
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-pulseaudio
        gstreamer1.0-alsa
        libavcodec-extra
    )

    for pkg in "${AUDIO_PKGS[@]}"; do
        run sudo apt-get install -y "$pkg" || warn "Skipped unavailable: $pkg"
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
        SND_DEV_COUNT=$(find /dev/snd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        log "Audio devices in /dev/snd: ${SND_DEV_COUNT} ✓"
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

    unset AUDIO_PKGS AUDIO_ENV_FILE PA_CLIENT SND_DEV_COUNT
    set_checkpoint 7
    log "Step 7 complete."
fi
# Step 8: Display scaling and HiDPI configuration
if should_run_step 8; then
    step_banner 8 "Display scaling and HiDPI (sommelier, GTK 2/3/4, Qt, Xft, fontconfig, cursor)"

    # 13.3" FHD OLED — configure sommelier, GTK 2/3/4, Qt, Xft, fontconfig, cursor

    # 8a. Sommelier environment (controls Linux app scaling)
    SOMMELIER_ENV="${HOME}/.config/environment.d/sommelier.conf"
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

    # 8b. GTK 3 settings
    GTK3_SETTINGS="${HOME}/.config/gtk-3.0/settings.ini"
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

    # 8c. GTK 4 settings
    GTK4_SETTINGS="${HOME}/.config/gtk-4.0/settings.ini"
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

    # 8d. GTK 2 settings (legacy apps)
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

    # 8e. Qt scaling and theming
    QT_ENV="${HOME}/.config/environment.d/qt.conf"
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
    run sudo apt-get install -y qt5ct || warn "qt5ct unavailable — Qt apps may not inherit dark theme"
    run sudo apt-get install -y qt5-gtk-platformtheme || \
        run sudo apt-get install -y qt5-style-plugins || \
        warn "Qt GTK theme package not available — Qt apps may not follow dark theme"

    # 8f. Xft / Xresources (for pure X11 apps)
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
        $DRY_RUN || log "Xresources merged"
    fi

    # 8g. Fontconfig (grayscale AA for OLED, Noto defaults)
    FC_LOCAL="${HOME}/.config/fontconfig/fonts.conf"
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
        run fc-cache -f || true
        $DRY_RUN || log "Font cache rebuilt"
    fi

    # 8h. Cursor theme (ensure consistency across toolkits)
    CURSOR_DIR="${HOME}/.icons/default"
    if [[ ! -f "${CURSOR_DIR}/index.theme" ]]; then
        write_file "${CURSOR_DIR}/index.theme" <<'EOF'
[Icon Theme]
Inherits=Adwaita
EOF
    else
        log "Cursor theme already exists — skipping"
    fi

    unset SOMMELIER_ENV GTK3_SETTINGS GTK4_SETTINGS GTK2_RC QT_ENV XRESOURCES FC_LOCAL CURSOR_DIR
    set_checkpoint 8
    log "Step 8 complete."
fi
# Step 9: GUI application essentials
if should_run_step 9; then
    step_banner 9 "GUI applications (Firefox, Thunar, Evince, fonts, screenshots, MIME defaults)"

    GUI_PKGS=(
        # Browser
        firefox-esr

        # File management: thunar (lightweight), archive plugin, thumbnail service
        thunar
        thunar-archive-plugin
        tumbler

        # Document and image viewers
        evince
        eog

        # Utilities: calculator, screenshot tool, archive manager
        gnome-calculator
        gnome-screenshot
        file-roller
        xdg-utils

        # Session support: D-Bus for X11, accessibility (suppresses GTK warnings),
        # desktop notifications (notify-send)
        dbus-x11
        at-spi2-core
        libnotify-bin

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
        run sudo apt-get install -y "$pkg" || warn "Skipped unavailable: $pkg"
    done

    # gnome-disk-utility has heavy GNOME deps — skip with --minimal
    if ! $MINIMAL; then
        run sudo apt-get install -y gnome-disk-utility \
            || warn "gnome-disk-utility install failed"
    else
        log "Skipping gnome-disk-utility (--minimal mode)"
    fi

    # Try to install full icon theme (may not exist on all versions)
    run sudo apt-get install -y adwaita-icon-theme-full || warn "adwaita-icon-theme-full unavailable — using base theme"

    # Set Firefox ESR as default browser
    if command -v firefox-esr &>/dev/null; then
        run sudo update-alternatives --set x-www-browser /usr/bin/firefox-esr || true
        $DRY_RUN || log "Firefox ESR set as default browser"
    fi

    # Set default file manager
    if command -v thunar &>/dev/null; then
        run xdg-mime default thunar.desktop inode/directory || true
        $DRY_RUN || log "Thunar set as default file manager"
    fi

    # Set default PDF viewer
    if command -v evince &>/dev/null; then
        run xdg-mime default org.gnome.Evince.desktop application/pdf || true
        $DRY_RUN || log "Evince set as default PDF viewer"
    fi

    # Set default image viewer
    if command -v eog &>/dev/null; then
        run xdg-mime default org.gnome.eog.desktop image/png || true
        run xdg-mime default org.gnome.eog.desktop image/jpeg || true
        $DRY_RUN || log "Eye of GNOME set as default image viewer"
    fi

    # Ensure desktop applications directory exists (garcon integration)
    run mkdir -p "${HOME}/.local/share/applications"
    $DRY_RUN || log "Desktop applications directory: ${HOME}/.local/share/applications ✓"

    unset GUI_PKGS
    set_checkpoint 9
    log "Step 9 complete."
fi
# Step 10: Python ecosystem
if should_run_step 10; then
    step_banner 10 "Python ecosystem"

    run sudo apt-get install -y python3 python3-pip python3-venv python3-dev python3-setuptools python3-wheel \
        || warn "Some Python packages failed — continuing"

    run mkdir -p "${HOME}/.local/bin"

    log "Python version: $(python3 --version 2>/dev/null || echo 'not installed')"
    log "pip version: $(python3 -m pip --version 2>/dev/null || echo 'not installed')"

    set_checkpoint 10
    log "Step 10 complete."
fi
# Step 11: Node.js via NodeSource (LTS, arm64)
if should_run_step 11; then
    step_banner 11 "Node.js LTS (arm64)"

    if command -v node &>/dev/null; then
        log "Node.js already installed: $(node --version)"
    else
        log "Installing Node.js ${NODE_MAJOR}.x LTS from NodeSource..."

        run sudo mkdir -p /etc/apt/keyrings || die "Cannot create /etc/apt/keyrings"
        _ns_key="$(mktemp)"
        run curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$_ns_key" \
            || { rm -f "$_ns_key"; die "NodeSource GPG key download failed"; }
        if [[ ! -s "$_ns_key" ]]; then
            rm -f "$_ns_key"; die "NodeSource GPG key is empty"
        fi
        # Verify GPG key fingerprint to prevent supply-chain substitution
        _ns_fp="$(gpg --dry-run --show-keys --with-colons "$_ns_key" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')"
        if [[ "$_ns_fp" != "$NODESOURCE_GPG_FP" ]]; then
            rm -f "$_ns_key"
            die "NodeSource GPG fingerprint mismatch: expected ${NODESOURCE_GPG_FP}, got ${_ns_fp:-empty}. Possible key rotation or supply-chain compromise."
        fi
        log "NodeSource GPG fingerprint verified: ${_ns_fp}"
        unset _ns_fp
        _ns_gpg="$(sudo mktemp /etc/apt/keyrings/.tmp_XXXXXXXX)" \
            || { rm -f "$_ns_key"; die "Cannot create tmpfile for GPG keyring"; }
        # shellcheck disable=SC2024  # redirect captures gpg log messages, not dearmored output (-o flag)
        sudo gpg --yes --dearmor -o "$_ns_gpg" < "$_ns_key" >> "$LOG_FILE" 2>&1 \
            || { rm -f "$_ns_key"; sudo rm -f "$_ns_gpg"; die "NodeSource GPG dearmor failed"; }
        sudo mv "$_ns_gpg" /etc/apt/keyrings/nodesource.gpg \
            || { rm -f "$_ns_key"; sudo rm -f "$_ns_gpg"; die "Cannot move GPG keyring into place"; }
        rm -f "$_ns_key"
        unset _ns_key _ns_gpg
        run_shell "echo 'deb [arch=arm64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main' | sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null"
        # Verify sources file was written correctly (#6)
        if [[ ! -s /etc/apt/sources.list.d/nodesource.list ]]; then
            die "NodeSource sources.list is empty or missing after write"
        fi
        if ! grep -q "deb.*nodesource" /etc/apt/sources.list.d/nodesource.list; then
            die "NodeSource sources.list content invalid"
        fi
        run sudo apt-get update  || warn "apt update failed"
        run sudo apt-get install -y nodejs || die "nodejs install failed — check NodeSource repo setup above"
    fi

    # Configure npm global prefix to avoid sudo for global installs
    NPM_GLOBAL="${HOME}/.npm-global"
    if command -v npm &>/dev/null; then
        run mkdir -p "$NPM_GLOBAL"
        run npm config set prefix "${NPM_GLOBAL}"
        $DRY_RUN || log "npm global prefix set to ${NPM_GLOBAL}"
    fi

    log "Node version: $(node --version 2>/dev/null || echo 'not installed')"
    log "npm version: $(npm --version 2>/dev/null || echo 'not installed')"

    unset NPM_GLOBAL
    set_checkpoint 11
    log "Step 11 complete."
fi
# Step 12: Rust via rustup (aarch64)
if should_run_step 12; then
    step_banner 12 "Rust toolchain (aarch64)"

    if command -v rustc &>/dev/null; then
        log "Rust already installed: $(rustc --version)"
    else
        log "Installing Rust via rustup (non-interactive)..."
        if $DRY_RUN; then
            log "[DRY-RUN] curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init-XXXXXXXXXX.sh"
            log "[DRY-RUN] sh /tmp/rustup-init-XXXXXXXXXX.sh -y --default-toolchain stable"
        else
            # TOFU (HTTPS-only); download to tmpfile to prevent executing truncated script (#4)
            _rustup_tmp="$(mktemp /tmp/rustup-init-XXXXXXXXXX.sh)"
            if ! run curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$_rustup_tmp"; then
                rm -f "$_rustup_tmp"
                die "Rustup download failed"
            fi
            if [[ ! -s "$_rustup_tmp" ]]; then
                rm -f "$_rustup_tmp"
                die "Rustup installer is empty"
            fi
            run_shell "sh '${_rustup_tmp}' -y --default-toolchain stable"
            rm -f "$_rustup_tmp"
            unset _rustup_tmp
        fi

        if [[ -f "${HOME}/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "${HOME}/.cargo/env"
        fi
    fi

    log "rustc version: $(rustc --version 2>/dev/null || echo 'not installed')"
    log "cargo version: $(cargo --version 2>/dev/null || echo 'not installed')"

    set_checkpoint 12
    log "Step 12 complete."
fi
# Step 13: Git configuration
if should_run_step 13; then
    step_banner 13 "Git configuration"

    run sudo apt-get install -y git git-lfs || warn "git install had issues"

    CURRENT_NAME="$(git config --global user.name 2>/dev/null || true)"
    CURRENT_EMAIL="$(git config --global user.email 2>/dev/null || true)"

    if [[ -z "$CURRENT_NAME" ]]; then
        if ! $DRY_RUN; then
            if $UNATTENDED; then
                GIT_NAME="$_GIT_NAME"
            else
                printf '%bEnter your Git name (e.g. Ryan Musante): %b' "$YELLOW" "$RESET"
                read -r GIT_NAME
            fi
            if [[ -n "$GIT_NAME" ]]; then
                run git config --global user.name "${GIT_NAME}"
            else
                warn "Git user.name not set (pass --git-name=NAME in unattended mode)"
            fi
        else
            log "[DRY-RUN] would prompt for git user.name"
        fi
    else
        log "Git user.name already set: ${CURRENT_NAME}"
    fi

    if [[ -z "$CURRENT_EMAIL" ]]; then
        if ! $DRY_RUN; then
            if $UNATTENDED; then
                GIT_EMAIL="$_GIT_EMAIL"
            else
                printf '%bEnter your Git email: %b' "$YELLOW" "$RESET"
                read -r GIT_EMAIL
            fi
            if [[ -n "$GIT_EMAIL" ]]; then
                run git config --global user.email "${GIT_EMAIL}"
            else
                warn "Git user.email not set (pass --git-email=EMAIL in unattended mode)"
            fi
        else
            log "[DRY-RUN] would prompt for git user.email"
        fi
    else
        log "Git user.email already set: ${CURRENT_EMAIL}"
    fi

    _gval="$(git config --global init.defaultBranch 2>/dev/null || true)"
    if [[ -z "$_gval" ]]; then
        run git config --global init.defaultBranch main
    else
        log "Git init.defaultBranch already set: ${_gval}"
    fi

    _gval="$(git config --global pull.rebase 2>/dev/null || true)"
    if [[ -z "$_gval" ]]; then
        run git config --global pull.rebase true
    else
        log "Git pull.rebase already set: ${_gval}"
    fi

    _gval="$(git config --global core.autocrlf 2>/dev/null || true)"
    if [[ -z "$_gval" ]]; then
        run git config --global core.autocrlf input
    else
        log "Git core.autocrlf already set: ${_gval}"
    fi

    _gval="$(git config --global core.editor 2>/dev/null || true)"
    if [[ -z "$_gval" ]]; then
        run git config --global core.editor vim
    else
        log "Git core.editor already set: ${_gval}"
    fi

    _gval="$(git config --global color.ui 2>/dev/null || true)"
    if [[ -z "$_gval" ]]; then
        run git config --global color.ui auto
    else
        log "Git color.ui already set: ${_gval}"
    fi

    _gval="$(git config --global push.autoSetupRemote 2>/dev/null || true)"
    if [[ -z "$_gval" ]]; then
        run git config --global push.autoSetupRemote true
    else
        log "Git push.autoSetupRemote already set: ${_gval}"
    fi
    unset _gval
    run git lfs install || warn "git-lfs init failed — install git-lfs manually"
    unset GIT_NAME GIT_EMAIL CURRENT_NAME CURRENT_EMAIL

    log "Git version: $(git --version 2>/dev/null || echo 'not installed')"

    set_checkpoint 13
    log "Step 13 complete."
fi
# Step 14: VS Code (arm64 .deb)
if should_run_step 14; then
    step_banner 14 "Visual Studio Code (arm64)"

    if command -v code &>/dev/null; then
        log "VS Code already installed: $(code --version 2>/dev/null | head -1 || true)"
    else
        if $DRY_RUN; then
            log "[DRY-RUN] curl -fSL https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-arm64 -o /tmp/vscode-arm64-XXXXXXXXXX.deb"
            log "[DRY-RUN] sudo dpkg -i /tmp/vscode-arm64-XXXXXXXXXX.deb"
        else
            log "Downloading VS Code arm64 .deb..."
            _VSCODE_DEB="$(mktemp /tmp/vscode-arm64-XXXXXXXXXX.deb)"
            if ! run curl -fSL "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-arm64" -o "${_VSCODE_DEB}"; then
                warn "VS Code download failed (curl exit $?). Install manually:"
                warn "  https://code.visualstudio.com/download (select ARM64 .deb)"
            fi

            if [[ -f "$_VSCODE_DEB" ]] && [[ -s "$_VSCODE_DEB" ]]; then
                # Validate .deb structure before installing (catches corrupt/truncated downloads)
                if ! dpkg-deb --info "$_VSCODE_DEB" > /dev/null 2>&1; then
                    warn "VS Code .deb is corrupt or invalid. Install manually:"
                    warn "  https://code.visualstudio.com/download (select ARM64 .deb)"
                elif run sudo dpkg -i "$_VSCODE_DEB"; then
                    log "VS Code installed ✓"
                elif run sudo apt-get install -f -y; then
                    log "VS Code installed (dpkg deps resolved by apt-get -f) ✓"
                else
                    warn "VS Code install failed (dpkg and apt-get -f both failed). Install manually:"
                    warn "  https://code.visualstudio.com/download (select ARM64 .deb)"
                fi
            else
                warn "VS Code download failed. Install manually:"
                warn "  https://code.visualstudio.com/download (select ARM64 .deb)"
            fi
            rm -f "$_VSCODE_DEB" 2>/dev/null
        fi
    fi

    # VS Code Wayland flags for better rendering on Crostini
    VSCODE_FLAGS="${HOME}/.config/code-flags.conf"
    if [[ ! -f "$VSCODE_FLAGS" ]]; then
        write_file "$VSCODE_FLAGS" <<'EOF'
--ozone-platform-hint=auto
EOF
    else
        log "VS Code flags already exist"
    fi

    unset VSCODE_FLAGS _VSCODE_DEB
    set_checkpoint 14
    log "Step 14 complete."
fi
# Step 15: Container resource tuning
if should_run_step 15; then
    step_banner 15 "Container resource tuning (sysctl, locale, env, XDG, paths)"

    # 15a. Increase inotify watchers (VS Code and file-heavy tools need this)
    if [[ ! -f "$SYSCTL_CONF" ]]; then
        write_file_sudo "$SYSCTL_CONF" <<'EOF'
fs.inotify.max_user_watches=524288
EOF
        run sudo chmod 644 "$SYSCTL_CONF" || true
        if run sudo sysctl --system; then
            $DRY_RUN || log "inotify watchers applied (524288)"
        else
            warn "sysctl apply failed — inotify setting written to file but not active until reboot"
        fi
    else
        log "sysctl tuning already applied"
    fi

    # 15b. Set locale to en_US.UTF-8
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        # sed -i is not atomic; backup first in case of partial write or interruption
        run sudo cp /etc/locale.gen /etc/locale.gen.bak || warn "locale.gen backup failed"
        if ! run sudo sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; then
            warn "locale.gen edit failed — restoring backup"
            sudo cp /etc/locale.gen.bak /etc/locale.gen 2>/dev/null || true
        fi
        run sudo locale-gen || warn "locale-gen failed"
        $DRY_RUN || log "en_US.UTF-8 locale generated"
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
        run sudo chmod 644 "$PROFILE_D" || true
    else
        log "Environment profile already exists"
    fi

    # 15d. Memory tuning — vm.* sysctls are read-only in Crostini; test before applying
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
            run sudo chmod 644 "$MEM_CONF" || true
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
        run xdg-user-dirs-update || true
        $DRY_RUN || log "XDG user directories updated"
    fi

    unset PROFILE_D MEM_CONF
    set_checkpoint 15
    log "Step 15 complete."
fi
# Step 16: Flatpak + Flathub
if should_run_step 16; then
    step_banner 16 "Flatpak + Flathub (ARM64 app source)"

    run sudo apt-get install -y flatpak || warn "flatpak install failed"
    run sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || warn "Flathub remote add failed"

    $DRY_RUN || log "Flatpak installed with Flathub remote."
    log "Install apps: flatpak install flathub <app-id>"

    set_checkpoint 16
    log "Step 16 complete."
fi
# Step 17: Gaming packages
if should_run_step 17; then
    step_banner 17 "Gaming packages (DOSBox, ScummVM, RetroArch)"

    # Phase 2: native ARM packages (no translation layer needed)
    run sudo apt-get install -y dosbox scummvm || warn "Some gaming packages failed"

    # RetroArch via Flatpak (aarch64 confirmed on Flathub)
    if command -v flatpak &>/dev/null; then
        run flatpak install -y flathub org.libretro.RetroArch || warn "RetroArch Flatpak install failed"
    else
        warn "flatpak not available — skip RetroArch (install flatpak first)"
    fi

    # Verify
    if command -v dosbox &>/dev/null; then
        log "dosbox: $(dosbox --version 2>/dev/null | head -1 || true) ✓"
    else
        warn "dosbox not found"
    fi
    if command -v scummvm &>/dev/null; then
        log "scummvm: $(scummvm --version 2>/dev/null | head -1 || true) ✓"
    else
        warn "scummvm not found"
    fi
    if flatpak list --app 2>/dev/null | grep -q org.libretro.RetroArch; then
        log "RetroArch Flatpak: installed ✓"
    else
        warn "RetroArch Flatpak not detected"
    fi

    log "For advanced gaming (box86/Wine/GOG): see crostini-gaming-packages.txt"

    set_checkpoint 17
    log "Step 17 complete."
fi
# Step 18: SSH key generation
if should_run_step 18; then
    step_banner 18 "SSH key generation"

    SSH_KEY="${HOME}/.ssh/id_ed25519"
    if [[ -f "$SSH_KEY" ]]; then
        log "SSH key already exists at ${SSH_KEY}"
    else
        if ! $DRY_RUN; then
            if $UNATTENDED; then
                GEN_SSH="y"
                SSH_COMMENT="$_SSH_COMMENT"
                SSH_PASS="$_SSH_PASSPHRASE"
            else
                printf '%bGenerate an Ed25519 SSH key? [Y/n]: %b' "$YELLOW" "$RESET"
                read -r GEN_SSH

                if [[ "${GEN_SSH,,}" != "n" ]]; then
                    printf '%bEmail for SSH key comment (blank for none): %b' "$YELLOW" "$RESET"
                    read -r SSH_COMMENT

                    printf '%bPassphrase for SSH key (blank = no passphrase): %b' "$YELLOW" "$RESET"
                    read -rs SSH_PASS
                    printf '\n'
                fi
            fi

            if [[ "${GEN_SSH,,}" != "n" ]]; then
                if [[ -z "${SSH_PASS:-}" ]]; then
                    warn "SSH key has no passphrase — key is unprotected at rest"
                fi

                run mkdir -p "${HOME}/.ssh"
                run chmod 700 "${HOME}/.ssh"

                # NOTE: ssh-keygen only accepts the passphrase via -N flag
                # (it reads from /dev/tty, NOT stdin or SSH_ASKPASS).
                # The -N value is transiently visible in /proc/*/cmdline.
                # Acceptable risk: Crostini is single-user, exposure is
                # sub-second, and the variable is zeroed immediately after.
                log "[EXEC] ssh-keygen -t ed25519 -f $SSH_KEY (passphrase redacted)"
                if [[ -n "${SSH_COMMENT:-}" ]]; then
                    ssh-keygen -t ed25519 -C "${SSH_COMMENT}" -f "$SSH_KEY" \
                        -N "${SSH_PASS:-}" >> "$LOG_FILE" 2>&1
                else
                    ssh-keygen -t ed25519 -f "$SSH_KEY" \
                        -N "${SSH_PASS:-}" >> "$LOG_FILE" 2>&1
                fi
                # Zero passphrase from memory immediately
                SSH_PASS=""

                if [[ -f "$SSH_KEY" ]]; then
                    run chmod 600 "$SSH_KEY"
                    run chmod 644 "${SSH_KEY}.pub"

                    log "SSH public key:"
                    tee -a "$LOG_FILE" < "${SSH_KEY}.pub" || true
                    printf '\n'
                    log "Add to GitHub/GitLab/servers as needed."
                fi
            else
                log "Skipping SSH key generation"
            fi
            unset GEN_SSH SSH_COMMENT SSH_PASS
        else
            log "[DRY-RUN] would prompt for SSH key generation"
        fi
    fi

    unset SSH_KEY
    set_checkpoint 18
    log "Step 18 complete."
fi
# Step 19: Container backup — opens ChromeOS backup page (--interactive)
if should_run_step 19; then
    step_banner 19 "Container backup"

    if ! $DRY_RUN && ! $UNATTENDED; then
        log "Opening ChromeOS backup page to snapshot this fresh setup..."
        printf '%b  → Click "Backup" to save your Linux container state.%b\n' "$YELLOW" "$RESET"
        printf '%b  → Do this periodically after major changes.%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/exportImport"
        sleep 2
        printf '%bPress Enter after backup completes (or to skip)...%b' "$YELLOW" "$RESET"
        read -r _
    elif $DRY_RUN; then
        log "[DRY-RUN] would open chrome://os-settings/crostini/exportImport"
    else
        log "Skipping interactive backup prompt (unattended mode)"
    fi

    set_checkpoint 19
    log "Step 19 complete."
fi
# Step 20: Summary and verification
if should_run_step 20; then
    step_banner 20 "Summary and verification"

    logprintf '\n%bCROSTINI SETUP COMPLETE%b\n\n' "$GREEN" "$RESET"

    # System
    logprintf '%bSystem:%b\n' "$BOLD" "$RESET"
    logprintf '  Architecture:  %s\n' "$(uname -m)"
    logprintf '  Kernel:        %s\n' "$(uname -r)"
    logprintf '  OS:            %s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
    # ChromeOS milestone
    if [[ -f /dev/.cros_milestone ]]; then
        logprintf '  ChromeOS:      milestone %s\n' "$(cat /dev/.cros_milestone)"
    fi
    logprintf '  Disk free:     %s MB\n' "$(($(df --output=avail / | tail -1 | tr -d ' ') / 1024))"
    logprintf '\n'

    # GPU
    logprintf '%bGPU / Graphics:%b\n' "$BOLD" "$RESET"
    if [[ -e /dev/dri/renderD128 ]]; then
        logprintf '  Render node:   %b✓%b /dev/dri/renderD128\n' "$GREEN" "$RESET"
        if command -v glxinfo &>/dev/null; then
            _glx_out="$(glxinfo 2>/dev/null || true)"
            GL_VENDOR="$(printf '%s\n' "$_glx_out" | grep "OpenGL vendor" | head -1 | cut -d: -f2 | xargs || true)"
            GL_RENDERER="$(printf '%s\n' "$_glx_out" | grep "OpenGL renderer" | head -1 | cut -d: -f2 | xargs || true)"
            GL_VERSION="$(printf '%s\n' "$_glx_out" | grep "OpenGL version" | head -1 | cut -d: -f2 | xargs || true)"
            unset _glx_out
            [[ -n "$GL_VENDOR" ]]   && printf '  GL vendor:     %s\n' "$GL_VENDOR"
            [[ -n "$GL_RENDERER" ]] && printf '  GL renderer:   %s\n' "$GL_RENDERER"
            [[ -n "$GL_VERSION" ]]  && printf '  GL version:    %s\n' "$GL_VERSION"
        fi
        if command -v vulkaninfo &>/dev/null; then
            _vk_out="$(vulkaninfo --summary 2>/dev/null || true)"
            VK_GPU="$(printf '%s\n' "$_vk_out" | grep "GPU name" | head -1 | cut -d= -f2 | xargs || true)"
            VK_API="$(printf '%s\n' "$_vk_out" | grep "apiVersion" | head -1 | cut -d= -f2 | xargs || true)"
            unset _vk_out
            if [[ -n "$VK_GPU" ]]; then
                logprintf '  Vulkan GPU:    %s\n' "$VK_GPU"
                [[ -n "$VK_API" ]] && printf '  Vulkan API:    %s\n' "$VK_API"
            else
                logprintf '  Vulkan:        not available (virgl does not support Vulkan)\n'
            fi
        fi
    elif [[ -d /dev/dri ]]; then
        logprintf '  Render node:   %b⚠ PARTIAL%b (/dev/dri exists, renderD128 missing)\n' "$YELLOW" "$RESET"
    else
        logprintf '  Render node:   %b✗ NOT ACTIVE%b\n' "$RED" "$RESET"
        logprintf '  Fix:           chrome://flags/#crostini-gpu-support → Enabled → Reboot\n'
    fi
    logprintf '\n'

    # Display
    logprintf '%bDisplay / Wayland:%b\n' "$BOLD" "$RESET"
    if pgrep -x sommelier &>/dev/null; then
        logprintf '  Sommelier:     %b✓%b running\n' "$GREEN" "$RESET"
    else
        logprintf '  Sommelier:     %b✗%b not running — restart terminal\n' "$RED" "$RESET"
    fi
    logprintf '  DISPLAY:       %s\n' "${DISPLAY:-not set}"
    logprintf '  WAYLAND:       %s\n' "${WAYLAND_DISPLAY:-not set}"
    logprintf '  GTK theme:     %s\n' "$(grep gtk-theme-name "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | cut -d= -f2 || echo 'default')"
    logprintf '  Xft DPI:       %s\n' "$(grep 'Xft.dpi' "${HOME}/.Xresources" 2>/dev/null | awk '{print $2}' || echo 'default')"
    logprintf '  Font:          %s\n' "$(grep gtk-font-name "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | cut -d= -f2 || echo 'default')"
    logprintf '\n'

    # Audio
    logprintf '%bAudio:%b\n' "$BOLD" "$RESET"
    if [[ -d /dev/snd ]]; then
        SND_DEV_COUNT=$(find /dev/snd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        logprintf '  ALSA devices:  %b✓%b %s device(s)\n' "$GREEN" "$RESET" "$SND_DEV_COUNT"
    else
        logprintf '  ALSA devices:  %b✗%b /dev/snd not found\n' "$RED" "$RESET"
    fi
    if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
        logprintf '  Microphone:    %b✓%b capture device present\n' "$GREEN" "$RESET"
    else
        logprintf '  Microphone:    %b✗%b not detected — enable in ChromeOS Linux settings\n' "$YELLOW" "$RESET"
    fi
    if command -v pactl &>/dev/null; then
        PA_STATUS="$(pactl info 2>/dev/null | grep "Server Name" | cut -d: -f2 | xargs || true)"
        if [[ -n "$PA_STATUS" ]]; then
            logprintf '  PulseAudio:    %b✓%b %s\n' "$GREEN" "$RESET" "$PA_STATUS"
        else
            logprintf '  PulseAudio:    %b⚠%b installed but not responding\n' "$YELLOW" "$RESET"
        fi
    fi
    logprintf '\n'

    # ChromeOS integration
    logprintf '%bChromeOS integration:%b\n' "$BOLD" "$RESET"
    if [[ -d /mnt/chromeos ]]; then
        mapfile -t _shared_arr < <(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d 2>/dev/null)
        SHARED_N=${#_shared_arr[@]}
        if [[ "$SHARED_N" -gt 0 ]]; then
            logprintf '  Shared dirs:   %b✓%b %s folder(s)\n' "$GREEN" "$RESET" "$SHARED_N"
            for d in "${_shared_arr[@]}"; do
                [[ -n "$d" ]] && printf '    %s\n' "$d"
            done
        else
            logprintf '  Shared dirs:   none — share via Files app → right-click → Share with Linux\n'
        fi
        unset _shared_arr SHARED_N
    fi
    logprintf '\n'

    # Installed tools
    logprintf '%bInstalled tools:%b\n' "$BOLD" "$RESET"

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
    check_tool "glmark2"     glmark2-es2-wayland
    check_tool "vulkaninfo"  vulkaninfo
    check_tool "pactl"       pactl
    check_tool "pavucontrol" pavucontrol
    check_tool "flatpak"     flatpak
    check_tool "dosbox"      dosbox
    check_tool "scummvm"     scummvm
    check_tool "code"        code
    check_tool "firefox-esr" firefox-esr
    check_tool "thunar"      thunar
    check_tool "evince"      evince
    check_tool "eog"         eog
    check_tool "file-roller" file-roller
    check_tool "gnome-screenshot" gnome-screenshot
    if flatpak list --app 2>/dev/null | grep -q org.libretro.RetroArch; then
        logprintf '  %-14s %b✓%b  Flatpak\n' "retroarch" "$GREEN" "$RESET"
    fi
    logprintf '\n'

    # Config files
    logprintf '%bConfig files written:%b\n' "$BOLD" "$RESET"

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
        logprintf '  %b⚠%b  %-44s %s\n' "$YELLOW" "$RESET" "Memory tuning (4 GB)" "skipped (vm.* read-only in container)"
    fi
    if command -v code &>/dev/null; then
        check_config "${HOME}/.config/code-flags.conf"           "VS Code Wayland"
    fi
    logprintf '\n'

    # Quick-test commands
    logprintf '%bQuick-test commands:%b\n' "$BOLD" "$RESET"
    logprintf '  GPU:     glxgears / glmark2-es2-wayland / vulkaninfo --summary\n'
    logprintf '  Audio:   pactl info / speaker-test -t wav -c 2 / pavucontrol\n'
    logprintf '  Display: xdpyinfo | grep resolution / xrandr\n'
    logprintf '  Fonts:   fc-match sans-serif / fc-match monospace\n'
    logprintf '\n'

    # Reminders
    logprintf '%bReminders:%b\n' "$YELLOW" "$RESET"
    logprintf '  • Steam is x86-only — no native ARM64 build exists\n'
    logprintf '  • box64/box86 (community x86 translation) exists but is\n'
    logprintf '    unsupported and unusable for gaming on 4 GB RAM / virgl GPU\n'
    logprintf '  • Cloud gaming: GeForce NOW / Xbox Cloud Gaming in ChromeOS browser\n'
    logprintf '  • Manual .deb downloads: always get the arm64 variant\n'
    logprintf '  • Flatpak apps: flatpak install flathub <app-id>\n'
    logprintf '  • Gaming (box86/Wine/GOG): see crostini-gaming-packages.txt\n'
    logprintf '  • If GPU not active: reboot entire Chromebook (not just container)\n'
    logprintf '\n'

    logprintf '%bLog file:%b %s\n' "$BOLD" "$RESET" "$LOG_FILE"

    # Clean up checkpoint
    if $DRY_RUN; then
        log "[DRY-RUN] would remove checkpoint file"
    else
        rm -f "$STEP_FILE"
        log "Checkpoint file removed. Setup fully complete."
    fi

    # Clean up step 20 variables
    unset GL_VENDOR GL_RENDERER GL_VERSION VK_GPU VK_API SND_DEV_COUNT PA_STATUS

    logprintf '\n%bRestart the Terminal app to apply all environment changes.%b\n\n' "$BOLD" "$RESET"
fi

exit 0
