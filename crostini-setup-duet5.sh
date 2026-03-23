#!/usr/bin/env bash
# crostini-setup-duet5.sh — Crostini post-install bootstrap for Lenovo Duet 5 (82QS0001US)
# Version: 4.9.0
# Date:    2026-03-22
# Arch:    aarch64 / arm64 (Qualcomm Snapdragon 7c Gen 2 — SC7180P)
# Target:  Debian Bookworm or Trixie container under ChromeOS Crostini
# Usage:   bash crostini-setup-duet5.sh [--dry-run] [--interactive] [--minimal] [--from-step=N] [--verify] [--reset] [--help] [--version]
# Fully unattended by default — use --interactive for ChromeOS toggle prompts.
# NOTE: Script uses sudo internally (~60 calls). Ensure sudo credential is cached (run `sudo true` first) or timestamp_timeout is adequate.
# WARNING: Steam is x86-only; box64/box86 community translation exists but is unusable on 4 GB RAM / virgl.
# NOTE: Crostini may ship Bookworm or Trixie. Package arrays use canonical (non-transitional) names that resolve on both.
# NOTE: Trixie mounts /tmp as tmpfs (RAM-backed). Downloads to /tmp (rustup installer) are transient and small (<100 MB); they are cleaned up in both normal flow and EXIT trap.

set -euo pipefail
# Restrict tempfiles/logs to owner-only by default
umask 077

# Constants
readonly SCRIPT_NAME="crostini-setup-duet5.sh"
readonly SCRIPT_VERSION="4.9.0"
readonly EXPECTED_ARCH="aarch64"
_log_ts="$(date +%Y%m%d-%H%M%S)" || { printf 'FATAL: date failed\n' >&2; exit 1; }
readonly LOG_FILE="${HOME}/crostini-setup-${_log_ts}.log"
readonly STEP_FILE="${HOME}/.crostini-setup-checkpoint"
readonly LOCK_FILE="${HOME}/.crostini-setup.lock"
readonly SYSCTL_CONF="/etc/sysctl.d/99-crostini-tuning.conf"
unset _log_ts
_start_epoch="$(date +%s)" || { printf 'FATAL: date failed\n' >&2; exit 1; }
readonly _START_EPOCH="$_start_epoch"
unset _start_epoch

# Create log file with restrictive permissions before any writes
if ! touch "$LOG_FILE" || ! chmod 600 "$LOG_FILE"; then
    printf 'FATAL: cannot create log file %s\n' "$LOG_FILE" >&2
    exit 1
fi

DRY_RUN=false
UNATTENDED=true
MINIMAL=false
_DEFERRED_CHECKPOINT=""
_DEFERRED_CHECKPOINT_MSG=""
_CHECKPOINT_OVERRIDE=""
_LOCK_ACQUIRED=false
_received_signal=""

# Signal handler — stores signal name, triggers EXIT trap via exit
# shellcheck disable=SC2317,SC2329
_handle_signal() { _received_signal="$1"; exit 1; }

# Cleanup trap
# shellcheck disable=SC2317,SC2329
cleanup() {
    local rc=$?
    # Prevent recursive cleanup from nested signals
    trap - EXIT INT TERM HUP PIPE QUIT
    # Disable set -e inside cleanup to guarantee full execution
    set +e
    # Strip ANSI escape codes from the log file in a single pass. This replaces the previous per-line sed approach (via process substitution) which was racy — the background sed could be killed before flushing.
    _strip_log_ansi
    # Remove temp files
    if [[ -n "${_rustup_tmp:-}" ]]; then rm -f "$_rustup_tmp" 2>/dev/null; fi
    if [[ -n "${_rustup_sha:-}" ]]; then rm -f "$_rustup_sha" 2>/dev/null; fi
    # Release lock only if this instance acquired it
    if $_LOCK_ACQUIRED && [[ -n "${LOCK_FILE:-}" ]]; then
        # Remove all files (pid + any orphaned tmpfiles from crash)
        find "$LOCK_FILE" -maxdepth 1 -type f -delete 2>/dev/null || true
        rmdir "$LOCK_FILE" 2>/dev/null || true
    fi
    if [[ "$rc" -ne 0 ]]; then
        # @@WHY: $SECONDS is a bash builtin — no subprocess, cannot hang. date(1) can hang on broken pipe / frozen cgroup; inside cleanup all traps are cleared, so a hang here is uninterruptible.
        local _elapsed="${SECONDS:-unknown}"
        _cleanup_warn "Script exited with code $rc after ${_elapsed}s. Re-run to resume from checkpoint."
    fi
    # Re-raise caught signal for correct 128+N exit code to parent
    if [[ -n "${_received_signal:-}" ]]; then
        kill -"$_received_signal" "$$"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap '_handle_signal INT' INT
trap '_handle_signal TERM' TERM
trap '_handle_signal HUP' HUP
trap '_handle_signal PIPE' PIPE
trap '_handle_signal QUIT' QUIT

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
readonly RED GREEN YELLOW BOLD RESET

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

# logprintf: printf to both stdout and log file. MUST be defined before step_banner.
logprintf() {
    # shellcheck disable=SC2059
    printf "$@"
    # shellcheck disable=SC2059
    printf "$@" >> "$LOG_FILE" 2>/dev/null || true
}

# _prompt: interactive prompt — stderr + log. All "Press Enter" lines route here for log trail.
_prompt() {
    # shellcheck disable=SC2059
    printf "$@" >&2
    # shellcheck disable=SC2059
    printf "$@" >> "$LOG_FILE" 2>/dev/null || true
}

# _cleanup_warn: log helper safe inside cleanup/trap. Uses $SECONDS (builtin, no subprocess).
# shellcheck disable=SC2317,SC2329
_cleanup_warn() {
    printf '%ss [WARN]  %s\n' "${SECONDS:-?}" "$*" >&2
    printf '%ss [WARN]  %s\n' "${SECONDS:-?}" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

# _strip_log_ansi: single-pass ANSI removal from log file. Called once at exit.
# shellcheck disable=SC2317,SC2329
_strip_log_ansi() {
    [[ -f "$LOG_FILE" ]] || return 0
    local _tmp
    _tmp="$(mktemp "${LOG_FILE}.strip_XXXXXXXX")" || { _cleanup_warn "Cannot create tmpfile for ANSI strip"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null || true
    if sed -e 's/\x1b\[[?]*[0-9;]*[A-Za-z]//g' -e 's/\x1b\][^\x07]*\x07//g' "$LOG_FILE" > "$_tmp" 2>/dev/null; then
        mv -- "$_tmp" "$LOG_FILE" 2>/dev/null || { rm -f "$_tmp"; _cleanup_warn "Cannot replace log after ANSI strip"; return 1; }
    else
        rm -f "$_tmp"
        _cleanup_warn "ANSI strip failed — log file retains escape codes"
        return 1
    fi
}

step_banner() {
    local num="$1" title="$2"
    logprintf '\n%bSTEP %s: %s%b\n\n' "$BOLD" "$num" "$title" "$RESET"
}

# Checkpoint system
get_checkpoint() {
    # In-memory override: set by --from-step/--verify so should_run_step works in --dry-run mode (where set_checkpoint is a no-op).
    if [[ -n "$_CHECKPOINT_OVERRIDE" ]]; then
        echo "$_CHECKPOINT_OVERRIDE"
        return 0
    fi
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
    # Atomic write: tmpfile + mv prevents empty/partial checkpoint on crash
    local _ckpt_tmp
    _ckpt_tmp="$(mktemp "${STEP_FILE}.tmp_XXXXXXXX")" || { warn "Cannot create checkpoint tmpfile"; return 1; }
    printf '%s\n' "$1" > "$_ckpt_tmp" || { rm -f "$_ckpt_tmp"; warn "Cannot write checkpoint"; return 1; }
    mv -- "$_ckpt_tmp" "$STEP_FILE" || { rm -f "$_ckpt_tmp"; warn "Cannot move checkpoint into place"; return 1; }
}

should_run_step() {
    local step_num="$1"
    local checkpoint
    checkpoint="$(get_checkpoint)"
    [[ "$step_num" -gt "$checkpoint" ]]
}

# _tee_log: tee stdin to terminal + log file. ANSI stripped at exit by _strip_log_ansi.
_tee_log() {
    tee -a "$LOG_FILE"
}

# run: execute "$@" directly; respects dry-run. stderr merged into stdout (2>&1) for log capture.
run() {
    if $DRY_RUN; then
        log "[DRY-RUN] $*"
        return 0
    fi
    log "[EXEC] $*"
    local rc _prev_e=false _prev_pf=false
    # Save caller's shell option state before disabling
    [[ "$-" == *e* ]] && _prev_e=true
    shopt -qo pipefail 2>/dev/null && _prev_pf=true
    # Temporarily disable errexit+pipefail so: 1) set -e doesn't kill us on pipeline failure 2) PIPESTATUS is not reset by an || guard
    set +eo pipefail
    "$@" 2>&1 | _tee_log
    # Capture PIPESTATUS atomically — any subsequent command resets it
    local _ps=("${PIPESTATUS[@]}")
    rc=${_ps[0]}
    local _tee_rc=${_ps[1]:-0}
    # Restore caller's shell options — never force-enable what wasn't set. Restore pipefail BEFORE errexit (see CHANGELOG 3.8.0): if pipefail was off, the old `false && set -o pipefail` returned 1, which killed the script under the just-restored set -e.  Using if/then avoids the non-zero exit code from a false && short-circuit entirely.
    if $_prev_pf; then set -o pipefail; fi
    if $_prev_e; then set -e; fi
    if [[ "$_tee_rc" -ne 0 ]]; then
        warn "Log pipeline failed (tee exit $_tee_rc) during: $*"
    fi
    if [[ "$rc" -ne 0 ]]; then
        warn "Command exited $rc: $*"
    fi
    return "$rc"
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
    # 644: standard for user config (GTK, fontconfig, Qt expect world-readable)
    chmod 644 "$tmp" || { rm -f "$tmp"; die "Cannot chmod $dest"; }
    mv -- "$tmp" "$dest" || { rm -f "$tmp"; die "Cannot move $dest into place"; }
    log "Wrote $dest"
}

# write_file_sudo: atomic write via sudo, respects dry-run. Output mode 644.
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
    sudo chmod 644 "$tmp" || { sudo rm -f "$tmp"; die "Cannot chmod tmpfile for $dest"; }
    sudo mv -- "$tmp" "$dest" || { sudo rm -f "$tmp"; die "Cannot move $dest into place"; }
    log "Wrote $dest (sudo)"
}

# install_pkgs_best_effort: batch install, fallback to per-package. Returns 1 if any failed.
install_pkgs_best_effort() {
    if $DRY_RUN; then
        log "[DRY-RUN] sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $*"
        return 0
    fi
    # Try batch first — succeeds in the common case (O(1) apt call)
    if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
        return 0
    fi
    # Batch failed — one or more packages unavailable; install individually
    warn "Batch install failed — falling back to per-package install"
    local pkg _fail_count=0 _total=$#
    for pkg in "$@"; do
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || { warn "Skipped unavailable: $pkg"; ((_fail_count++)) || true; }
    done
    if [[ "$_fail_count" -gt 0 ]]; then
        warn "install_pkgs_best_effort: ${_fail_count}/${_total} packages failed"
        return 1
    fi
    return 0
}

# Open URL in ChromeOS browser
open_chromeos_url() {
    local url="$1"
    log "Opening URL: $url"
    if command -v garcon-url-handler &>/dev/null; then
        garcon-url-handler "$url" 2>>"$LOG_FILE" || true
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>>"$LOG_FILE" || true
    else
        warn "Cannot auto-open URL. Manually navigate to: $url"
    fi
}

check_tool() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        local ver
        # Some tools (java, scummvm) output version to stderr; try stdout first
        ver="$(timeout 3 "$cmd" --version 2>/dev/null | head -1)" || true
        if [[ -z "$ver" ]]; then
            # Capture stderr-only (no pipe — avoids SIGPIPE on large output)
            ver="$(timeout 3 "$cmd" --version 2>&1 1>/dev/null)" || true
            ver="${ver%%$'\n'*}"
        fi
        logprintf '  %-14s %b✓%b  %s\n' "$name" "$GREEN" "$RESET" "$ver"
        ((_verify_pass++)) || true
    else
        logprintf '  %-14s %b✗%b  not found\n' "$name" "$RED" "$RESET"
        ((_verify_fail++)) || true
    fi
}

check_config() {
    local path="$1" desc="$2"
    if [[ -s "$path" ]]; then
        logprintf '  %b✓%b  %-44s %s\n' "$GREEN" "$RESET" "$desc" "$path"
        ((_verify_pass++)) || true
    elif [[ -f "$path" ]]; then
        logprintf '  %b⚠%b  %-44s %s (empty)\n' "$YELLOW" "$RESET" "$desc" "$path"
        ((_verify_warn++)) || true
    else
        logprintf '  %b✗%b  %-44s %s\n' "$RED" "$RESET" "$desc" "$path"
        ((_verify_fail++)) || true
    fi
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Crostini post-install bootstrap for Lenovo Duet 5 Chromebook (ARM64)

USAGE:
    bash ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    --dry-run      Print commands without executing
    --interactive  Prompt for ChromeOS toggles (default: unattended)
    --from-step=N  Start (or restart) from step N (1-15; N=15 is same as --verify)
    --verify       Run only step 15 (summary and verification)
    --minimal      Skip heavy optional packages (e.g. gnome-disk-utility)
    --help         Show this help message
    --version      Show version
    --reset        Clear checkpoint and start from step 1
    --             Stop processing options (remaining args ignored)

STEPS PERFORMED:
     1  Preflight checks (arch, Crostini, disk, network, root, sommelier)
     2  ChromeOS integration (GPU, mic, USB, folders, ports, disk;
        --interactive opens ChromeOS settings pages for each toggle)
     3  Upgrade to Trixie and full system update
     4  Core CLI utilities (ripgrep, fd, fzf, bat, tmux, jq, curl,
        htop, wl-clipboard, ...)
     5  Build essentials and development headers
     6  GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan, glmark2)
     7  Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol)
     8  Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt,
        Xft DPI 120, fontconfig, cursor)
     9  GUI applications (Firefox ESR, Chromium, Thunar, Evince, xterm, fonts, screenshots, MIME defaults)
    10  Rust stable aarch64 via rustup
    11  Container resource tuning (sysctl, locale, env, XDG, paths, memory)
    12  Flatpak + Flathub (ARM64 app source)
    13  Gaming packages (DOSBox-X, DOSBox, ScummVM, RetroArch)
    14  Container backup (opens ChromeOS backup page with --interactive)
    15  Summary and verification

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
        --from-step=*)
            if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
                die "Cannot specify --from-step more than once, or combine with --verify"
            fi
            _from="${arg#*=}"
            if [[ ! "$_from" =~ ^[0-9]+$ ]] || [[ "$_from" -lt 1 ]] || [[ "$_from" -gt 15 ]]; then
                die "--from-step requires a number 1-15 (got '${_from}')"
            fi
            # Defer checkpoint write until after lock acquisition (avoids race)
            _DEFERRED_CHECKPOINT="$((_from - 1))"
            _DEFERRED_CHECKPOINT_MSG="Checkpoint set to step $((_from - 1)); will resume from step ${_from}."
            unset _from
            ;;
        --verify)
            if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
                die "Cannot specify --verify more than once, or combine with --from-step"
            fi
            # Defer checkpoint write until after lock acquisition (avoids race)
            _DEFERRED_CHECKPOINT="14"
            _DEFERRED_CHECKPOINT_MSG="Checkpoint set to 14; running verification only."
            ;;
        --minimal) MINIMAL=true ;;
        --help)    rm -f "$LOG_FILE" 2>/dev/null; usage ;;
        --version) rm -f "$LOG_FILE" 2>/dev/null; echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
        --reset)
            if [[ -d "$LOCK_FILE" ]]; then
                _rpid="$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")"
                if [[ -n "$_rpid" ]] && kill -0 "$_rpid" 2>/dev/null; then
                    die "Another instance (PID ${_rpid}) is running. Cannot reset while active."
                fi
                # Process dead or no PID — remove stale lock (incl. orphaned tmpfiles)
                find "$LOCK_FILE" -maxdepth 1 -type f -delete 2>/dev/null || true
                rmdir "$LOCK_FILE" 2>/dev/null || die "Cannot remove lock dir ${LOCK_FILE} — remove manually"
                unset _rpid
            fi
            rm -f "$STEP_FILE"; rm -f "$LOG_FILE" 2>/dev/null; echo "Checkpoint and lock cleared."; exit 0
            ;;
        --)        break ;;
        --from-step)
            die "--from-step requires =N syntax, e.g. --from-step=5" ;;
        -*)        die "Unknown option: $arg. Use --help for usage." ;;
        *)         die "Unknown argument: $arg. Use --help for usage." ;;
    esac
done

# Acquire exclusive lock (PID-based stale detection for crash recovery)
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    _old_pid="$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")"
    if [[ -z "$_old_pid" ]]; then
        # PID file missing/empty (crash between mkdir and PID write) — treat as stale
        warn "Removing stale lock (no PID file — likely prior crash)"
        find "$LOCK_FILE" -maxdepth 1 -type f -delete 2>/dev/null || true
        rmdir "$LOCK_FILE" 2>/dev/null || die "Cannot remove stale lock dir ${LOCK_FILE} — remove manually"
        mkdir "$LOCK_FILE" || die "Cannot re-acquire lock after stale removal"
    elif ! kill -0 "$_old_pid" 2>/dev/null; then
        warn "Removing stale lock from dead PID $_old_pid"
        find "$LOCK_FILE" -maxdepth 1 -type f -delete 2>/dev/null || true
        rmdir "$LOCK_FILE" 2>/dev/null || die "Cannot remove stale lock dir ${LOCK_FILE} — remove manually"
        mkdir "$LOCK_FILE" || die "Cannot re-acquire lock after stale removal"
    else
        die "Another instance (PID ${_old_pid}) is running (lock: ${LOCK_FILE}). Remove manually if stale."
    fi
    unset _old_pid
fi
_pid_tmp="$(mktemp "$LOCK_FILE/.pid_XXXXXXXX")" \
    || die "Cannot create PID tmpfile"
printf '%s\n' "$$" > "$_pid_tmp"
mv -- "$_pid_tmp" "$LOCK_FILE/pid" \
    || { rm -f "$_pid_tmp"; die "Cannot write PID file"; }
_LOCK_ACQUIRED=true
unset _pid_tmp

# Apply deferred checkpoint (must be inside lock to avoid race with concurrent instances)
if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
    # In-memory override ensures should_run_step works even in --dry-run (where set_checkpoint is a no-op and the file is never written).
    _CHECKPOINT_OVERRIDE="$_DEFERRED_CHECKPOINT"
    set_checkpoint "$_DEFERRED_CHECKPOINT" || die "Cannot write checkpoint file ${STEP_FILE} — is \$HOME writable?"
    log "$_DEFERRED_CHECKPOINT_MSG"
fi
unset _DEFERRED_CHECKPOINT _DEFERRED_CHECKPOINT_MSG

# Set noninteractive for any direct (non-sudo) dpkg/apt invocations. NOTE: sudo strips this (env_reset); all sudo apt-get calls pass it explicitly.
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

    # 1a2. Bash version (mapfile, PIPESTATUS, local -a require bash 4+; 5.0 for consistency)
    if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
        die "Requires bash 5.0+ (got ${BASH_VERSION:-unknown}). Crostini ships bash 5.x by default."
    fi

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
        _os_codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-bookworm}")"
        log "Container OS: ${_os_pretty} (${_os_codename}) ✓"
        unset _os_pretty
    else
        _os_codename="bookworm"
    fi

    # 1d. Disk space check (need at least 2 GB free)
    AVAIL_KB="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')" || true
    if [[ ! "$AVAIL_KB" =~ ^[0-9]+$ ]]; then
        die "Cannot determine available disk space (df returned '${AVAIL_KB:-empty}')"
    fi
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [[ "$AVAIL_MB" -lt 2048 ]]; then
        die "Insufficient disk space: ${AVAIL_MB} MB available, need at least 2048 MB. Resize: Settings → Developers → Linux → Disk size."
    fi
    log "Available disk: ${AVAIL_MB} MB ✓"

    # 1e. GPU acceleration warning (disabled by default since ChromeOS 131)
    if [[ ! -e /dev/dri/renderD128 ]]; then
        warn "IMPORTANT: GPU acceleration is disabled by default since ChromeOS 131."
        warn "Enable: chrome://flags#crostini-gpu-support → Enabled → full Chromebook reboot."
        warn "GPU packages will be installed regardless; /dev/dri/renderD128 requires the flag."
    else
        log "GPU render node: /dev/dri/renderD128 already active ✓"
    fi

    # 1f. Network connectivity (uses detected codename for repo URL)
    if $DRY_RUN; then
        log "[DRY-RUN] skip network check"
    elif curl -fsS --connect-timeout 3 --max-time 5 "https://deb.debian.org/debian/dists/${_os_codename}/Release.gpg" -o /dev/null 2>/dev/null; then
        log "Network connectivity: ✓"
    else
        warn "Cannot reach deb.debian.org. Some steps may fail without network."
    fi

    # 1g. Not running as root
    if [[ "$EUID" -eq 0 ]]; then
        if $DRY_RUN; then
            warn "[DRY-RUN] Running as root. Would abort in live mode."
        else
            die "Do not run this script as root. Run as your normal user (sudo is used internally where needed)."
        fi
    fi
    log "Running as user: $(whoami) ✓"

    # 1h. Sommelier (Wayland bridge) — needed for all GUI apps
    if pgrep -x sommelier &>/dev/null; then
        log "Sommelier (Wayland bridge): running ✓"
    else
        warn "Sommelier not detected. GUI apps may not display until container restarts."
    fi

    unset CURRENT_ARCH AVAIL_KB AVAIL_MB _os_codename
    set_checkpoint 1
    log "Step 1 complete."
fi
# Step 2: ChromeOS integration (GPU, mic, USB, folders, ports, disk)
if should_run_step 2; then
    step_banner 2 "ChromeOS integration (GPU, mic, USB, folders, ports, disk)"

    # 2a. GPU acceleration
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU acceleration: ALREADY ACTIVE ✓"
    else
        log "GPU acceleration not detected."
        if ! $DRY_RUN; then
            if ! $UNATTENDED; then
                _prompt '%b  → The chrome://flags page is opening in ChromeOS now.%b\n' "$YELLOW" "$RESET"
                _prompt '%b  → Search for "crostini-gpu-support" and set to "Enabled".%b\n' "$YELLOW" "$RESET"
                _prompt '%b  → A full Chromebook reboot is required for GPU to activate.%b\n' "$YELLOW" "$RESET"
                _prompt '%b  → GPU packages will be installed now regardless.%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://flags/#crostini-gpu-support"
                sleep 2
                _prompt '%bPress Enter after enabling the flag (or to continue)...%b' "$YELLOW" "$RESET"
                read -r -t 300 _ </dev/tty || true
            fi
            if [[ -e /dev/dri/renderD128 ]]; then
                log "GPU acceleration now active ✓"
            else
                warn "GPU not yet active — requires full Chromebook reboot. Continuing."
            fi
        else
            if ! $UNATTENDED; then
                log "[DRY-RUN] would open chrome://flags/#crostini-gpu-support"
            else
                log "[DRY-RUN] GPU flag check skipped (unattended; use --interactive to open chrome://flags)"
            fi
        fi
    fi

    # 2b. Microphone access
    if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
        log "Microphone capture device: detected ✓"
    else
        log "Microphone not detected."
        if ! $DRY_RUN; then
            if ! $UNATTENDED; then
                _prompt '%b  → Toggle "Allow Linux to access your microphone" → On%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://os-settings/crostini"
                sleep 2
                _prompt '%bPress Enter after enabling microphone (or to continue)...%b' "$YELLOW" "$RESET"
                read -r -t 300 _ </dev/tty || true
            fi
            if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
                log "Microphone now available ✓"
            else
                warn "Microphone still not detected. May need container restart."
            fi
        else
            if ! $UNATTENDED; then
                log "[DRY-RUN] would open chrome://os-settings/crostini for mic toggle"
            else
                log "[DRY-RUN] mic toggle skipped (unattended; use --interactive to open settings)"
            fi
        fi
    fi

    # 2c. USB device passthrough
    if ! $DRY_RUN && ! $UNATTENDED; then
        log "Opening USB device management..."
        _prompt '%b  → Toggle on any USB devices you need (drives, Arduino, etc.)%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/usbPreferences"
        sleep 2
        _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r -t 300 _ </dev/tty || true
    elif $DRY_RUN && ! $UNATTENDED; then
        log "[DRY-RUN] would open chrome://os-settings/crostini/usbPreferences"
    fi

    # 2d. Shared folders
    if [[ -d /mnt/chromeos ]]; then
        SHARED_COUNT="$(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d 2>/dev/null | wc -l)" || true
        if [[ "$SHARED_COUNT" -gt 0 ]]; then
            log "Shared ChromeOS folders: ${SHARED_COUNT} detected ✓"
        else
            log "No shared folders."
            if ! $DRY_RUN && ! $UNATTENDED; then
                _prompt '%b  → Click "Share folder" to make ChromeOS folders visible at /mnt/chromeos/%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://os-settings/crostini/sharedPaths"
                sleep 2
                _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
                read -r -t 300 _ </dev/tty || true
            elif $DRY_RUN && ! $UNATTENDED; then
                log "[DRY-RUN] would open chrome://os-settings/crostini/sharedPaths"
            fi
        fi
        unset SHARED_COUNT
    fi

    # 2e. Port forwarding
    if ! $DRY_RUN && ! $UNATTENDED; then
        log "Opening port forwarding settings..."
        _prompt '%b  → Add any dev server ports (3000, 5000, 8080, etc.)%b\n' "$YELLOW" "$RESET"
        _prompt '%b  → Crostini also auto-detects listening ports in most cases.%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/portForwarding"
        sleep 2
        _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r -t 300 _ </dev/tty || true
    elif $DRY_RUN && ! $UNATTENDED; then
        log "[DRY-RUN] would open chrome://os-settings/crostini/portForwarding"
    fi

    # 2f. Disk size check
    _avail_raw="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')" || true
    if [[ "$_avail_raw" =~ ^[0-9]+$ ]]; then
        AVAIL_MB_NOW=$((_avail_raw / 1024))
    else
        warn "Cannot determine available disk space"
        # Skip resize advisory on df failure
        AVAIL_MB_NOW=99999
    fi
    unset _avail_raw
    if [[ "$AVAIL_MB_NOW" -lt 10240 ]]; then
        log "Disk under 10 GB free."
        if ! $DRY_RUN && ! $UNATTENDED; then
            _prompt '%b  → Consider increasing Linux disk allocation (20-30 GB recommended).%b\n\n' "$YELLOW" "$RESET"
            open_chromeos_url "chrome://os-settings/crostini"
            sleep 2
            _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
            read -r -t 300 _ </dev/tty || true
        elif $DRY_RUN && ! $UNATTENDED; then
            log "[DRY-RUN] would open chrome://os-settings/crostini for disk resize"
        fi
    else
        log "Disk space: ${AVAIL_MB_NOW} MB free — adequate"
    fi

    unset AVAIL_MB_NOW
    set_checkpoint 2
    log "Step 2 complete."
fi
# Step 3: Upgrade to Trixie and full system update
if should_run_step 3; then
    step_banner 3 "Upgrade to Trixie and full system update"

    # Enable HTTP pipelining — sends multiple requests per TCP connection. Queue-Mode "access" allows parallel connections across URIs. Pipeline-Depth 4 balances throughput vs. 4 GB RAM constraint. NOTE: Pipeline-Depth applies to HTTP only; HTTPS repos (Debian default) benefit from Queue-Mode parallelism but not HTTP pipelining.
    APT_PARALLEL="/etc/apt/apt.conf.d/90parallel"
    if [[ ! -f "$APT_PARALLEL" ]]; then
        write_file_sudo "$APT_PARALLEL" <<'EOF'
// apt download tuning — managed by crostini-setup-duet5.sh
Acquire::Queue-Mode "access";
Acquire::http::Pipeline-Depth "4";
Acquire::Languages "none";
// Retry transient failures (WiFi drops, CDN hiccups) — critical for mobile device
Acquire::Retries "3";
EOF
    else
        log "Parallel apt config already exists"
    fi
    unset APT_PARALLEL

    # 3a. Upgrade to Trixie if still on Bookworm (or any pre-Trixie release)
    _cur_codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")" || true
    if [[ -n "$_cur_codename" ]] && [[ ! "$_cur_codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
        die "VERSION_CODENAME '${_cur_codename}' contains unexpected characters — aborting upgrade"
    fi
    if [[ "$_cur_codename" != "trixie" ]] && [[ -n "$_cur_codename" ]]; then
        log "Current release: ${_cur_codename} — upgrading to Trixie (Debian 13)"
        if $DRY_RUN; then
            log "[DRY-RUN] cp /etc/apt/sources.list /etc/apt/sources.list.pre-trixie"
            log "[DRY-RUN] sed -i 's/${_cur_codename}/trixie/g' /etc/apt/sources.list"
            log "[DRY-RUN] cp /etc/apt/sources.list.d/cros.list /etc/apt/cros.list.pre-trixie (if exists)"
            log "[DRY-RUN] sed -i 's/${_cur_codename}/trixie/g' /etc/apt/sources.list.d/cros.list (if exists)"
            log "[DRY-RUN] sed -i 's/${_cur_codename}/trixie/g' on additional .list/.sources in sources.list.d/ (with backup to /etc/apt/)"
            log "[DRY-RUN] sudo DEBIAN_FRONTEND=noninteractive apt-get update"
            log "[DRY-RUN] sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
            log "[DRY-RUN] sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
            log "[DRY-RUN] sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y"
        else
            # Back up sources before rewriting
            if ! run sudo cp /etc/apt/sources.list /etc/apt/sources.list.pre-trixie; then
                die "Cannot back up /etc/apt/sources.list — aborting upgrade"
            fi
            # Rewrite: bookworm → trixie (also handles bullseye or any older codename)
            if ! run sudo sed -i "s/${_cur_codename}/trixie/g" /etc/apt/sources.list; then
                warn "sources.list rewrite failed — restoring backup"
                run sudo cp -- /etc/apt/sources.list.pre-trixie /etc/apt/sources.list \
                    || die "Cannot restore sources.list backup — manual fix required"
                die "Trixie upgrade aborted"
            fi
            log "Rewrote /etc/apt/sources.list: ${_cur_codename} → trixie"
            # Also update cros-packages repo if present (Crostini-managed) NOTE: cros.list may reset on container restart; this handles the current session so the full-upgrade resolves all dependencies.
            if [[ -f /etc/apt/sources.list.d/cros.list ]]; then
                run sudo cp /etc/apt/sources.list.d/cros.list /etc/apt/cros.list.pre-trixie || true
                if run sudo sed -i "s/${_cur_codename}/trixie/g" /etc/apt/sources.list.d/cros.list; then
                    log "Rewrote cros.list: ${_cur_codename} → trixie"
                    warn "NOTE: cros.list resets on container restart (ChromeOS regenerates it)"
                    warn "Debian repos in sources.list are permanent — only cros-packages affected"
                else
                    warn "cros.list rewrite failed — continuing (non-fatal)"
                fi
            fi
            # Also handle -security and -updates sources if in separate files Handle both legacy .list format and deb822 .sources format Backups stored in /etc/apt/ (not sources.list.d/) to avoid APT "Ignoring file" warnings on unrecognized extensions.
            for _sfile in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                [[ -f "$_sfile" ]] || continue
                if grep -q "${_cur_codename}" "$_sfile" 2>/dev/null; then
                    _sfile_bak="/etc/apt/$(basename "$_sfile").pre-trixie"
                    run sudo cp -- "$_sfile" "$_sfile_bak" \
                        || { warn "Cannot back up ${_sfile} — skipping"; continue; }
                    run sudo sed -i "s/${_cur_codename}/trixie/g" "$_sfile" \
                        || warn "Failed to update ${_sfile} — backup at ${_sfile_bak}"
                fi
            done
            unset _sfile _sfile_bak
        fi
    elif [[ "$_cur_codename" == "trixie" ]]; then
        log "Already running Trixie — no upgrade needed"
    else
        warn "Cannot determine current release codename — skipping Trixie upgrade"
    fi
    unset _cur_codename

    # 3b. Update, upgrade, full-upgrade (also serves as Trixie dist-upgrade)
    if run sudo DEBIAN_FRONTEND=noninteractive apt-get update; then
        # --force-confdef --force-confold: accept package maintainer defaults for new conffiles, keep existing modified conffiles. Without these, dpkg can prompt interactively during upgrades even with DEBIAN_FRONTEND=noninteractive (which sudo strips via env_reset unless sudoers has env_keep).
        run sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            || warn "apt upgrade had issues"
        run sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            || warn "apt-get full-upgrade had issues"
    else
        warn "apt update failed — skipping upgrade/full-upgrade (stale package indices)"
    fi
    run sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y || warn "apt autoremove had issues"

    # 3c. Verify upgrade landed on Trixie
    if ! $DRY_RUN; then
        _post_codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")" || true
        if [[ "$_post_codename" == "trixie" ]]; then
            log "Trixie upgrade verified: $(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Debian 13}")"
        elif [[ -n "$_post_codename" ]]; then
            warn "Expected trixie after upgrade, got ${_post_codename} — partial upgrade?"
            warn "Re-run the script or manually: sudo apt update && sudo apt full-upgrade"
        fi
        unset _post_codename
    fi

    # 3d. Mitigate /tmp tmpfs OOM — Trixie mounts /tmp as RAM-backed tmpfs; on 4 GB this risks OOM during large builds or downloads. Cap at 512M.
    _TMP_DROPIN="/etc/systemd/system/tmp.mount.d/override.conf"
    if [[ ! -f "$_TMP_DROPIN" ]]; then
        if $DRY_RUN; then
            log "[DRY-RUN] cap /tmp tmpfs at 512M via drop-in (if tmp.mount active)"
        elif systemctl is-active --quiet tmp.mount 2>/dev/null; then
            write_file_sudo "$_TMP_DROPIN" <<'TMPEOF'
[Mount]
Options=mode=1777,nosuid,nodev,size=512M
TMPEOF
            run sudo systemctl daemon-reload \
                || warn "daemon-reload failed — /tmp cap takes effect on next container start"
            log "/tmp tmpfs capped at 512M (OOM mitigation)"
        else
            log "/tmp not mounted as tmpfs — no mitigation needed"
        fi
    else
        log "tmp.mount drop-in already exists"
    fi
    unset _TMP_DROPIN

    # 3e. Migrate APT sources to deb822 format (Trixie recommendation) apt modernize-sources converts .list → .sources with Signed-By. Non-fatal: old format is supported until at least 2029.
    if command -v apt &>/dev/null; then
        if $DRY_RUN; then
            log "[DRY-RUN] apt -y modernize-sources"
        elif apt modernize-sources --help &>/dev/null; then
            if run sudo DEBIAN_FRONTEND=noninteractive apt -y modernize-sources; then
                log "APT sources migrated to deb822 format"
                # Guard: modernize-sources may create cros.sources while cros.list remains, causing duplicate entries. Remove the .list if its .sources equivalent was created.
                if [[ -f /etc/apt/sources.list.d/cros.sources ]] && [[ -f /etc/apt/sources.list.d/cros.list ]]; then
                    if run sudo mv -- /etc/apt/sources.list.d/cros.list /etc/apt/cros.list.pre-modernize; then
                        log "Removed duplicate cros.list (modernize-sources created cros.sources)"
                    else
                        warn "cros.list duplicate removal failed — both cros.list and cros.sources may exist"
                    fi
                fi
            else
                warn "apt modernize-sources failed — old format still works"
            fi
        else
            log "apt modernize-sources not available (pre-Trixie apt) — skipping"
        fi
    fi

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

        # Wayland clipboard (wl-copy / wl-paste for terminal ↔ GUI integration)
        wl-clipboard
    )

    install_pkgs_best_effort "${CORE_PKGS[@]}" || warn "Some core CLI packages unavailable — non-fatal"

    # Create common symlinks for renamed Debian packages
    if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        if run sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd; then
            $DRY_RUN || log "Symlinked fdfind → fd"
        else
            warn "Symlink fdfind → fd failed"
        fi
    fi
    if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        if run sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat; then
            $DRY_RUN || log "Symlinked batcat → bat"
        else
            warn "Symlink batcat → bat failed"
        fi
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

    install_pkgs_best_effort "${DEV_PKGS[@]}" || warn "Some dev packages unavailable — non-fatal"

    unset DEV_PKGS
    set_checkpoint 5
    log "Step 5 complete."
fi
# Step 6: GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan, glmark2)
if should_run_step 6; then
    step_banner 6 "GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan, glmark2)"

    # Stable packages — canonical names (resolve on both Bookworm and Trixie arm64) libegl1/libgles2 are the real packages; the -mesa transitionals depend on them
    GPU_STABLE_PKGS=(
        mesa-utils
        libgl1-mesa-dri
        libegl1
        libgles2
        libvulkan1
        libwayland-client0
        libwayland-egl1
        x11-utils
        x11-xserver-utils
        xdg-desktop-portal
        xdg-desktop-portal-gtk
    )

    install_pkgs_best_effort "${GPU_STABLE_PKGS[@]}" || warn "Some GPU packages unavailable — non-fatal"

    # Volatile packages — names may differ across Debian versions libgl1 replaces the transitional libgl1-mesa-glx
    GPU_VOLATILE_PKGS=(
        mesa-vulkan-drivers
        libgl1
        vulkan-tools
        glmark2-wayland
        glmark2-es2-wayland
    )

    # Per-package fallback for volatile names — GPU package names change between versions
    install_pkgs_best_effort "${GPU_VOLATILE_PKGS[@]}" || warn "Some volatile GPU packages unavailable — expected across Debian versions"

    # Verify GPU
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU render node: /dev/dri/renderD128 ✓"
        if command -v glxinfo &>/dev/null; then
            _glx_out="$(glxinfo 2>/dev/null || true)"
            GL_VENDOR="$(printf '%s\n' "$_glx_out" | grep "OpenGL vendor" | head -1 | cut -d: -f2 | xargs -r || true)"
            GL_RENDERER="$(printf '%s\n' "$_glx_out" | grep "OpenGL renderer" | head -1 | cut -d: -f2 | xargs -r || true)"
            GL_VERSION="$(printf '%s\n' "$_glx_out" | grep "OpenGL version" | head -1 | cut -d: -f2 | xargs -r || true)"
            unset _glx_out
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
# Crostini GPU acceleration environment — managed by crostini-setup-duet5.sh
# Wayland EGL
EGL_PLATFORM=wayland
# GTK4 dark mode
GTK_THEME=Adwaita:dark

# Force virgl driver — prevents Mesa 25.x Zink regression (zen-browser/desktop#12276).
# Reverses the 4.7.7 removal: Zink crash risk now outweighs auto-detect benefit.
MESA_LOADER_DRIVER_OVERRIDE=virgl
GALLIUM_DRIVER=virgl

# Disable GL error checking (~5-10% CPU savings in games/emulators)
# Unset for debugging: env -u MESA_NO_ERROR <command>
MESA_NO_ERROR=1

# Shader cache: single file reduces eMMC random I/O; 512 MB cap prevents disk bloat
MESA_SHADER_CACHE_DISABLE=false
MESA_SHADER_CACHE_MAX_SIZE=512M
MESA_DISK_CACHE_SINGLE_FILE=1
EOF
    elif ! grep -q 'MESA_LOADER_DRIVER_OVERRIDE' "$GPU_ENV_FILE"; then
        log "Upgrading gpu.conf: adding Mesa driver override and shader cache vars"
        write_file "$GPU_ENV_FILE" <<'EOF'
# Crostini GPU acceleration environment — managed by crostini-setup-duet5.sh
# Wayland EGL
EGL_PLATFORM=wayland
# GTK4 dark mode
GTK_THEME=Adwaita:dark

# Force virgl driver — prevents Mesa 25.x Zink regression (zen-browser/desktop#12276).
# Reverses the 4.7.7 removal: Zink crash risk now outweighs auto-detect benefit.
MESA_LOADER_DRIVER_OVERRIDE=virgl
GALLIUM_DRIVER=virgl

# Disable GL error checking (~5-10% CPU savings in games/emulators)
# Unset for debugging: env -u MESA_NO_ERROR <command>
MESA_NO_ERROR=1

# Shader cache: single file reduces eMMC random I/O; 512 MB cap prevents disk bloat
MESA_SHADER_CACHE_DISABLE=false
MESA_SHADER_CACHE_MAX_SIZE=512M
MESA_DISK_CACHE_SINGLE_FILE=1
EOF
    else
        log "GPU env already up to date — skipping"
    fi

    unset GL_VENDOR GL_RENDERER GL_VERSION GPU_ENV_FILE GPU_STABLE_PKGS GPU_VOLATILE_PKGS
    set_checkpoint 6
    log "Step 6 complete."
fi
# Step 7: Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol)
if should_run_step 7; then
    step_banner 7 "Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol)"

    AUDIO_PKGS=(
        # ALSA — libasound2 (Bookworm) / libasound2t64 (Trixie) pulled in by alsa-utils and libasound2-plugins; no explicit listing needed.
        alsa-utils
        libasound2-plugins

        # PipeWire audio — Crostini uses PipeWire since Bullseye. pipewire-audio metapackage: pipewire + wireplumber + pipewire-pulse + pipewire-alsa
        pipewire-audio

        # PulseAudio client utilities + GUI mixer
        pulseaudio-utils
        pavucontrol

        # GStreamer codecs and media support gstreamer1.0-pulseaudio was removed; its PulseAudio plugin is in gstreamer1.0-plugins-good.
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-alsa
    )

    install_pkgs_best_effort "${AUDIO_PKGS[@]}" || warn "Some audio packages unavailable — non-fatal"

    # Mask legacy PulseAudio daemon if present (conflicts with PipeWire) Ensure PipeWire audio chain is active
    if ! $DRY_RUN; then
        if dpkg -l pulseaudio 2>/dev/null | grep -q '^ii'; then
            if run systemctl --user mask --now pulseaudio.service && \
               run systemctl --user mask --now pulseaudio.socket; then
                log "PulseAudio daemon masked (PipeWire provides pulse compatibility)"
            else
                warn "PulseAudio mask failed — PipeWire may conflict"
            fi
        fi
        if run systemctl --user enable --now pipewire.socket; then
            log "pipewire.socket enabled"
        else
            warn "pipewire.socket enable failed"
        fi
        if run systemctl --user enable --now pipewire-pulse.socket; then
            log "pipewire-pulse.socket enabled"
        else
            warn "pipewire-pulse.socket enable failed"
        fi
    else
        log "[DRY-RUN] systemctl --user mask --now pulseaudio.service (if installed)"
        log "[DRY-RUN] systemctl --user enable --now pipewire.socket"
        log "[DRY-RUN] systemctl --user enable --now pipewire-pulse.socket"
    fi

    # libavcodec-extra (~80 MB of codec libraries) — skip with --minimal
    if ! $MINIMAL; then
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libavcodec-extra \
            || warn "libavcodec-extra unavailable — media codec support may be limited"
    else
        log "Skipping libavcodec-extra (--minimal mode)"
    fi

    # Verify audio
    if [[ -d /dev/snd ]]; then
        SND_DEV_COUNT="$(find /dev/snd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" || true
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
        write_file "$AUDIO_ENV_FILE" <<'EOF'
# Crostini audio environment
# PipeWire provides PulseAudio socket natively via pipewire-pulse
EOF
    else
        log "Audio env already exists — skipping"
    fi

    # PipeWire quantum override — reduce buffer for lower audio latency
    _PW_QUANTUM="/etc/pipewire/pipewire.conf.d/99-quantum.conf"
    if [[ ! -f "$_PW_QUANTUM" ]]; then
        write_file_sudo "$_PW_QUANTUM" <<'QEOF'
context.properties = {
    default.clock.quantum = 256
}
QEOF
    else
        log "PipeWire quantum override already exists"
    fi
    unset _PW_QUANTUM

    # PipeWire user-level gaming overrides — counteract KVM VM auto-detection
    # that forces min-quantum=1024 (21.3 ms). See SPEC §5.2.
    _PW_GAMING="${HOME}/.config/pipewire/pipewire.conf.d/10-crostini-gaming.conf"
    if [[ ! -f "$_PW_GAMING" ]]; then
        run mkdir -p "${HOME}/.config/pipewire/pipewire.conf.d" || true
        write_file "$_PW_GAMING" <<'PWEOF'
# PipeWire core overrides for Crostini gaming — managed by crostini-setup-duet5.sh
# Counteracts PipeWire's KVM auto-detection which forces min-quantum=1024 (21.3 ms).
# Quantum 256 at 48 kHz = 5.3 ms latency — optimal for SC7180P under gaming load.

context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum       = 256
    default.clock.min-quantum   = 256
    default.clock.max-quantum   = 1024
    clock.power-of-two-quantum  = true
}

context.properties.rules = [
    {   # Explicitly override KVM VM detection that forces min-quantum=1024
        matches = [ { cpu.vm.name = "KVM" } ]
        actions = {
            update-props = {
                default.clock.min-quantum = 256
            }
        }
    }
]
PWEOF
    else
        log "PipeWire gaming config already exists"
    fi
    unset _PW_GAMING

    # PipeWire-Pulse user-level gaming override — disable pulse-layer VM quantum override
    _PW_PULSE_GAMING="${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-crostini-gaming.conf"
    if [[ ! -f "$_PW_PULSE_GAMING" ]]; then
        run mkdir -p "${HOME}/.config/pipewire/pipewire-pulse.conf.d" || true
        write_file "$_PW_PULSE_GAMING" <<'PPEOF'
# PipeWire PulseAudio layer overrides for Crostini — managed by crostini-setup-duet5.sh
# vm.overrides={} disables the PulseAudio-layer VM quantum override independently
# of the core graph override in pipewire.conf.d/.

pulse.properties = {
    pulse.min.req     = 256/48000
    pulse.default.req = 256/48000
    pulse.min.quantum = 256/48000
    vm.overrides      = {}
}
PPEOF
    else
        log "PipeWire-Pulse gaming config already exists"
    fi
    unset _PW_PULSE_GAMING

    unset AUDIO_PKGS AUDIO_ENV_FILE SND_DEV_COUNT
    set_checkpoint 7
    log "Step 7 complete."
fi
# Step 8: Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt, Xft DPI 120, fontconfig, cursor)
if should_run_step 8; then
    step_banner 8 "Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt, Xft DPI 120, fontconfig, cursor)"

    # 13.3in FHD OLED — configure sommelier, GTK 2/3/4, Qt, Xft, fontconfig, cursor

    # 8a. Sommelier environment (controls Linux app scaling)
    SOMMELIER_ENV="${HOME}/.config/environment.d/sommelier.conf"
    if [[ ! -f "$SOMMELIER_ENV" ]]; then
        write_file "$SOMMELIER_ENV" <<'EOF'
# Sommelier display scaling for Crostini
# SOMMELIER_SCALE adjusts Linux app window scaling:
#   1.0 = native (let ChromeOS handle scaling — recommended for FHD)
#   0.5 = 2x magnification (for 4K displays)
SOMMELIER_SCALE=1.0

# Pass Super key through to Linux apps instead of ChromeOS intercepting it.
# Required for VS Code, Firefox, and any app using Super as a modifier.
SOMMELIER_ACCELERATORS=Super_L

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

    # Install Qt5 GTK platform theme so Qt apps follow GTK dark theme. Batch qt5ct with preferred platform theme; if qt5-gtk-platformtheme is unavailable, install_pkgs_best_effort falls back to per-package (qt5ct succeeds individually) and the || arm tries the alternative name.
    install_pkgs_best_effort qt5ct qt5-gtk-platformtheme || \
        install_pkgs_best_effort qt5-style-plugins || \
        warn "Qt GTK theme package not available — Qt apps may not follow dark theme"

    # Qt6 GTK platform theme — allows Qt6 apps to follow GTK dark theme
    # WARNING: qt5ct conflicts with QT_QPA_PLATFORMTHEME=gtk3 (set in qt.conf above)
    install_pkgs_best_effort qt6-gtk-platformtheme || \
        warn "qt6-gtk-platformtheme not available — Qt6 apps may not follow dark theme"

    # 8f. Xft / Xresources (for pure X11 apps)
    XRESOURCES="${HOME}/.Xresources"
    if [[ ! -f "$XRESOURCES" ]]; then
        write_file "$XRESOURCES" <<'EOF'
! Font rendering for X11 apps on Duet 5 (13.3in 1920x1080 OLED)
! OLED has no LCD subpixel stripe — use grayscale AA (rgba=none)
! NOTE: sommelier now passes exact DPI to X clients.
! 120 DPI affects pure X11 apps only (not Wayland/GTK4).
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
        if run xrdb -merge "$XRESOURCES"; then
            $DRY_RUN || log "Xresources merged"
        else
            warn "xrdb merge failed — Xresources not applied until next session"
        fi
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
        if run fc-cache -f; then
            $DRY_RUN || log "Font cache rebuilt"
        else
            warn "fc-cache failed — font cache not rebuilt"
        fi
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
# Step 9: GUI applications (Firefox ESR, Chromium, Thunar, Evince, xterm, fonts, screenshots, MIME defaults)
if should_run_step 9; then
    step_banner 9 "GUI applications (Firefox ESR, Chromium, Thunar, Evince, xterm, fonts, screenshots, MIME defaults)"

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

        # Session support: D-Bus for X11, accessibility (suppresses GTK warnings), desktop notifications (notify-send)
        dbus-x11
        at-spi2-core
        libnotify-bin

        # Terminal emulator — needed for Thunar "Open Terminal Here" and other desktop actions. xterm is the standard X11 fallback that sensible-terminal and xdg-terminal-exec resolve to.
        xterm

        # Fonts — comprehensive set for international content
        fonts-noto
        fonts-noto-cjk
        fonts-noto-color-emoji
        fonts-noto-mono
        fonts-liberation
        fonts-firacode
        fonts-hack
        # adwaita-icon-theme includes "full" set since 45.0-4 (removed in Trixie)
        adwaita-icon-theme
    )

    install_pkgs_best_effort "${GUI_PKGS[@]}" || warn "Some GUI packages unavailable — non-fatal"

    # gnome-disk-utility has heavy GNOME deps — skip with --minimal
    if ! $MINIMAL; then
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-disk-utility \
            || warn "gnome-disk-utility install failed"
    else
        log "Skipping gnome-disk-utility (--minimal mode)"
    fi

    # Set Firefox ESR as default browser
    if command -v firefox-esr &>/dev/null || $DRY_RUN; then
        if run sudo update-alternatives --set x-www-browser /usr/bin/firefox-esr; then
            $DRY_RUN || log "Firefox ESR set as default browser"
        else
            warn "update-alternatives for Firefox ESR failed"
        fi
    fi

    # Native Chromium (optional — heavy, ~400 MB)
    if ! $MINIMAL; then
        run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y chromium \
            || warn "chromium install failed (non-fatal)"
    fi

    # Set default file manager Desktop file was renamed in Thunar 4.20 (Xfce reverse-DNS convention)
    _thunar_desktop="thunar.desktop"
    if [[ -f /usr/share/applications/org.xfce.thunar.desktop ]]; then
        _thunar_desktop="org.xfce.thunar.desktop"
    fi
    if command -v thunar &>/dev/null || $DRY_RUN; then
        if run xdg-mime default "$_thunar_desktop" inode/directory; then
            $DRY_RUN || log "Thunar set as default file manager ($_thunar_desktop)"
        else
            warn "xdg-mime default for Thunar failed"
        fi
    fi
    unset _thunar_desktop

    # Set default PDF viewer
    if command -v evince &>/dev/null || $DRY_RUN; then
        if run xdg-mime default org.gnome.Evince.desktop application/pdf; then
            $DRY_RUN || log "Evince set as default PDF viewer"
        else
            warn "xdg-mime default for Evince failed"
        fi
    fi

    # Set default image viewer
    if command -v eog &>/dev/null || $DRY_RUN; then
        _eog_ok=true
        for _mime in image/png image/jpeg image/gif image/webp image/svg+xml image/bmp image/tiff; do
            run xdg-mime default org.gnome.eog.desktop "$_mime" || { warn "xdg-mime default for eog/${_mime#image/} failed"; _eog_ok=false; }
        done
        unset _mime
        $_eog_ok && { $DRY_RUN || log "Eye of GNOME set as default image viewer"; }
        unset _eog_ok
    fi

    # Ensure desktop applications directory exists (garcon integration)
    if run mkdir -p "${HOME}/.local/share/applications"; then
        $DRY_RUN || log "Desktop applications directory: ${HOME}/.local/share/applications ✓"
    else
        warn "Cannot create desktop applications directory"
    fi

    unset GUI_PKGS
    set_checkpoint 9
    log "Step 9 complete."
fi
# Step 10: Rust stable aarch64 via rustup
if should_run_step 10; then
    step_banner 10 "Rust stable aarch64 via rustup"

    if command -v rustc &>/dev/null; then
        log "Rust already installed: $(timeout 3 rustc --version 2>/dev/null || echo 'unknown')"
    elif [[ -d "${HOME}/.rustup" ]]; then
        # ~/.rustup exists but rustc not in PATH — source cargo/env to recover
        warn "Existing ~/.rustup detected but rustc not in PATH"
        if [[ -f "${HOME}/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "${HOME}/.cargo/env" || true
        fi
        if command -v rustc &>/dev/null; then
            log "Rust recovered via cargo/env: $(timeout 3 rustc --version 2>/dev/null || echo 'unknown')"
        else
            warn "rustc still not found after sourcing cargo/env — re-running rustup"
        fi
    fi

    if ! command -v rustc &>/dev/null; then
        log "Installing Rust via rustup (non-interactive)..."
        if $DRY_RUN; then
            log "[DRY-RUN] curl --proto '=https' --tlsv1.2 -sSf --connect-timeout 10 --max-time 60 https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init -o /tmp/rustup-init-XXXXXXXXXX"
            log "[DRY-RUN] sha256sum verify against rustup-init.sha256"
            log "[DRY-RUN] /tmp/rustup-init-XXXXXXXXXX -y --default-toolchain stable"
        else
            # TOFU (Trust On First Use): HTTPS-only. rustup.rs does not publish a stable signing key (GPG removed in 1.26.0). SHA-256 verify added below. Download binary directly (not shell wrapper) to enable checksum verification.
            _rustup_tmp="$(mktemp /tmp/rustup-init-XXXXXXXXXX)" || die "Cannot create tmpfile for rustup installer"
            if ! run curl --proto '=https' --tlsv1.2 -sSf --connect-timeout 10 --max-time 60 \
                "https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init" \
                -o "$_rustup_tmp"; then
                rm -f "$_rustup_tmp"
                die "Rustup download failed"
            fi
            if [[ ! -s "$_rustup_tmp" ]]; then
                rm -f "$_rustup_tmp"
                die "Rustup installer is empty"
            fi
            # Verify SHA-256 checksum (TOFU via HTTPS, no GPG since rustup 1.26.0)
            _rustup_sha="$(mktemp /tmp/rustup-sha-XXXXXXXXXX)" || { warn "Cannot create checksum tmpfile"; _rustup_sha=""; }
            if [[ -n "$_rustup_sha" ]]; then
                if curl --proto '=https' --tlsv1.2 -sSf --connect-timeout 10 --max-time 30 \
                    "https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init.sha256" \
                    -o "$_rustup_sha" 2>/dev/null && [[ -s "$_rustup_sha" ]]; then
                    _expected="$(awk '{print $1}' "$_rustup_sha")"
                    _actual="$(sha256sum "$_rustup_tmp" | awk '{print $1}')"
                    if [[ "$_expected" != "$_actual" ]]; then
                        rm -f "$_rustup_tmp" "$_rustup_sha"
                        die "rustup-init SHA-256 mismatch: expected ${_expected}, got ${_actual}"
                    fi
                    log "rustup-init SHA-256 verified: ${_actual}"
                else
                    warn "Cannot download rustup checksum — proceeding with TOFU"
                fi
                rm -f "$_rustup_sha"
            else
                warn "Cannot create checksum tmpfile — proceeding with TOFU"
            fi
            chmod +x "$_rustup_tmp"
            run "$_rustup_tmp" -y --default-toolchain stable || die "Rustup installer failed"
            rm -f "$_rustup_tmp"
            unset _rustup_tmp _rustup_sha _expected _actual
        fi

        if [[ -f "${HOME}/.cargo/env" ]]; then
            # shellcheck source=/dev/null
            source "${HOME}/.cargo/env" || warn "Failed to source ${HOME}/.cargo/env — PATH may not include cargo/rustc"
        fi
    fi

    log "rustc version: $(timeout 3 rustc --version 2>/dev/null || echo 'not installed')"
    log "cargo version: $(timeout 3 cargo --version 2>/dev/null || echo 'not installed')"

    set_checkpoint 10
    log "Step 10 complete."
fi
# Step 11: Container resource tuning (sysctl, locale, env, XDG, paths, memory)
if should_run_step 11; then
    step_banner 11 "Container resource tuning (sysctl, locale, env, XDG, paths, memory)"

    # 11a. Install linux-sysctl-defaults (Trixie requirement for ping permissions) In Trixie, /etc/sysctl.conf is no longer honored by systemd-sysctl. This package provides /usr/lib/sysctl.d/50-default.conf which sets net.ipv4.ping_group_range for unprivileged ping access.
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y linux-sysctl-defaults \
        || warn "linux-sysctl-defaults unavailable (expected on Bookworm — Trixie-only package)"

    # 11b. Increase inotify watchers (file-heavy tools need this)
    if [[ ! -f "$SYSCTL_CONF" ]]; then
        write_file_sudo "$SYSCTL_CONF" <<'EOF'
fs.inotify.max_user_watches=524288
# Allow overcommit — prevents malloc failures in emulators on 4 GB RAM
vm.overcommit_memory=1
# Prevent mmap failures in emulators, Wine, and box64
vm.max_map_count=262144
EOF
        if run sudo sysctl --system; then
            if ! $DRY_RUN; then
                _inotify_val="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)" || true
                if [[ "$_inotify_val" == "524288" ]]; then
                    log "inotify watchers applied (524288) ✓"
                else
                    warn "inotify config written but value is ${_inotify_val:-unknown} (Termina VM may block writes)"
                    warn "May take effect after container restart; if not, this is a Crostini limitation"
                fi
                unset _inotify_val
                _overcommit_val="$(sysctl -n vm.overcommit_memory 2>/dev/null)" || true
                if [[ "$_overcommit_val" == "1" ]]; then
                    log "vm.overcommit_memory applied (1) ✓"
                else
                    warn "vm.overcommit_memory is ${_overcommit_val:-unknown} (may be read-only in this container)"
                fi
                unset _overcommit_val
            fi
        else
            warn "sysctl apply failed — inotify setting written to file but not active until reboot"
        fi
    else
        log "sysctl tuning already applied"
        # Upgrade path: append vm.max_map_count if absent (§6)
        if ! grep -q 'vm.max_map_count' "$SYSCTL_CONF"; then
            printf '%s\n' '# Prevent mmap failures in emulators, Wine, and box64' \
                | run sudo tee -a "$SYSCTL_CONF" > /dev/null
            printf '%s\n' 'vm.max_map_count=262144' \
                | run sudo tee -a "$SYSCTL_CONF" > /dev/null
            log "Appended vm.max_map_count to $SYSCTL_CONF"
            run sudo sysctl --system || warn "sysctl apply failed after appending vm.max_map_count"
        fi
    fi

    # 11b2. Sysctl startup persistence — Crostini containers may not run systemd-sysctl on start
    _SYSCTL_SVC="/etc/systemd/system/crostini-sysctl.service"
    if [[ ! -f "$_SYSCTL_SVC" ]]; then
        write_file_sudo "$_SYSCTL_SVC" <<'SVCEOF'
[Unit]
Description=Apply sysctl settings at container start
After=systemd-sysctl.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl --system
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
        run sudo systemctl daemon-reload \
            || warn "daemon-reload failed — service enable may fail"
        run sudo systemctl enable crostini-sysctl.service || warn "crostini-sysctl.service enable failed"
    else
        log "crostini-sysctl.service already exists"
    fi
    unset _SYSCTL_SVC

    # 11c. Set locale to en_US.UTF-8
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        # @@WHY: Gate sed on successful backup — if cp fails (disk full), proceeding to sed -i risks corrupting locale.gen with no rollback.
        if run sudo cp /etc/locale.gen /etc/locale.gen.bak; then
            if run sudo sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; then
                if run sudo locale-gen; then
                    if ! $DRY_RUN; then
                        run sudo rm -f /etc/locale.gen.bak || true
                        log "en_US.UTF-8 locale generated"
                    fi
                else
                    warn "locale-gen failed — locale.gen modified but generation incomplete; backup at /etc/locale.gen.bak"
                fi
            else
                warn "locale.gen edit failed — restoring backup"
                run sudo cp -- /etc/locale.gen.bak /etc/locale.gen || warn "Rollback of locale.gen failed — manual restore from /etc/locale.gen.bak required"
                run sudo rm -f /etc/locale.gen.bak || true
            fi
        else
            warn "locale.gen backup failed — skipping locale edit to avoid unrecoverable corruption"
        fi
    else
        log "en_US.UTF-8 locale already available"
    fi

    # 11d. Master environment profile (shell-agnostic via /etc/profile.d)
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

# PATH helper — prepend only if dir exists and is not already in PATH
_crostini_path_prepend() {
    case ":$PATH:" in
        *:"$1":*) ;;
        *) export PATH="$1:$PATH" ;;
    esac
}

# Cargo/Rust
[ -d "$HOME/.cargo/bin" ] && _crostini_path_prepend "$HOME/.cargo/bin"
# Limit cargo parallel jobs — 4 GB RAM constraint
export CARGO_BUILD_JOBS=2

# Local bin (user scripts)
[ -d "$HOME/.local/bin" ] && _crostini_path_prepend "$HOME/.local/bin"

unset -f _crostini_path_prepend
ENVEOF
    else
        log "Environment profile already exists"
    fi

    # 11e. Memory tuning — vm.* sysctls are read-only in Crostini; test before applying NOTE: sysctl --system may silently skip individual read-only keys (it only fails on parse errors).  Verify with: sysctl vm.swappiness vm.vfs_cache_pressure
    MEM_CONF="/etc/sysctl.d/99-crostini-memory.conf"
    if [[ ! -f "$MEM_CONF" ]]; then
        if $DRY_RUN || [[ -w /proc/sys/vm/swappiness ]]; then
            write_file_sudo "$MEM_CONF" <<'MEMEOF'
# Memory tuning for 4 GB Duet 5 — managed by crostini-setup-duet5.sh
# Lower swappiness: prefer keeping pages in RAM over swapping
vm.swappiness=10
# Retain filesystem metadata cache — reduces eMMC random reads
# (150 was overly aggressive; 50 balances cache retention vs memory pressure)
vm.vfs_cache_pressure=50
# Lower dirty ratio thresholds — flush writes earlier on low-RAM device
vm.dirty_ratio=10
vm.dirty_background_ratio=5
MEMEOF
            run sudo sysctl --system || warn "memory sysctl apply failed"
        else
            warn "vm.swappiness is read-only in this container (expected in Crostini)"
            warn "Memory tuning requires host-level (termina VM) access — skipping"
        fi
    else
        log "Memory tuning config already exists"
        # Upgrade path: change vfs_cache_pressure 150→50 (§6)
        if grep -q 'vfs_cache_pressure=150' "$MEM_CONF"; then
            run sudo sed -i \
                -e 's/vfs_cache_pressure=150/vfs_cache_pressure=50/' \
                -e 's/More aggressive page cache reclaim under memory pressure/Retain filesystem metadata cache — reduces eMMC random reads/' \
                "$MEM_CONF"
            log "Updated vfs_cache_pressure: 150 → 50"
            run sudo sysctl --system || warn "memory sysctl apply failed after vfs_cache_pressure update"
        fi
    fi

    # 11f. Ensure XDG dirs exist
    run mkdir -p "${HOME}/.local/share" "${HOME}/.local/bin" "${HOME}/.config" "${HOME}/.cache" \
        || warn "Cannot create XDG directories"
    if command -v xdg-user-dirs-update &>/dev/null; then
        if run xdg-user-dirs-update; then
            $DRY_RUN || log "XDG user directories updated"
        else
            warn "xdg-user-dirs-update failed"
        fi
    fi

    unset PROFILE_D MEM_CONF
    set_checkpoint 11
    log "Step 11 complete."
fi
# Step 12: Flatpak + Flathub (ARM64 app source)
if should_run_step 12; then
    step_banner 12 "Flatpak + Flathub (ARM64 app source)"

    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y flatpak || warn "flatpak install failed"
    if $DRY_RUN; then
        # In dry-run, apt install is a no-op so flatpak binary won't exist; always trace the planned remote-add.
        run sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    elif command -v flatpak &>/dev/null; then
        # System-level remote (may fail due to polkit in Crostini — non-fatal)
        run sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || warn "System Flathub remote add failed (polkit) — user remote below"
        # User-level remote (no polkit needed; required for --user installs)
        run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || warn "User Flathub remote add failed"
        log "Flatpak installed with Flathub remote."
    else
        warn "flatpak binary not available — skipping Flathub remote"
    fi
    if ! $DRY_RUN; then
        # Pin Freedesktop Platform 24.08 — ≥25.08 crashes on Crostini (Mesa Zink incompatibility)
        if command -v flatpak &>/dev/null; then
            run flatpak install --user --noninteractive -y flathub org.freedesktop.Platform//24.08 \
                || warn "Freedesktop Platform 24.08 install failed — pin per-app with: flatpak override --user --env=MESA_LOADER_DRIVER_OVERRIDE=virgl <app-id>"
        fi
    else
        log "[DRY-RUN] flatpak install --user org.freedesktop.Platform//24.08"
    fi
    log "Install apps: flatpak install flathub <app-id>"

    set_checkpoint 12
    log "Step 12 complete."
fi
# Step 13: Gaming packages (DOSBox-X, DOSBox, ScummVM, RetroArch)
if should_run_step 13; then
    step_banner 13 "Gaming packages (DOSBox-X, DOSBox, ScummVM, RetroArch)"

    # Native ARM packages — DOSBox-X primary (aarch64 dynrec), classic DOSBox fallback
    # fluid-soundfont-gm: General MIDI soundfont for DOSBox-X and ScummVM
    install_pkgs_best_effort dosbox-x dosbox scummvm fluid-soundfont-gm || warn "Some gaming packages failed"
    log "DOSBox-X recommended (aarch64 dynrec). Classic DOSBox: interpreter-only fallback."

    # RetroArch via Flatpak (aarch64 confirmed on Flathub) User-mode install: system-mode requires polkit (flatpak-system-helper) which is blocked in Crostini containers.
    if $DRY_RUN; then
        # In dry-run, flatpak may not exist (apt install was a no-op); always trace.
        run flatpak install --user --noninteractive -y flathub org.libretro.RetroArch
    elif command -v flatpak &>/dev/null; then
        run flatpak install --user --noninteractive -y flathub org.libretro.RetroArch || warn "RetroArch Flatpak install failed"
    else
        warn "flatpak not available — skip RetroArch (install flatpak first)"
    fi

    # RetroArch Flatpak environment overrides — sandbox does not inherit host env (§5.5.1)
    if ! $DRY_RUN && timeout 5 flatpak list --app --user 2>/dev/null | grep -q org.libretro.RetroArch; then
        flatpak override --user --env=GALLIUM_DRIVER=virgl org.libretro.RetroArch
        flatpak override --user --env=MESA_LOADER_DRIVER_OVERRIDE=virgl org.libretro.RetroArch
        flatpak override --user --env=MESA_NO_ERROR=1 org.libretro.RetroArch
        flatpak override --user --env=EGL_PLATFORM=wayland org.libretro.RetroArch
        log "RetroArch Flatpak Mesa overrides applied"
    elif $DRY_RUN; then
        log "[DRY-RUN] flatpak override --user --env=GALLIUM_DRIVER=virgl org.libretro.RetroArch (+ 3 more)"
    fi

    # RetroArch default config (§5.5.2)
    _RA_CFG="${HOME}/.var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg"
    if [[ ! -f "$_RA_CFG" ]]; then
        run mkdir -p "${HOME}/.var/app/org.libretro.RetroArch/config/retroarch" || true
        write_file "$_RA_CFG" <<'RACFG'
# RetroArch Crostini config — managed by crostini-setup-duet5.sh
# Written once on first install; edit freely afterward.

# Video: glcore works on virgl's GL 4.3 core profile and enables slang shaders.
# Threaded video offloads GL calls (benefits virgl's serialized command stream)
# at the cost of +1 frame input latency — acceptable for retro gaming.
video_driver = "glcore"
video_threaded = "true"
video_vsync = "true"
video_max_swapchain_images = "2"

# Audio: MUST use "pulse", NOT "pipewire".
# RetroArch's native PipeWire driver (GitHub libretro/RetroArch#17685) hard-codes
# quantum values and ignores the latency slider. The PulseAudio driver works
# correctly through PipeWire's compatibility layer.
audio_driver = "pulse"
audio_latency = "64"

# Memory: disable rewind (consumes ~20 MB/min buffer on 4 GB device).
# Run-ahead: disabled globally; enable per-core for 8/16-bit only (see README).
rewind_enable = "false"
run_ahead_enabled = "false"

# Misc
savestate_compression = "true"
menu_driver = "rgui"
RACFG
    else
        log "RetroArch config already exists — skipping"
    fi
    unset _RA_CFG

    # DOSBox-X default config (§5.4.2)
    _DBX_CFG="${HOME}/.config/dosbox-x/dosbox-x.conf"
    if [[ ! -f "$_DBX_CFG" ]]; then
        run mkdir -p "${HOME}/.config/dosbox-x" || true
        write_file "$_DBX_CFG" <<'DBXCFG'
# DOSBox-X optimized config for Crostini ARM64 — managed by crostini-setup-duet5.sh
# Edit freely; this file is only written once (skipped if already present).

[sdl]
fullscreen=false
fullresolution=desktop
output=openglpp

[dosbox]
machine=svga_s3
memsize=16

[cpu]
core=dynamic
cputype=auto
cycles=auto

[render]
frameskip=0
aspect=true
doublescan=false
scaler=none

[sblaster]
sbtype=sb16
oplemu=default

[midi]
mpu401=intelligent
mididevice=fluidsynth
midiconfig=/usr/share/sounds/sf2/FluidR3_GM.sf2

[mixer]
rate=48000
blocksize=1024
prebuffer=25
DBXCFG
    else
        log "DOSBox-X config already exists — skipping"
    fi
    unset _DBX_CFG

    # ScummVM default config (§5.6)
    _SVM_CFG="${HOME}/.config/scummvm/scummvm.ini"
    if [[ ! -f "$_SVM_CFG" ]]; then
        run mkdir -p "${HOME}/.config/scummvm" || true
        write_file "$_SVM_CFG" <<'SVMCFG'
# ScummVM Crostini config — managed by crostini-setup-duet5.sh
# Written once on first install; edit freely afterward.
[scummvm]
gfx_mode=opengl
stretch_mode=pixel_perfect
aspect_ratio=true
filtering=false
vsync=true
music_driver=fluidsynth
soundfont=/usr/share/sounds/sf2/FluidR3_GM.sf2
SVMCFG
    else
        log "ScummVM config already exists — skipping"
    fi
    unset _SVM_CFG

    # Standalone emulators — skip with --minimal (§5.7)
    if ! $MINIMAL; then
        # PPSSPP Flatpak (standalone PSP, 10-15% faster than RetroArch core)
        if $DRY_RUN; then
            run flatpak install --user --noninteractive -y flathub org.ppsspp.PPSSPP
        elif command -v flatpak &>/dev/null; then
            run flatpak install --user --noninteractive -y flathub org.ppsspp.PPSSPP \
                || warn "PPSSPP Flatpak install failed — non-fatal"
        fi

        # mgba-qt (standalone GBA with debug tools)
        install_pkgs_best_effort mgba-qt || warn "mgba-qt unavailable — non-fatal"

        # Apply Mesa Flatpak overrides to standalone Flatpak emulators (§5.7)
        if ! $DRY_RUN; then
            for _app_id in org.ppsspp.PPSSPP; do
                if timeout 5 flatpak list --app --user 2>/dev/null | grep -q "$_app_id"; then
                    flatpak override --user --env=GALLIUM_DRIVER=virgl "$_app_id"
                    flatpak override --user --env=MESA_LOADER_DRIVER_OVERRIDE=virgl "$_app_id"
                    flatpak override --user --env=MESA_NO_ERROR=1 "$_app_id"
                    flatpak override --user --env=EGL_PLATFORM=wayland "$_app_id"
                    log "$_app_id Mesa overrides applied"
                fi
            done
            unset _app_id
        else
            log "[DRY-RUN] flatpak override --user --env=GALLIUM_DRIVER=virgl org.ppsspp.PPSSPP (+ 3 more)"
        fi
    else
        log "Skipping standalone emulators (--minimal mode)"
    fi

    # Verify (skip in dry-run — packages were not actually installed)
    if ! $DRY_RUN; then
        if command -v dosbox &>/dev/null; then
            _dosbox_ver="$(timeout 3 dosbox --version 2>/dev/null | head -1 || true)"
            log "dosbox: ${_dosbox_ver:-installed} ✓"
            unset _dosbox_ver
        else
            warn "dosbox not found"
        fi
        if command -v dosbox-x &>/dev/null; then
            _dosboxx_ver="$(timeout 3 dosbox-x --version 2>/dev/null | head -1 || true)"
            log "dosbox-x: ${_dosboxx_ver:-installed} ✓"
            unset _dosboxx_ver
        else
            warn "dosbox-x not found"
        fi
        if command -v scummvm &>/dev/null; then
            _scummvm_ver="$(timeout 3 scummvm --version 2>/dev/null | head -1 || true)"
            log "scummvm: ${_scummvm_ver:-installed} ✓"
            unset _scummvm_ver
        else
            warn "scummvm not found"
        fi
        if timeout 5 flatpak list --app --user 2>/dev/null | grep -q org.libretro.RetroArch; then
            log "RetroArch Flatpak: installed ✓"
        else
            warn "RetroArch Flatpak not detected"
        fi
    fi

    log "For advanced gaming (box64/Wine/GOG/cloud): see README.md § Gaming"

    set_checkpoint 13
    log "Step 13 complete."
fi
# Step 14: Container backup
# Opens ChromeOS backup page when run with --interactive.
if should_run_step 14; then
    step_banner 14 "Container backup"

    if ! $DRY_RUN && ! $UNATTENDED; then
        log "Opening ChromeOS backup page to snapshot this fresh setup..."
        _prompt '%b  → Click "Backup" to save your Linux container state.%b\n' "$YELLOW" "$RESET"
        _prompt '%b  → Do this periodically after major changes.%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/exportImport"
        sleep 2
        _prompt '%bPress Enter after backup completes (or to skip)...%b' "$YELLOW" "$RESET"
        read -r -t 300 _ </dev/tty || true
    elif $DRY_RUN && ! $UNATTENDED; then
        log "[DRY-RUN] would open chrome://os-settings/crostini/exportImport"
    elif $DRY_RUN; then
        log "[DRY-RUN] Skipping interactive backup prompt (unattended mode)"
    else
        log "Skipping interactive backup prompt (unattended mode)"
    fi

    set_checkpoint 14
    log "Step 14 complete."
fi
# Step 15: Summary and verification
if should_run_step 15; then
    step_banner 15 "Summary and verification"

    # Verification counters (used by check_tool / check_config below)
    _verify_pass=0
    _verify_fail=0
    _verify_warn=0

    if $DRY_RUN; then
        log "[DRY-RUN] Verification runs live (all checks are read-only)"
    fi

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
    _disk_avail="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')" || true
    if [[ "$_disk_avail" =~ ^[0-9]+$ ]]; then
        logprintf '  Disk free:     %s MB\n' "$((_disk_avail / 1024))"
    else
        logprintf '  Disk free:     unknown\n'
    fi
    unset _disk_avail
    logprintf '\n'

    # GPU
    logprintf '%bGPU / Graphics:%b\n' "$BOLD" "$RESET"
    if [[ -e /dev/dri/renderD128 ]]; then
        logprintf '  Render node:   %b✓%b /dev/dri/renderD128\n' "$GREEN" "$RESET"
        ((_verify_pass++)) || true
        if command -v glxinfo &>/dev/null; then
            _glx_out="$(glxinfo 2>/dev/null || true)"
            GL_VENDOR="$(printf '%s\n' "$_glx_out" | grep "OpenGL vendor" | head -1 | cut -d: -f2 | xargs -r || true)"
            GL_RENDERER="$(printf '%s\n' "$_glx_out" | grep "OpenGL renderer" | head -1 | cut -d: -f2 | xargs -r || true)"
            GL_VERSION="$(printf '%s\n' "$_glx_out" | grep "OpenGL version" | head -1 | cut -d: -f2 | xargs -r || true)"
            unset _glx_out
            [[ -n "$GL_VENDOR" ]]   && logprintf '  GL vendor:     %s\n' "$GL_VENDOR"
            [[ -n "$GL_RENDERER" ]] && logprintf '  GL renderer:   %s\n' "$GL_RENDERER"
            [[ -n "$GL_VERSION" ]]  && logprintf '  GL version:    %s\n' "$GL_VERSION"
        fi
        if command -v vulkaninfo &>/dev/null; then
            _vk_out="$(vulkaninfo --summary 2>/dev/null || true)"
            VK_GPU="$(printf '%s\n' "$_vk_out" | grep "GPU name" | head -1 | cut -d= -f2 | xargs -r || true)"
            VK_API="$(printf '%s\n' "$_vk_out" | grep "apiVersion" | head -1 | cut -d= -f2 | xargs -r || true)"
            unset _vk_out
            if [[ -n "$VK_GPU" ]]; then
                logprintf '  Vulkan GPU:    %s\n' "$VK_GPU"
                [[ -n "$VK_API" ]] && logprintf '  Vulkan API:    %s\n' "$VK_API"
            else
                logprintf '  Vulkan:        not available (virgl does not support Vulkan)\n'
            fi
        fi
    elif [[ -d /dev/dri ]]; then
        logprintf '  Render node:   %b⚠ PARTIAL%b (/dev/dri exists, renderD128 missing)\n' "$YELLOW" "$RESET"
        ((_verify_warn++)) || true
    else
        logprintf '  Render node:   %b✗ NOT ACTIVE%b\n' "$RED" "$RESET"
        ((_verify_fail++)) || true
        logprintf '  Fix:           chrome://flags/#crostini-gpu-support → Enabled → Reboot\n'
    fi
    logprintf '\n'

    # Display
    logprintf '%bDisplay / Wayland:%b\n' "$BOLD" "$RESET"
    if pgrep -x sommelier &>/dev/null; then
        logprintf '  Sommelier:     %b✓%b running\n' "$GREEN" "$RESET"
        ((_verify_pass++)) || true
    else
        logprintf '  Sommelier:     %b✗%b not running — restart terminal\n' "$RED" "$RESET"
        ((_verify_fail++)) || true
    fi
    logprintf '  DISPLAY:       %s\n' "${DISPLAY:-not set}"
    logprintf '  WAYLAND:       %s\n' "${WAYLAND_DISPLAY:-not set}"
    logprintf '  GTK theme:     %s\n' "$(grep gtk-theme-name "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | head -1 | cut -d= -f2 || echo 'default')"
    logprintf '  Xft DPI:       %s\n' "$(grep 'Xft.dpi' "${HOME}/.Xresources" 2>/dev/null | head -1 | awk '{print $2}' || echo 'default')"
    logprintf '  Font:          %s\n' "$(grep gtk-font-name "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null | head -1 | cut -d= -f2 || echo 'default')"
    logprintf '\n'

    # Audio
    logprintf '%bAudio:%b\n' "$BOLD" "$RESET"
    if [[ -d /dev/snd ]]; then
        SND_DEV_COUNT="$(find /dev/snd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" || true
        logprintf '  ALSA devices:  %b✓%b %s device(s)\n' "$GREEN" "$RESET" "$SND_DEV_COUNT"
        ((_verify_pass++)) || true
    else
        logprintf '  ALSA devices:  %b✗%b /dev/snd not found\n' "$RED" "$RESET"
        ((_verify_fail++)) || true
    fi
    if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
        logprintf '  Microphone:    %b✓%b capture device present\n' "$GREEN" "$RESET"
        ((_verify_pass++)) || true
    else
        logprintf '  Microphone:    %b⚠%b not detected — enable in ChromeOS Linux settings\n' "$YELLOW" "$RESET"
        ((_verify_warn++)) || true
    fi
    if command -v pactl &>/dev/null; then
        PA_STATUS="$(pactl info 2>/dev/null | grep "Server Name" | cut -d: -f2 | xargs -r || true)"
        if [[ -n "$PA_STATUS" ]]; then
            logprintf '  PulseAudio:    %b✓%b %s\n' "$GREEN" "$RESET" "$PA_STATUS"
            ((_verify_pass++)) || true
        else
            logprintf '  PulseAudio:    %b⚠%b installed but not responding\n' "$YELLOW" "$RESET"
            ((_verify_warn++)) || true
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
                [[ -n "$d" ]] && logprintf '    %s\n' "$d"
            done
        else
            logprintf '  Shared dirs:   none — share via Files app → right-click → Share with Linux\n'
        fi
        unset _shared_arr SHARED_N
    fi
    logprintf '\n'

    # Installed tools
    logprintf '%bInstalled tools:%b\n' "$BOLD" "$RESET"

    check_tool "rustc"       rustc
    check_tool "cargo"       cargo
    check_tool "vim"         vim
    check_tool "curl"        curl
    check_tool "wl-clipboard" wl-copy
    check_tool "ripgrep"     rg
    check_tool "fd"          fd
    check_tool "fzf"         fzf
    check_tool "bat"         bat
    check_tool "tmux"        tmux
    check_tool "jq"          jq
    check_tool "htop"        htop
    check_tool "nano"        nano
    check_tool "ncdu"        ncdu
    check_tool "strace"      strace
    check_tool "rsync"       rsync
    check_tool "file"        file
    check_tool "tree"        tree
    check_tool "less"        less
    check_tool "wget"        wget
    check_tool "dig"         dig
    check_tool "ssh"         ssh
    check_tool "lsof"        lsof
    check_tool "screen"      screen
    check_tool "zip"         zip
    check_tool "unzip"       unzip
    check_tool "7z"          7z
    check_tool "rename"      rename
    check_tool "glxinfo"     glxinfo
    check_tool "glmark2"     glmark2-es2-wayland
    check_tool "vulkaninfo"  vulkaninfo
    check_tool "pactl"       pactl
    check_tool "pavucontrol" pavucontrol
    check_tool "flatpak"     flatpak
    check_tool "dosbox"      dosbox
    check_tool "dosbox-x"    dosbox-x
    check_tool "scummvm"     scummvm
    check_tool "firefox-esr" firefox-esr
    if ! $MINIMAL; then check_tool "chromium" chromium; fi
    check_tool "thunar"      thunar
    check_tool "evince"      evince
    check_tool "eog"         eog
    check_tool "file-roller" file-roller
    check_tool "gnome-screenshot" gnome-screenshot
    check_tool "xterm"       xterm
    if timeout 5 flatpak list --app --user 2>/dev/null | grep -q org.libretro.RetroArch; then
        logprintf '  %-14s %b✓%b  Flatpak (user)\n' "retroarch" "$GREEN" "$RESET"
        ((_verify_pass++)) || true
    else
        logprintf '  %-14s %b✗%b  not found\n' "retroarch" "$RED" "$RESET"
        ((_verify_fail++)) || true
    fi
    if ! $MINIMAL; then
        if timeout 5 flatpak list --app --user 2>/dev/null | grep -q org.ppsspp.PPSSPP; then
            logprintf '  %-14s %b✓%b  Flatpak (user)\n' "ppsspp" "$GREEN" "$RESET"
            ((_verify_pass++)) || true
        else
            logprintf '  %-14s %b✗%b  not found\n' "ppsspp" "$RED" "$RESET"
            ((_verify_fail++)) || true
        fi
        check_tool "mgba" mgba-qt
    fi
    logprintf '\n'

    # Config files
    logprintf '%bConfig files written:%b\n' "$BOLD" "$RESET"

    check_config "/etc/apt/apt.conf.d/90parallel"                "Apt download tuning"
    check_config "${HOME}/.config/environment.d/gpu.conf"       "GPU env"
    check_config "${HOME}/.config/environment.d/audio.conf"      "Audio env"
    check_config "${HOME}/.config/environment.d/sommelier.conf"  "Sommelier scaling + keys"
    check_config "${HOME}/.config/environment.d/qt.conf"         "Qt scaling/theming"
    check_config "${HOME}/.config/gtk-3.0/settings.ini"          "GTK 3 theme + fonts"
    check_config "${HOME}/.config/gtk-4.0/settings.ini"          "GTK 4 theme + fonts"
    check_config "${HOME}/.gtkrc-2.0"                            "GTK 2 theme (legacy)"
    check_config "${HOME}/.Xresources"                           "Xft DPI + rendering"
    check_config "${HOME}/.config/fontconfig/fonts.conf"         "Fontconfig OLED AA"
    check_config "${HOME}/.icons/default/index.theme"            "Cursor theme"
    check_config "/etc/profile.d/crostini-env.sh"                "Shell env + PATH"
    check_config "/etc/sysctl.d/99-crostini-tuning.conf"         "inotify + overcommit + max_map_count"
    if [[ -f "/etc/systemd/system/crostini-sysctl.service" ]]; then
        check_config "/etc/systemd/system/crostini-sysctl.service" "Sysctl persistence service"
    fi
    if [[ -f "/etc/systemd/system/tmp.mount.d/override.conf" ]]; then
        check_config "/etc/systemd/system/tmp.mount.d/override.conf" "/tmp tmpfs 512M cap"
    fi
    if [[ -f "/etc/pipewire/pipewire.conf.d/99-quantum.conf" ]]; then
        check_config "/etc/pipewire/pipewire.conf.d/99-quantum.conf" "PipeWire quantum override"
    fi
    check_config "${HOME}/.config/pipewire/pipewire.conf.d/10-crostini-gaming.conf"        "PipeWire gaming quantum"
    check_config "${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-crostini-gaming.conf"   "PipeWire-Pulse gaming"
    check_config "${HOME}/.config/dosbox-x/dosbox-x.conf"                                   "DOSBox-X config"
    check_config "/usr/share/sounds/sf2/FluidR3_GM.sf2"                                     "FluidSynth GM soundfont"
    check_config "${HOME}/.var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg"    "RetroArch config"
    check_config "${HOME}/.config/scummvm/scummvm.ini"                                       "ScummVM config"
    if [[ -f "/etc/sysctl.d/99-crostini-memory.conf" ]]; then
        check_config "/etc/sysctl.d/99-crostini-memory.conf"     "Memory tuning (4 GB)"
    else
        logprintf '  %b⚠%b  %-44s %s\n' "$YELLOW" "$RESET" "Memory tuning (4 GB)" "skipped (vm.* read-only in container)"
        ((_verify_warn++)) || true
    fi
    # PipeWire audio chain verification
    if systemctl --user is-active pipewire-pulse.socket &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "PipeWire-pulse active"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "PipeWire-pulse not running — restart terminal"
        ((_verify_warn++)) || true
    fi
    logprintf '\n'
    logprintf '%bQuick-test commands:%b\n' "$BOLD" "$RESET"
    logprintf '  GPU/Audio:   glxgears / glmark2-es2-wayland / vulkaninfo --summary / pactl info\n'
    logprintf '  Display:     xdpyinfo | grep resolution / fc-match sans-serif / fc-match monospace\n'
    logprintf '\n'

    # Reminders
    logprintf '%bReminders:%b\n' "$YELLOW" "$RESET"
    logprintf '  • Manual .deb downloads: always get the arm64 variant\n'
    logprintf '  • Flatpak apps: flatpak install --user flathub <app-id>\n'
    logprintf '  • If GPU not active: reboot entire Chromebook (not just container)\n'
    logprintf '  • Gaming (box86/Wine/GOG/cloud): see README.md § Gaming\n'
    logprintf '\n'

    logprintf '%bLog file:%b %s\n' "$BOLD" "$RESET" "$LOG_FILE"

    # Verification summary
    logprintf '\n%bVerification totals:%b  ' "$BOLD" "$RESET"
    logprintf '%b%s passed%b' "$GREEN" "$_verify_pass" "$RESET"
    [[ "$_verify_warn" -gt 0 ]] && logprintf '  %b%s warnings%b' "$YELLOW" "$_verify_warn" "$RESET"
    [[ "$_verify_fail" -gt 0 ]] && logprintf '  %b%s failed%b' "$RED" "$_verify_fail" "$RESET"
    logprintf '\n'

    # Mark step 15 complete before removing the checkpoint file. This ensures a crash between here and rm -f still shows step 15 done.
    set_checkpoint 15

    # Clean up checkpoint — all steps finished, no resume needed
    if $DRY_RUN; then
        log "[DRY-RUN] would remove checkpoint file"
    else
        rm -f "$STEP_FILE"
        log "Checkpoint file removed. Setup fully complete."
    fi

    # Clean up step 15 variables
    unset GL_VENDOR GL_RENDERER GL_VERSION VK_GPU VK_API SND_DEV_COUNT PA_STATUS
    unset _verify_pass _verify_fail _verify_warn

    # Elapsed time
    _now_epoch="$(date +%s 2>/dev/null)" || _now_epoch=""
    if [[ -n "$_now_epoch" ]]; then
        _elapsed=$(( _now_epoch - _START_EPOCH ))
    else
        _elapsed="${SECONDS:-0}"
    fi
    logprintf '%bElapsed time:%b  %dm %ds\n' "$BOLD" "$RESET" "$((_elapsed / 60))" "$((_elapsed % 60))"
    unset _now_epoch _elapsed

    logprintf '\n%bRestart the Terminal app to apply all environment changes.%b\n\n' "$BOLD" "$RESET"
    log "Step 15 complete."
fi

exit 0
