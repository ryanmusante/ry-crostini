#!/usr/bin/env bash
# ry-crostini.sh — Crostini post-install bootstrap for Lenovo Duet 5 (82QS0001US)
# Version: 8.0.2
# Date:    2026-04-05
# Arch:    aarch64 / arm64 (Qualcomm Snapdragon 7c Gen 2 — SC7180P)
# Target:  Debian Trixie container under ChromeOS Crostini (Bookworm upgraded automatically)
# Usage:   bash ry-crostini.sh [--dry-run] [--interactive] [--from-step=N] [--verify] [--reset] [--help] [--version] [--]
# Fully unattended by default — use --interactive for ChromeOS toggle prompts.
# NOTE: Script uses sudo internally (~70 calls). A background keepalive renews credentials every 60 s. Run `sudo true` first to cache the initial credential.
# WARNING: Steam is x86-only; box64/box86 community translation exists but is unusable on 4 GB RAM / virgl.
# NOTE: Crostini may initially ship Bookworm; step 2 upgrades to Trixie. Package arrays use canonical (non-transitional) names.
# NOTE: Trixie mounts /tmp as tmpfs (RAM-backed). Downloads to /tmp are transient and small; they are cleaned up in both normal flow and EXIT trap.

set -euo pipefail
# Propagate ERR trap to functions/subshells; inherit errexit in $(command substitution)
set -E
shopt -s inherit_errexit
# Standard umask — all write_file variants set explicit permissions (644/600/700)
umask 022

# Constants
readonly SCRIPT_NAME="ry-crostini.sh"
readonly SCRIPT_VERSION="8.0.2"
readonly EXPECTED_ARCH="aarch64"
_log_ts="$(date +%Y%m%d-%H%M%S)" || { printf 'FATAL: date failed\n' >&2; exit 1; }
# Not readonly — _parallel_check_tools subshells must reassign to /dev/null
LOG_FILE="${HOME}/ry-crostini-${_log_ts}.log"
readonly STEP_FILE="${HOME}/.ry-crostini-checkpoint"
readonly LOCK_FILE="${HOME}/.ry-crostini.lock"
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
_DEFERRED_CHECKPOINT=""
_DEFERRED_CHECKPOINT_MSG=""
_CHECKPOINT_OVERRIDE=""
_LOCK_ACQUIRED=false
_received_signal=""
_SUDO_KEEPALIVE_PID=""
_PARALLEL_TMPDIR=""
_SUDO_TMPFILE=""

# Signal handler — stores signal name, triggers EXIT trap via exit
# shellcheck disable=SC2317,SC2329
_handle_signal() { _received_signal="$1"; exit 1; }

# Cleanup trap
# shellcheck disable=SC2317,SC2329
cleanup() {
    local rc=$?
    # Prevent recursive cleanup from nested signals
    trap - EXIT INT TERM HUP PIPE QUIT WINCH
    # Disable set -e inside cleanup to guarantee full execution
    set +e
    # Restore terminal scroll region before any output
    _progress_cleanup
    # Strip ANSI escape codes from log file (single-pass; replaces racy per-line sed)
    _strip_log_ansi
    # Stop sudo credential keepalive (disowned — kill by raw PID)
    if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$_SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    # Restore terminal state — keepalive/progress escape sequences can corrupt tty when killed mid-write
    if [[ -t 0 ]]; then stty sane 2>/dev/null || true; fi
    # Remove parallel check_tool tmpdir if abandoned by signal during wait
    if [[ -n "${_PARALLEL_TMPDIR:-}" && -d "${_PARALLEL_TMPDIR:-}" ]]; then
        rm -rf -- "$_PARALLEL_TMPDIR" 2>/dev/null || true
    fi
    # Remove abandoned write_file_sudo tmpfile (signal between mktemp and mv)
    if [[ -n "${_SUDO_TMPFILE:-}" ]]; then
        sudo rm -f -- "$_SUDO_TMPFILE" 2>/dev/null || true
    fi
    # Release lock only if this instance acquired it
    if $_LOCK_ACQUIRED && [[ -n "${LOCK_FILE:-}" ]]; then
        # Remove all files (pid + any orphaned tmpfiles from crash)
        find "$LOCK_FILE" -maxdepth 1 -type f -delete 2>/dev/null || true
        rmdir "$LOCK_FILE" 2>/dev/null || true
    fi
    if [[ "$rc" -ne 0 ]]; then
        if [[ "${_had_failures:-0}" -gt 0 ]]; then
            # Exited due to verification failures — steps 1-10 are complete
            _cleanup_warn "Script exited with code $rc. Verification failed. Fix issues above, then run: bash ry-crostini.sh --verify"
        elif ${_no_checks_ran:-false}; then
            # --from-step=13 with no prior verification — already messaged inline
            :
        else
            _cleanup_warn "Script exited with code $rc. Re-run to resume from checkpoint."
        fi
    fi
    # Re-raise caught signal for correct 128+N exit code to parent
    if [[ -n "${_received_signal:-}" ]]; then
        kill -"$_received_signal" "$$"
    fi
    exit "$rc"
}
# Progress bar state — initialized before traps to prevent unbound-variable exit under set -u
_PROGRESS_ENABLED=false
_PROGRESS_STEP=0
trap cleanup EXIT
trap '_handle_signal INT' INT
trap '_handle_signal TERM' TERM
trap '_handle_signal HUP' HUP
trap '_handle_signal PIPE' PIPE
trap '_handle_signal QUIT' QUIT
trap '_progress_resize' WINCH

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

# Progress bar — pinned to bottom of terminal via scroll region
readonly _PROGRESS_TOTAL=13

# _progress_init: reserve bottom terminal line, draw initial bar. Called once after lock+checkpoint.
# shellcheck disable=SC2317
_progress_init() {
    [[ -t 1 ]] || return 0
    local rows
    rows="$(tput lines 2>/dev/null)" || return 0
    [[ "$rows" -ge 5 ]] || return 0
    _PROGRESS_ENABLED=true
    # Scroll region: rows 1..(N-1); bottom line reserved for progress bar
    printf '\033[1;%dr' "$((rows - 1))"
    local ckpt
    ckpt="$(get_checkpoint)"
    _progress_draw "$ckpt"
}

# _progress_draw: render progress bar on the reserved bottom line (stdout only)
# shellcheck disable=SC2317
_progress_draw() {
    $_PROGRESS_ENABLED || return 0
    local step="${1:-$_PROGRESS_STEP}"
    _PROGRESS_STEP="$step"
    local rows cols pct filled empty bar_w label bar_f bar_e
    rows="$(tput lines 2>/dev/null)" || return 0
    cols="$(tput cols 2>/dev/null)" || cols=80
    pct=$((step * 100 / _PROGRESS_TOTAL))
    label="Step ${step}/${_PROGRESS_TOTAL} (${pct}%)"
    bar_w=$((cols - ${#label} - 5))
    (( bar_w < 10 )) && bar_w=10
    filled=$((bar_w * step / _PROGRESS_TOTAL))
    empty=$((bar_w - filled))
    printf -v bar_f '%*s' "$filled" ''
    printf -v bar_e '%*s' "$empty" ''
    # Save cursor → draw on last row → restore cursor
    printf '\0337\033[%d;1H\033[2K' "$rows"
    if [[ -n "$GREEN" ]]; then
        printf ' %b[%b%b%s%b%s%b]%b %s' \
            "$BOLD" "$RESET" "$GREEN" "${bar_f// /█}" "$RESET" \
            "${bar_e// /░}" "$BOLD" "$RESET" "$label"
    else
        printf ' [%s%s] %s' "${bar_f// /#}" "${bar_e// /-}" "$label"
    fi
    printf '\0338'
}

# _progress_resize: SIGWINCH handler — update scroll region after terminal resize.
# shellcheck disable=SC2317
_progress_resize() {
    $_PROGRESS_ENABLED || return
    local rows
    rows="$(tput lines 2>/dev/null)" || return
    printf '\033[1;%dr' "$((rows - 1))"
    _progress_draw
}

# _progress_cleanup: restore full scroll region. Called from cleanup trap.
# shellcheck disable=SC2317
_progress_cleanup() {
    $_PROGRESS_ENABLED || return 0
    _PROGRESS_ENABLED=false
    local rows
    rows="$(tput lines 2>/dev/null)" || rows=24
    # Save cursor → reset scroll region → clear bar line → restore cursor
    printf '\0337\033[r\033[%d;1H\033[2K\0338' "$rows"
}

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

# logprintf: printf to stdout and log. Callers MUST use literal format strings.
logprintf() {
    # shellcheck disable=SC2059
    printf "$@"
    # shellcheck disable=SC2059
    printf "$@" >> "$LOG_FILE" 2>/dev/null || true
}

# _prompt: interactive prompt to stderr + log. Callers MUST use literal format strings.
_prompt() {
    # shellcheck disable=SC2059
    printf "$@" >&2
    # shellcheck disable=SC2059
    printf "$@" >> "$LOG_FILE" 2>/dev/null || true
}

# _cleanup_warn: log helper safe inside cleanup/trap. Uses $SECONDS (builtin, no subprocess).
# shellcheck disable=SC2317,SC2329
_cleanup_warn() {
    local _s="${SECONDS:-0}" _ts
    printf -v _ts '+%dm%02ds' "$((_s / 60))" "$((_s % 60))"
    printf '%s [WARN]  %s\n' "$_ts" "$*" >&2
    printf '%s [WARN]  %s\n' "$_ts" "$*" \
        >> "$LOG_FILE" 2>/dev/null || true
}

# _strip_log_ansi: single-pass ANSI removal from log file. Called once at exit.
# shellcheck disable=SC2317,SC2329
_strip_log_ansi() {
    [[ -f "$LOG_FILE" ]] || return 0
    local _tmp
    _tmp="$(mktemp "${LOG_FILE}.strip_XXXXXXXX")" || { _cleanup_warn "Cannot create tmpfile for ANSI strip"; return 1; }
    chmod 600 "$_tmp" 2>/dev/null || true
    if sed -e 's/\x1b\[[?]*[0-9;]*[A-Za-z]//g' -e 's/\x1b\][^\x07\x1b]*\x07//g' -e 's/\x1b\][^\x1b]*\x1b\\//g' -e 's/\x1b[0-9A-Za-z]//g' "$LOG_FILE" > "$_tmp" 2>/dev/null; then
        mv -- "$_tmp" "$LOG_FILE" 2>/dev/null || { rm -f -- "$_tmp"; _cleanup_warn "Cannot replace log after ANSI strip"; return 1; }
    else
        rm -f -- "$_tmp"
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
    # In-memory override for --from-step/--verify (set_checkpoint is a no-op in --dry-run)
    if [[ -n "$_CHECKPOINT_OVERRIDE" ]]; then
        echo "$_CHECKPOINT_OVERRIDE"
        return 0
    fi
    if [[ -f "$STEP_FILE" ]]; then
        local val
        val="$(cat "$STEP_FILE" 2>/dev/null)" || { warn "Cannot read checkpoint file ${STEP_FILE}. Use --reset to clear."; echo 0; return 0; }
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
    _progress_draw "$1"
    if $DRY_RUN; then
        log "[DRY-RUN] set checkpoint $1"
        return 0
    fi
    # Atomic write: tmpfile + mv prevents empty/partial checkpoint on crash
    local _ckpt_tmp
    _ckpt_tmp="$(mktemp "${STEP_FILE}.tmp_XXXXXXXX")" || { warn "Cannot create checkpoint tmpfile"; return 1; }
    printf '%s\n' "$1" > "$_ckpt_tmp" || { rm -f -- "$_ckpt_tmp"; warn "Cannot write checkpoint"; return 1; }
    mv -- "$_ckpt_tmp" "$STEP_FILE" || { rm -f -- "$_ckpt_tmp"; warn "Cannot move checkpoint into place"; return 1; }
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
    # Temporarily disable errexit+pipefail so PIPESTATUS is not reset by an || guard
    set +eo pipefail
    "$@" 2>&1 | _tee_log
    # Capture PIPESTATUS atomically — any subsequent command resets it
    local _ps=("${PIPESTATUS[@]}")
    rc=${_ps[0]}
    local _tee_rc=${_ps[1]:-0}
    # Restore caller's shell options; pipefail BEFORE errexit (see CHANGELOG 3.8.0)
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

# _write_file_impl: atomic write stdin to path with given mode, respects dry-run
_write_file_impl() {
    local dest="$1" mode="$2"
    if $DRY_RUN; then
        log "[DRY-RUN] write $dest"
        # Consume stdin so heredoc doesn't error
        cat > /dev/null
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || die "Cannot create parent dir for $dest"
    local tmp
    tmp="$(mktemp "$(dirname "$dest")/.tmp_XXXXXXXX")" || die "Cannot create tmpfile for $dest"
    cat > "$tmp" || { rm -f -- "$tmp"; die "Cannot write $dest"; }
    chmod "$mode" "$tmp" || { rm -f -- "$tmp"; die "Cannot chmod $dest"; }
    mv -- "$tmp" "$dest" || { rm -f -- "$tmp"; die "Cannot move $dest into place"; }
    if [[ "$mode" == "644" ]]; then
        log "Wrote $dest"
    else
        log "Wrote $dest (mode $mode)"
    fi
}
# write_file: atomic write stdin to path, mode 644
write_file() { _write_file_impl "$1" 644; }
# write_file_private: atomic write stdin to path, mode 600
write_file_private() { _write_file_impl "$1" 600; }
# write_file_exec: atomic write stdin to path, mode 700. For user scripts/wrappers.
write_file_exec() { _write_file_impl "$1" 700; }

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
    # Track for cleanup trap — signal between mktemp and mv would leak this file
    _SUDO_TMPFILE="$tmp"
    sudo tee "$tmp" > /dev/null || { sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""; die "Cannot write $dest"; }
    sudo chmod 644 "$tmp" || { sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""; die "Cannot chmod tmpfile for $dest"; }
    sudo mv -- "$tmp" "$dest" || { sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""; die "Cannot move $dest into place"; }
    _SUDO_TMPFILE=""
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

# check_tool: verify a CLI tool exists and print its version. Per-tool flag overrides in _TOOL_VER_FLAG.
declare -gA _TOOL_VER_FLAG=(
    [lsof]="-v"
    [dig]="-v"
    [7z]="i"
    [tmux]="-V"
    [ssh]="-V"
    [glxinfo]=""
    [xterm]="-v"
    [dosbox-x]=""
    [gnome-disks]=""
    [vulkaninfo]="--version"
)
check_tool() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        local ver="" flag
        # Resolve version flag: per-tool override if present, else --version
        if [[ -v "_TOOL_VER_FLAG[$cmd]" ]]; then
            flag="${_TOOL_VER_FLAG["$cmd"]}"
        else
            flag="--version"
        fi

        if [[ -n "$flag" ]]; then
            # Some tools (java, scummvm) output version to stderr; try stdout first
            # shellcheck disable=SC2086
            ver="$(timeout 3 "$cmd" $flag 2>/dev/null | head -1)" || true
            # Some tools (e.g. 7z i on older p7zip) emit a blank first line before the version banner.
            if [[ -z "$ver" ]]; then
                # shellcheck disable=SC2086
                ver="$(timeout 3 "$cmd" $flag 2>/dev/null | grep -m1 .)" || true
            fi
            if [[ -z "$ver" ]]; then
                # Capture stderr-only (no pipe — avoids SIGPIPE on large output)
                local _raw
                # shellcheck disable=SC2086
                _raw="$(timeout 3 "$cmd" $flag 2>&1 1>/dev/null)" || true
                ver="${_raw%%$'\n'*}"
                # Skip leading noise (e.g. unzip "caution:" or label-only version lines)
                if [[ "$ver" == caution:* || "$ver" == [Ww]arning:* || \
                      ( "$ver" == *[Vv]ersion* && "$ver" == *: && ! "$ver" =~ [0-9] ) ]]; then
                    _raw="${_raw#*$'\n'}"
                    ver="${_raw%%$'\n'*}"
                fi
            fi
        fi

        # Detect error output masquerading as a version string
        local _bad=0
        if [[ -z "$ver" ]]; then
            _bad=1
        elif [[ "$ver" == *"illegal option"* || "$ver" == *"Invalid option"* || \
                "$ver" == *"Unknown option"* || "$ver" == *"bad command line"* || \
                "$ver" == *"unrecognized option"* || "$ver" == *"invalid option"* || \
                "$ver" == ERROR:* || "$ver" == error:* || \
                "$ver" == "usage:"* || "$ver" == Usage:* ]]; then
            _bad=1
        fi

        if (( _bad )); then
            if [[ -v "_TOOL_VER_FLAG[$cmd]" && -z "${_TOOL_VER_FLAG["$cmd"]}" ]]; then
                # Explicitly no version probe — tool is present and functional
                logprintf '  %-14s %b✓%b  (installed)\n' "$name" "$GREEN" "$RESET"
                ((_verify_pass++)) || true
            else
                logprintf '  %-14s %b⚠%b  version unverified (installed)\n' "$name" "$YELLOW" "$RESET"
                ((_verify_warn++)) || true
            fi
        else
            logprintf '  %-14s %b✓%b  %s\n' "$name" "$GREEN" "$RESET" "$ver"
            ((_verify_pass++)) || true
        fi
    else
        logprintf '  %-14s %b✗%b  not found\n' "$name" "$RED" "$RESET"
        ((_verify_fail++)) || true
    fi
}

# check_config: verify a config file exists and is non-empty
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

# _parallel_check_tools "display_name|command" ...: concurrent check_tool with ordered replay
_parallel_check_tools() {
    local _pct_dir _pct_n=0 _pct_pids=()
    _pct_dir="$(mktemp -d "${TMPDIR:-/tmp}/ry-ct-XXXXXX")" || {
        warn "Cannot create tmpdir for parallel tool checks — falling back to sequential"
        local _pct_entry
        for _pct_entry in "$@"; do
            check_tool "${_pct_entry%%|*}" "${_pct_entry#*|}"
        done
        return
    }
    # Expose to cleanup trap so SIGINT during wait doesn't leak tmpdir
    _PARALLEL_TMPDIR="$_pct_dir"

    local _pct_entry _pct_idx
    for _pct_entry in "$@"; do
        printf -v _pct_idx '%04d' "$_pct_n"
        (
            # Suppress LOG_FILE writes inside subshell — replay handles logging
            LOG_FILE=/dev/null
            _verify_pass=0; _verify_fail=0; _verify_warn=0
            check_tool "${_pct_entry%%|*}" "${_pct_entry#*|}"
            # Sentinel line: SOH + counters (never appears in normal output)
            printf '\x01%d %d %d\n' "$_verify_pass" "$_verify_fail" "$_verify_warn"
        ) > "${_pct_dir}/${_pct_idx}" 2>&1 &
        _pct_pids+=($!)
        ((_pct_n++)) || true
    done

    wait "${_pct_pids[@]}" 2>/dev/null || true

    # Replay output in order; sum counters from sentinel lines
    local _pct_f _pct_line _pct_p _pct_fl _pct_w
    for _pct_f in "${_pct_dir}/"*; do
        [[ -f "$_pct_f" ]] || continue
        while IFS= read -r _pct_line; do
            if [[ "$_pct_line" == $'\x01'* ]]; then
                read -r _pct_p _pct_fl _pct_w <<< "${_pct_line#$'\x01'}"
                ((_verify_pass += _pct_p)) || true
                ((_verify_fail += _pct_fl)) || true
                ((_verify_warn += _pct_w)) || true
            else
                printf '%s\n' "$_pct_line"
                printf '%s\n' "$_pct_line" >> "$LOG_FILE" 2>/dev/null || true
            fi
        done < "$_pct_f"
    done

    rm -rf -- "$_pct_dir"
    _PARALLEL_TMPDIR=""
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
    --from-step=N  Start (or restart) from step N (1-13; N=11 is same as --verify)
    --verify       Run only steps 11-13 (verification and summary)
    --help         Show this help message
    --version      Show version
    --reset        Clear checkpoint and start from step 1
    --             Stop processing options (remaining args ignored)

STEPS PERFORMED:
     1  Preflight + ChromeOS integration (arch, bash ≥5.0, Crostini,
        Debian version, disk, GPU, network, root, sommelier, mic, USB,
        folders, ports, disk-resize; --interactive)
     2  System update (apt tuning, man-db trigger disable, Trixie
        upgrade, cros pkg hold, deb822 migration, /tmp tmpfs cap,
        cros-pin service)
     3  Core CLI utilities (curl, jq, tmux, htop, wl-clipboard,
        ripgrep, fd, fzf, bat, earlyoom, ...)
     4  Build essentials and development headers
     5  GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)
     6  Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol,
        PipeWire gaming tuning, WirePlumber ALSA tuning)
     7  Display scaling and HiDPI (sommelier, Super key passthrough,
        GTK 2/3/4, Qt platform themes, Xft DPI 96, fontconfig, cursor)
     8  GUI essentials (xterm, session support, fonts, icons)
     9  Container resource tuning (locale, journald volatile, timer
        cleanup, env, XDG, paths)
    10  Gaming packages (DOSBox-X, ScummVM, RetroArch, FluidSynth
        soundfont, innoextract/GOG, unrar/unar, box64, qemu-user,
        DOSBox-X config, run-game launcher)
    11  Verification — tools and config files
    12  Verification — scripts and assets
    13  Verification summary

CHECKPOINT:
    Progress is saved after each step to ${STEP_FILE}.
    Re-run the script to resume from where it left off.
    Use --reset to start over.

LOG:
    Full output is written to ~/ry-crostini-YYYYMMDD-HHMMSS.log
    Logs older than 7 days are removed automatically on each run.
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
            if [[ ! "$_from" =~ ^[0-9]+$ ]] || [[ "$((10#$_from))" -lt 1 ]] || [[ "$((10#$_from))" -gt 13 ]]; then
                die "--from-step requires a number 1-13 (got '${_from}')"
            fi
            # Defer checkpoint write until after lock acquisition (avoids race)
            _DEFERRED_CHECKPOINT="$((10#$_from - 1))"
            _DEFERRED_CHECKPOINT_MSG="Checkpoint set to step $((10#$_from - 1)); will resume from step $((10#$_from))."
            unset _from
            ;;
        --verify)
            if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
                die "Cannot specify --verify more than once, or combine with --from-step"
            fi
            # Defer checkpoint write until after lock acquisition (avoids race)
            _DEFERRED_CHECKPOINT="10"
            _DEFERRED_CHECKPOINT_MSG="Checkpoint set to 10; running verification only (steps 11-13)."
            ;;
        --help)    rm -f -- "$LOG_FILE" 2>/dev/null; usage ;;
        --version) rm -f -- "$LOG_FILE" 2>/dev/null; echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
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
            rm -f -- "$STEP_FILE"; rm -f -- "$LOG_FILE" 2>/dev/null; echo "Checkpoint and lock cleared."; exit 0
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
    || { rm -f -- "$_pid_tmp"; die "Cannot write PID file"; }
_LOCK_ACQUIRED=true
unset _pid_tmp

# Apply deferred checkpoint (must be inside lock to avoid race with concurrent instances)
if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
    # In-memory override ensures should_run_step works in --dry-run
    _CHECKPOINT_OVERRIDE="$_DEFERRED_CHECKPOINT"
    set_checkpoint "$_DEFERRED_CHECKPOINT" || die "Cannot write checkpoint file ${STEP_FILE} — is \$HOME writable?"
    log "$_DEFERRED_CHECKPOINT_MSG"
fi
unset _DEFERRED_CHECKPOINT _DEFERRED_CHECKPOINT_MSG

# Set noninteractive for direct dpkg/apt invocations (sudo strips this via env_reset)
export DEBIAN_FRONTEND=noninteractive

# Sudo credential keepalive — renew every 60 s; skipped in --dry-run; killed in cleanup()
if ! $DRY_RUN; then
    (while true; do sudo -v 2>/dev/null || true; sleep 60; done) &
    _SUDO_KEEPALIVE_PID=$!
    disown "$_SUDO_KEEPALIVE_PID"
fi

# Initialize progress bar (requires terminal, checkpoint, and color globals)
_progress_init

# Rotate old log files — keep last 7 days
find "$HOME" -maxdepth 1 -name 'ry-crostini-*.log' -mtime +7 -delete 2>/dev/null || true

# _gpu_conf_content: emit gpu.conf heredoc. Called by step 5 (fresh-write and upgrade-path).
_gpu_conf_content() {
    cat <<'EOF'
# Crostini GPU acceleration environment — managed by ry-crostini.sh
# ry-crostini:8.0.2
# Wayland EGL
EGL_PLATFORM=wayland
# GTK4 dark mode
GTK_THEME=Adwaita:dark
# GTK4 defaults to Vulkan renderer; virgl exposes only OpenGL — crashes or
# software fallback without this. ngl = new GL backend (GTK >= 4.14).
GSK_RENDERER=ngl

# Force virgl driver — prevents Mesa 25.x Zink regression (zen-browser/desktop#12276).
# Reverses the 4.7.7 removal: Zink crash risk now outweighs auto-detect benefit.
MESA_LOADER_DRIVER_OVERRIDE=virgl

# MESA_NO_ERROR intentionally omitted — disables all GL error checking, which is
# dangerous system-wide on virgl (invalid GL calls cross VM boundary and can hang
# host virglrenderer). Enabled per-game via run-game wrapper instead.

# Shader cache: database backend respects MAX_SIZE (single-file Fossilize ignores it);
# 256 MB cap appropriate for 128 GB eMMC. Explicit dir prevents misplacement if
# XDG_CACHE_HOME is unset.
MESA_SHADER_CACHE_DIR=${HOME}/.cache/mesa_shader_cache
MESA_SHADER_CACHE_MAX_SIZE=256M
MESA_DISK_CACHE_DATABASE=1
# Reduce database partition count from default 50 — less overhead on 4 GB RAM / eMMC
MESA_DISK_CACHE_DATABASE_NUM_PARTS=4

# mesa_glthread intentionally omitted — virgl serializes all GL through
# virtio-gpu; glthread adds marshaling overhead feeding a serial pipe.
# Enabled per-game via run-game wrapper instead.
EOF
}

# _pw_gaming_content: emit PipeWire gaming config heredoc (fresh-write and upgrade-path)
_pw_gaming_content() {
    cat <<'PWEOF'
# PipeWire core overrides for Crostini gaming — managed by ry-crostini.sh
# ry-crostini:8.0.2
# Counteracts PipeWire's KVM auto-detection which forces min-quantum=1024 (21.3 ms).
# Quantum 512 at 48 kHz = 10.67 ms latency — headroom for emulation cores with
# variable audio rates (N64, PSX). RetroArch PipeWire driver may override system
# quantum (libretro/RetroArch#17685); 512 prevents xruns.

context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum       = 512
    default.clock.min-quantum   = 512
    default.clock.max-quantum   = 2048
    clock.power-of-two-quantum  = true
    # Allow real-time memory locking for audio threads
    mem.allow-mlock             = true
    # Flush denormal floats in audio thread — prevents CPU spikes during silence on ARM64 NEON
    cpu.zero.denormals          = true
    # Reduce max link buffers from default 64 — saves memory on 4 GB system
    link.max-buffers            = 16
}

context.properties.rules = [
    {   # Explicitly override VM detection that forces min-quantum=1024
        matches = [ { cpu.vm.name = !null } ]
        actions = {
            update-props = {
                default.clock.min-quantum = 512
            }
        }
    }
]
PWEOF
}

# _pw_pulse_gaming_content: emit PipeWire-Pulse gaming config heredoc (fresh-write and upgrade-path)
_pw_pulse_gaming_content() {
    cat <<'PPEOF'
# PipeWire PulseAudio layer overrides for Crostini — managed by ry-crostini.sh
# ry-crostini:8.0.2
# pulse.properties.rules replaces deprecated vm.overrides={} (PipeWire 1.4.x)

pulse.properties = {
    pulse.min.req     = 512/48000
    pulse.min.quantum = 512/48000
}
pulse.properties.rules = [
    { matches = [ { cpu.vm.name = !null } ]
      actions = { update-props = { pulse.min.quantum = 512/48000 } }
    }
]
PPEOF
}

# _gtk_settings_content: emit GTK 3/4 settings.ini heredoc. Called by step 7 (GTK 3 and GTK 4).
_gtk_settings_content() {
    cat <<'GTKEOF'
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
GTKEOF
}

# Step 1: Preflight + ChromeOS integration
if should_run_step 1; then
    step_banner 1 "Preflight + ChromeOS integration (arch, bash ≥5.0, Crostini, Debian version, disk, GPU, network, root, sommelier, mic, USB, folders, ports, disk-resize; --interactive)"

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

    # 1b. Bash version (mapfile, PIPESTATUS, local -a require bash 4+; 5.0 for consistency)
    if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
        die "Requires bash 5.0+ (got ${BASH_VERSION:-unknown}). Crostini ships bash 5.x by default."
    fi

    # 1c. Crostini container detection
    if [[ -f /dev/.cros_milestone ]]; then
        log "ChromeOS milestone: $(cat /dev/.cros_milestone) ✓"
    elif [[ -d /mnt/chromeos ]]; then
        log "Crostini mount point detected ✓"
    else
        warn "Cannot confirm Crostini environment. Proceeding anyway."
    fi

    # 1d. Debian version
    if [[ -f /etc/os-release ]]; then
        _os_pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
        _os_codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-bookworm}")"
        if [[ ! "$_os_codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
            warn "VERSION_CODENAME '${_os_codename}' looks suspicious — defaulting to bookworm"
            _os_codename="bookworm"
        fi
        log "Container OS: ${_os_pretty} (${_os_codename}) ✓"
        unset _os_pretty
    else
        _os_codename="bookworm"
    fi

    # 1e. Disk space check (need at least 2 GB free)
    AVAIL_KB="$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')" || true
    if [[ ! "$AVAIL_KB" =~ ^[0-9]+$ ]]; then
        die "Cannot determine available disk space (df returned '${AVAIL_KB:-empty}')"
    fi
    AVAIL_MB=$((AVAIL_KB / 1024))
    if [[ "$AVAIL_MB" -lt 2048 ]]; then
        die "Insufficient disk space: ${AVAIL_MB} MB available, need at least 2048 MB. Resize: Settings → Developers → Linux → Disk size."
    fi
    log "Available disk: ${AVAIL_MB} MB ✓"

    # 1f. GPU acceleration warning (disabled by default since ChromeOS 131)
    if [[ ! -e /dev/dri/renderD128 ]]; then
        warn "IMPORTANT: GPU acceleration is disabled by default since ChromeOS 131."
        warn "Enable: chrome://flags#crostini-gpu-support → Enabled → full Chromebook reboot."
        warn "GPU packages will be installed regardless; /dev/dri/renderD128 requires the flag."
    else
        log "GPU render node: /dev/dri/renderD128 already active ✓"
    fi

    # 1g. Network connectivity (uses detected codename for repo URL)
    if $DRY_RUN; then
        log "[DRY-RUN] skip network check"
    elif curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 3 --max-time 5 "https://deb.debian.org/debian/dists/${_os_codename}/Release.gpg" -o /dev/null 2>/dev/null; then
        log "Network connectivity: ✓"
    else
        warn "Cannot reach deb.debian.org. Some steps may fail without network."
    fi

    # 1h. Not running as root
    if [[ "$EUID" -eq 0 ]]; then
        if $DRY_RUN; then
            warn "[DRY-RUN] Running as root. Would abort in live mode."
        else
            die "Do not run this script as root. Run as your normal user (sudo is used internally where needed)."
        fi
    fi
    log "Running as user: $(whoami) ✓"

    # 1i. Sommelier (Wayland bridge) — needed for all GUI apps
    if pgrep -x sommelier &>/dev/null; then
        log "Sommelier (Wayland bridge): running ✓"
    else
        log "Sommelier not yet active — will start on terminal restart ✓"
    fi

    unset CURRENT_ARCH AVAIL_KB AVAIL_MB _os_codename

    # 1j. GPU acceleration + pointer lock (ChromeOS integration)
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU acceleration: ALREADY ACTIVE ✓"
        log "Pointer lock: verify chrome://flags/#exo-pointer-lock is Enabled (required for mouse capture in games)"
    else
        log "GPU acceleration not detected."
        if ! $DRY_RUN; then
            if ! $UNATTENDED; then
                _prompt '%b  → The chrome://flags page is opening in ChromeOS now.%b\n' "$YELLOW" "$RESET"
                _prompt '%b  → Search for "crostini-gpu-support" and set to "Enabled".%b\n' "$YELLOW" "$RESET"
                _prompt '%b  → Also enable "exo-pointer-lock" (required for mouse capture in games).%b\n' "$YELLOW" "$RESET"
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

    # 1k. Microphone access
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

    # 1l. USB device passthrough
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

    # 1m. Shared folders
    if [[ -d /mnt/chromeos ]]; then
        SHARED_COUNT="$(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d -printf '.' 2>/dev/null | wc -c)" || true
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

    # 1n. Port forwarding
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

    # 1o. Disk size check
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
    set_checkpoint 1
    log "Step 1 complete."
fi
# Step 2: System update
if should_run_step 2; then
    step_banner 2 "System update (apt tuning, man-db trigger disable, Trixie upgrade, cros pkg hold, deb822 migration, /tmp tmpfs cap, cros-pin service)"

    # Enable parallel downloads and HTTP pipelining (Pipeline-Depth applies to HTTP only)
    APT_PARALLEL="/etc/apt/apt.conf.d/90parallel"
    if [[ ! -f "$APT_PARALLEL" ]]; then
        write_file_sudo "$APT_PARALLEL" <<'EOF'
// apt download tuning — managed by ry-crostini.sh
Acquire::Queue-Mode "access";
Acquire::http::Pipeline-Depth "0";
Acquire::Languages "none";
// Retry transient failures (WiFi drops, CDN hiccups) — critical for mobile device
Acquire::Retries "3";
EOF
    else
        log "Parallel apt config already exists"
    fi
    unset APT_PARALLEL

    # Disable man-db auto-update trigger (30-60 s on ARM64 per apt install)
    if $DRY_RUN; then
        log "[DRY-RUN] disable man-db auto-update"
    elif command -v debconf-communicate &>/dev/null; then
        if echo "set man-db/auto-update false" | sudo debconf-communicate &>/dev/null; then
            log "man-db auto-update disabled (run 'sudo mandb' manually when needed)"
        else
            warn "man-db auto-update disable failed — non-fatal"
        fi
    fi

    # 2a. Upgrade to Trixie if not already running it
    _cur_codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")" || true
    if [[ -n "$_cur_codename" ]] && [[ ! "$_cur_codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
        die "VERSION_CODENAME '${_cur_codename}' contains unexpected characters — aborting"
    fi
    if [[ "$_cur_codename" != "trixie" ]] && [[ -n "$_cur_codename" ]]; then
        log "Current release: ${_cur_codename} — upgrading to Trixie (Debian 13)"
        if $DRY_RUN; then
            log "[DRY-RUN] cp /etc/apt/sources.list /etc/apt/sources.list.pre-trixie"
            log "[DRY-RUN] sed -i on deb/deb-src lines: ${_cur_codename} → trixie in /etc/apt/sources.list"
            log "[DRY-RUN] sed -i on repo lines: ${_cur_codename} → trixie in cros.list and additional .list/.sources in sources.list.d/ (with backup to /etc/apt/)"
        else
            # Back up sources before rewriting
            if ! run sudo cp /etc/apt/sources.list /etc/apt/sources.list.pre-trixie; then
                die "Cannot back up /etc/apt/sources.list — aborting upgrade"
            fi
            # Rewrite: bookworm → trixie on deb/deb-src lines only (preserves comments)
            if ! run sudo sed -i "/^deb/s/${_cur_codename}/trixie/g" /etc/apt/sources.list; then
                warn "sources.list rewrite failed — restoring backup"
                run sudo cp -- /etc/apt/sources.list.pre-trixie /etc/apt/sources.list \
                    || die "Cannot restore sources.list backup — manual fix required"
                die "Trixie upgrade aborted"
            fi
            log "Rewrote /etc/apt/sources.list: ${_cur_codename} → trixie"
            # Also update cros-packages repo if present (resets on container restart)
            if [[ -f /etc/apt/sources.list.d/cros.list ]]; then
                run sudo cp /etc/apt/sources.list.d/cros.list /etc/apt/cros.list.pre-trixie || true
                if run sudo sed -i "/^deb/s/${_cur_codename}/trixie/g" /etc/apt/sources.list.d/cros.list; then
                    log "Rewrote cros.list: ${_cur_codename} → trixie"
                    log "NOTE: cros.list resets on container restart (ChromeOS regenerates it)"
                    log "Debian repos in sources.list are permanent — only cros-packages affected"
                else
                    warn "cros.list rewrite failed — continuing (non-fatal)"
                fi
            fi
            # Also handle additional .list/.sources files; backups in /etc/apt/ (not sources.list.d/)
            _had_nullglob=false
            shopt -q nullglob && _had_nullglob=true
            shopt -s nullglob
            for _sfile in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                [[ -f "$_sfile" ]] || continue
                if grep -q "${_cur_codename}" "$_sfile" 2>/dev/null; then
                    _sfile_bak="/etc/apt/$(basename "$_sfile").pre-trixie"
                    run sudo cp -- "$_sfile" "$_sfile_bak" \
                        || { warn "Cannot back up ${_sfile} — skipping"; continue; }
                    # .list format: replace on deb/deb-src lines; .sources (deb822): replace on Suites: lines
                    if [[ "$_sfile" == *.sources ]]; then
                        run sudo sed -i "/^Suites:/s/${_cur_codename}/trixie/g" "$_sfile" \
                            || warn "Failed to update ${_sfile} — backup at ${_sfile_bak}"
                    else
                        run sudo sed -i "/^deb/s/${_cur_codename}/trixie/g" "$_sfile" \
                            || warn "Failed to update ${_sfile} — backup at ${_sfile_bak}"
                    fi
                fi
            done
            $_had_nullglob || shopt -u nullglob
            unset _sfile _sfile_bak _had_nullglob
        fi
    elif [[ "$_cur_codename" == "trixie" ]]; then
        log "Already running Trixie — no upgrade needed"
    else
        die "Cannot determine current release codename — aborting"
    fi
    unset _cur_codename

    # 2b. Update and upgrade — hold cros-* during dist-upgrade; single dpkg-query replaces 9 forks
    mapfile -t _CROS_HOLD_PKGS < <(
        dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
            cros-guest-tools cros-garcon cros-notificationd \
            cros-sftp cros-sommelier cros-sommelier-config \
            cros-wayland cros-pulse-config cros-apt-config 2>/dev/null \
        | awk '/^ii/{print $2}'
    )
    if [[ "${#_CROS_HOLD_PKGS[@]}" -gt 0 ]]; then
        if $DRY_RUN; then
            log "[DRY-RUN] apt-mark hold ${_CROS_HOLD_PKGS[*]}"
        else
            run sudo apt-mark hold "${_CROS_HOLD_PKGS[@]}" \
                || warn "apt-mark hold failed — Crostini packages may be upgraded (risky)"
            log "Held Crostini packages: ${_CROS_HOLD_PKGS[*]}"
        fi
    fi

    if run sudo DEBIAN_FRONTEND=noninteractive apt-get update; then
        # --force-confdef --force-confold: prevent interactive dpkg prompts during upgrade
        run sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            || warn "apt upgrade had issues"
        # NOTE: dpkg /lib/* "Directory not empty" warnings during Trixie upgrade are harmless (UsrMerge)
        log "NOTE: dpkg /lib/* directory warnings during upgrade are expected (UsrMerge transition)"
        run sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            || warn "apt-get full-upgrade had issues"
    else
        warn "apt update failed — skipping upgrade (stale package indices)"
    fi

    # @@WHY: cros-guest-tools stays held permanently (cros-im unavailable on Trixie)
    _CROS_UNHOLD_PKGS=()
    for _cpkg in "${_CROS_HOLD_PKGS[@]}"; do
        [[ "$_cpkg" == "cros-guest-tools" ]] && continue
        _CROS_UNHOLD_PKGS+=("$_cpkg")
    done
    if [[ "${#_CROS_UNHOLD_PKGS[@]}" -gt 0 ]]; then
        if $DRY_RUN; then
            log "[DRY-RUN] apt-mark unhold ${_CROS_UNHOLD_PKGS[*]}"
            log "[DRY-RUN] cros-guest-tools remains held (cros-im unavailable on Trixie)"
        else
            run sudo apt-mark unhold "${_CROS_UNHOLD_PKGS[@]}" || warn "apt-mark unhold failed"
            log "cros-guest-tools remains held (cros-im unavailable on Trixie)"
        fi
    fi
    unset _CROS_HOLD_PKGS _CROS_UNHOLD_PKGS _cpkg

    # @@WHY: No --purge — conffiles may be needed by Crostini packages at next boot
    run sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || warn "apt autoremove had issues"

    # 2c. Verify upgrade landed on Trixie
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

    # 2d. Cap /tmp tmpfs at 512M (OOM mitigation for 4 GB RAM; write before first Trixie restart)
    _TMP_DROPIN="/etc/systemd/system/tmp.mount.d/override.conf"
    if [[ ! -f "$_TMP_DROPIN" ]]; then
        if $DRY_RUN; then
            log "[DRY-RUN] cap /tmp tmpfs at 512M via drop-in"
        else
            write_file_sudo "$_TMP_DROPIN" <<'TMPEOF'
[Mount]
Options=mode=1777,nosuid,nodev,size=512M
TMPEOF
            run sudo systemctl daemon-reload \
                || warn "daemon-reload failed — /tmp cap takes effect on next container start"
            log "/tmp tmpfs capped at 512M (OOM mitigation)"
        fi
    else
        log "tmp.mount drop-in already exists"
    fi
    unset _TMP_DROPIN

    # 2e. Migrate APT sources to deb822 format
    if $DRY_RUN; then
        log "[DRY-RUN] apt -y modernize-sources"
    elif apt --help 2>/dev/null | grep -q 'modernize-sources'; then
        if run sudo DEBIAN_FRONTEND=noninteractive apt -y modernize-sources; then
            log "APT sources migrated to deb822 format"
            # Guard: modernize-sources may create cros.sources while cros.list remains, causing duplicate entries.
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
        warn "apt modernize-sources not available — apt may need upgrading"
    fi

    # 2f. Service to remove stale cros.list (ChromeOS regenerates it with old codename on restart)
    _CROS_PIN_SVC="/etc/systemd/system/ry-crostini-cros-pin.service"
    if [[ ! -f "$_CROS_PIN_SVC" ]]; then
        write_file_sudo "$_CROS_PIN_SVC" <<'CROSEOF'
[Unit]
Description=Remove stale cros.list when cros.sources is present
DefaultDependencies=no
Before=apt-daily.service apt-daily-upgrade.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c \
    'if [ -f /etc/apt/sources.list.d/cros.sources ] && \
        [ -f /etc/apt/sources.list.d/cros.list ]; then \
        mv /etc/apt/sources.list.d/cros.list /etc/apt/cros.list.regenerated; \
    fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
CROSEOF
        run sudo systemctl daemon-reload \
            || warn "daemon-reload failed — ry-crostini-cros-pin.service enable may fail"
        run sudo systemctl enable ry-crostini-cros-pin.service \
            || warn "ry-crostini-cros-pin.service enable failed"
        log "ry-crostini-cros-pin.service enabled (removes stale cros.list on container restart)"
    else
        log "ry-crostini-cros-pin.service already exists"
    fi
    unset _CROS_PIN_SVC

    set_checkpoint 2
    log "Step 2 complete."
fi
# Step 3: Core CLI utilities (curl, jq, tmux, htop, wl-clipboard, ripgrep, fd, fzf, bat, ...)
if should_run_step 3; then
    step_banner 3 "Core CLI utilities (curl, jq, tmux, htop, wl-clipboard, ripgrep, fd, fzf, bat, earlyoom, ...)"

    CORE_PKGS=(
        # Navigation and file management
        file tree zip unzip 7zip rsync rename

        # Text processing
        nano vim less jq

        # Network utilities
        curl wget dnsutils openssh-client
        ca-certificates gnupg

        # System monitoring
        htop ncdu lsof strace

        # Misc
        tmux screen man-db bash-completion locales

        # Wayland clipboard (wl-copy / wl-paste for terminal ↔ GUI integration)
        wl-clipboard

        # Rust CLI alternatives — enhanced replacements for grep/find/cat
        ripgrep fd-find fzf bat
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

    # earlyoom: userspace OOM killer — kernel OOM too late in containers, systemd-oomd needs cgroup v2
    if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom; then
        if ! $DRY_RUN; then
            _EARLYOOM_CONF="/etc/default/earlyoom"
            # @@WHY: marker check is self-healing — apt upgrade loss or fresh install both trigger re-write
            if [[ ! -f "$_EARLYOOM_CONF" ]] || ! grep -q 'ry-crostini' "$_EARLYOOM_CONF"; then
                write_file_sudo "$_EARLYOOM_CONF" <<'EOOMEOF'
# earlyoom config — managed by ry-crostini.sh
EARLYOOM_ARGS="-m 10 -s 10 -p --prefer '(retroarch|box64|wine|dosbox-x|scummvm)' --avoid '(^|/)(init|systemd|dbus-daemon|garcon|sommelier)$' --sort-by-rss -r 3600"
EOOMEOF
            fi
            run sudo systemctl enable --now earlyoom.service \
                || warn "earlyoom enable failed"
            log "earlyoom installed and enabled"
            unset _EARLYOOM_CONF
        fi
    else
        warn "earlyoom install failed — OOM protection unavailable"
    fi

    set_checkpoint 3
    log "Step 3 complete."
fi
# Step 4: Build essentials and development headers
if should_run_step 4; then
    step_banner 4 "Build essentials and development headers"

    DEV_PKGS=(
        build-essential gcc g++ make cmake pkg-config
        autoconf automake libtool
        libssl-dev libffi-dev zlib1g-dev libbz2-dev
        libreadline-dev libsqlite3-dev libncurses-dev
        libxml2-dev libxslt1-dev liblzma-dev libgdbm-dev
    )

    install_pkgs_best_effort "${DEV_PKGS[@]}" || warn "Some dev packages unavailable — non-fatal"

    unset DEV_PKGS
    set_checkpoint 4
    log "Step 4 complete."
fi

# Step 5: GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)
if should_run_step 5; then
    step_banner 5 "GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan)"

    # Stable packages — canonical names for Bookworm and Trixie arm64
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

    # Volatile packages — names may differ across Debian versions
    GPU_VOLATILE_PKGS=(
        mesa-vulkan-drivers
        libgl1
        vulkan-tools
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
        _gpu_conf_content | write_file "$GPU_ENV_FILE"
    else
        log "GPU env already exists — skipping"
    fi

    unset GL_VENDOR GL_RENDERER GL_VERSION GPU_ENV_FILE GPU_STABLE_PKGS GPU_VOLATILE_PKGS
    set_checkpoint 5
    log "Step 5 complete."
fi
# Step 6: Audio stack
if should_run_step 6; then
    step_banner 6 "Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol, PipeWire gaming tuning, WirePlumber ALSA tuning)"

    AUDIO_PKGS=(
        # ALSA — libasound2/libasound2t64 pulled in by alsa-utils
        alsa-utils
        libasound2-plugins

        # PipeWire audio metapackage (pipewire + wireplumber + pipewire-pulse + pipewire-alsa)
        pipewire-audio

        # PulseAudio client utilities + GUI mixer
        pulseaudio-utils
        pavucontrol

        # GStreamer codecs (gstreamer1.0-pulseaudio removed; plugin is in -plugins-good)
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
        gstreamer1.0-alsa
    )
    # Append in same transaction so apt resolves the full dep graph at once
    AUDIO_PKGS+=(libavcodec-extra)

    install_pkgs_best_effort "${AUDIO_PKGS[@]}" || warn "Some audio packages unavailable — non-fatal"

    # Mask legacy PulseAudio daemon if present; ensure PipeWire audio chain is active
    if ! $DRY_RUN; then
        if dpkg -l pulseaudio 2>/dev/null | grep -q '^ii'; then
            if run systemctl --user mask --now pulseaudio.service pulseaudio.socket; then
                log "PulseAudio daemon masked (PipeWire provides pulse compatibility)"
            else
                warn "PulseAudio mask failed — PipeWire may conflict"
            fi
        fi
        if run systemctl --user enable --now pipewire.socket pipewire-pulse.socket; then
            log "PipeWire sockets enabled"
        else
            warn "PipeWire socket enable failed"
        fi
    else
        log "[DRY-RUN] systemctl --user mask --now pulseaudio.service pulseaudio.socket (if installed)"
        log "[DRY-RUN] systemctl --user enable --now pipewire.socket pipewire-pulse.socket"
    fi

    # libavcodec-extra is now included in AUDIO_PKGS above (same transaction).

    # Verify audio
    if [[ -d /dev/snd ]]; then
        SND_DEV_COUNT="$(find /dev/snd -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)" || true
        log "Audio devices in /dev/snd: ${SND_DEV_COUNT} ✓"
        if [[ -e /dev/snd/pcmC0D0c ]] || [[ -e /dev/snd/pcmC1D0c ]]; then
            log "Microphone capture device: detected ✓"
        else
            warn "No capture device. Enable mic: Settings → Developers → Linux → Microphone"
        fi
    else
        warn "/dev/snd not found. Audio may not work until container restart."
    fi

    # PipeWire gaming overrides — counteract KVM VM auto-detection (min-quantum=1024)
    _PW_GAMING="${HOME}/.config/pipewire/pipewire.conf.d/10-ry-crostini-gaming.conf"
    if [[ ! -f "$_PW_GAMING" ]]; then
        _pw_gaming_content | write_file "$_PW_GAMING"
    else
        log "PipeWire gaming config already exists"
    fi
    unset _PW_GAMING

    # PipeWire-Pulse user-level gaming override — disable pulse-layer VM quantum override
    _PW_PULSE_GAMING="${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-ry-crostini-gaming.conf"
    if [[ ! -f "$_PW_PULSE_GAMING" ]]; then
        _pw_pulse_gaming_content | write_file "$_PW_PULSE_GAMING"
    else
        log "PipeWire-Pulse gaming config already exists"
    fi
    unset _PW_PULSE_GAMING

    # WirePlumber ALSA tuning — optimizes ALSA node buffer parameters for gaming latency
    _WP_ALSA="${HOME}/.config/wireplumber/wireplumber.conf.d/51-crostini-alsa.conf"
    if [[ ! -f "$_WP_ALSA" ]]; then
        write_file "$_WP_ALSA" <<'WPEOF'
# WirePlumber ALSA tuning for Crostini gaming — managed by ry-crostini.sh
# ry-crostini:8.0.2
# Optimizes ALSA node buffer parameters; disables auto-suspend.
# WirePlumber 0.5+ JSON .conf format (Trixie ships 0.5.8).
# Virtio-snd is a batch device — do NOT set api.alsa.disable-batch=true,
# which removes PipeWire's native batch compensation and forces excessive
# headroom. Let PipeWire handle batch timing natively.

monitor.alsa.rules = [
    {
        matches = [ { node.name = "~alsa_output.*" } ]
        actions = {
            update-props = {
                api.alsa.period-size              = 512
                api.alsa.period-num               = 3
                api.alsa.headroom                 = 2048
                session.suspend-timeout-seconds   = 0
            }
        }
    }
]
WPEOF
    else
        log "WirePlumber ALSA config already exists"
    fi
    unset _WP_ALSA

    unset AUDIO_PKGS SND_DEV_COUNT
    set_checkpoint 6
    log "Step 6 complete."
fi
# Step 7: Display scaling and HiDPI
if should_run_step 7; then
    step_banner 7 "Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt platform themes, Xft DPI 96, fontconfig, cursor)"

    # 13.3in FHD OLED — configure sommelier, GTK 2/3/4, Qt, Xft, fontconfig, cursor

    # 7a. Sommelier environment (controls Linux app scaling)
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

    # 7b. GTK 3 settings
    GTK3_SETTINGS="${HOME}/.config/gtk-3.0/settings.ini"
    if [[ ! -f "$GTK3_SETTINGS" ]]; then
        _gtk_settings_content | write_file "$GTK3_SETTINGS"
    else
        log "GTK 3 settings.ini already exists — skipping"
    fi

    # 7c. GTK 4 settings
    GTK4_SETTINGS="${HOME}/.config/gtk-4.0/settings.ini"
    if [[ ! -f "$GTK4_SETTINGS" ]]; then
        _gtk_settings_content | write_file "$GTK4_SETTINGS"
    else
        log "GTK 4 settings.ini already exists — skipping"
    fi

    # 7d. GTK 2 settings (legacy apps)
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

    # 7e. Qt scaling and theming
    QT_ENV="${HOME}/.config/environment.d/qt.conf"
    if [[ ! -f "$QT_ENV" ]]; then
        write_file "$QT_ENV" <<'EOF'
# Qt theming — QT_AUTO_SCREEN_SCALE_FACTOR removed (deprecated Qt 5.14, ignored in Qt 6)
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
QT_QPA_PLATFORMTHEME=gtk3
EOF
    else
        log "Qt env already exists — skipping"
    fi

    # Qt GTK platform theme plugins (no qt5ct — conflicts with =gtk3); single batch install
    install_pkgs_best_effort qt5-gtk-platformtheme adwaita-qt adwaita-qt6 qt6-gtk-platformtheme || \
        warn "Some Qt theme packages not available — Qt apps may not fully follow dark theme"

    # 7f. Xft / Xresources (for pure X11 apps)
    XRESOURCES="${HOME}/.Xresources"
    if [[ ! -f "$XRESOURCES" ]]; then
        write_file "$XRESOURCES" <<'EOF'
! Font rendering for X11 apps on Duet 5 (13.3in 1920x1080 OLED)
! OLED has no LCD subpixel stripe — use grayscale AA (rgba=none)
! NOTE: sommelier passes DPI to X clients via Xwayland DPI buckets (72, 96, 160, 240).
! 96 matches the nearest bucket for FHD@13.3in and avoids inconsistent sizing
! between Xresources-reading X11 apps and Wayland-native apps.
Xft.dpi: 96
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

    # 7g. Fontconfig (grayscale AA for OLED, Noto defaults)
    FC_LOCAL="${HOME}/.config/fontconfig/fonts.conf"
    if [[ ! -f "$FC_LOCAL" ]]; then
        write_file "$FC_LOCAL" <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- ry-crostini:8.0.2 -->
<fontconfig>
  <!-- Grayscale antialiasing for OLED display (no LCD subpixel stripe) -->
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>none</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcdnone</const></edit>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
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
        if run timeout 60 fc-cache -f; then
            $DRY_RUN || log "Font cache rebuilt"
        else
            warn "fc-cache failed — font cache not rebuilt"
        fi
    fi

    # 7h. Cursor theme (ensure consistency across toolkits)
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
    set_checkpoint 7
    log "Step 7 complete."
fi
# Step 8: GUI essentials (xterm, session support, fonts, icons)
if should_run_step 8; then
    step_banner 8 "GUI essentials (xterm, session support, fonts, icons)"

    GUI_PKGS=(
        xdg-utils

        # Session support: D-Bus, accessibility, desktop notifications
        dbus-x11
        at-spi2-core
        libnotify-bin

        # Terminal emulator — standard X11 fallback that sensible-terminal and xdg-terminal-exec resolve to.
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

    # gnome-disk-utility — heavy GNOME deps but useful for disk management
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-disk-utility \
        || warn "gnome-disk-utility install failed"

    # Ensure desktop applications directory exists (garcon integration)
    if run mkdir -p "${HOME}/.local/share/applications"; then
        $DRY_RUN || log "Desktop applications directory: ${HOME}/.local/share/applications ✓"
    else
        warn "Cannot create desktop applications directory"
    fi

    unset GUI_PKGS
    set_checkpoint 8
    log "Step 8 complete."
fi
# Step 9: Container resource tuning (sysctl keys are read-only in Crostini — removed)
if should_run_step 9; then
    step_banner 9 "Container resource tuning (locale, journald volatile, timer cleanup, env, XDG, paths)"

    # 9a. Set locale to en_US.UTF-8
    if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
        # @@WHY: Gate sed on successful backup — cp failure means no rollback
        if run sudo cp /etc/locale.gen /etc/locale.gen.bak; then
            if run sudo sed -i 's/^# *en_US\.UTF-8/en_US.UTF-8/' /etc/locale.gen; then
                if run timeout 120 sudo locale-gen; then
                    if ! $DRY_RUN; then
                        run sudo rm -f -- /etc/locale.gen.bak || true
                        log "en_US.UTF-8 locale generated"
                    fi
                else
                    warn "locale-gen failed — locale.gen modified but generation incomplete; backup at /etc/locale.gen.bak"
                fi
            else
                warn "locale.gen edit failed — restoring backup"
                run sudo cp -- /etc/locale.gen.bak /etc/locale.gen || warn "Rollback of locale.gen failed — manual restore from /etc/locale.gen.bak required"
                run sudo rm -f -- /etc/locale.gen.bak || true
            fi
        else
            warn "locale.gen backup failed — skipping locale edit to avoid unrecoverable corruption"
        fi
    else
        log "en_US.UTF-8 locale already available"
    fi

    # 9b. Journald volatile storage — write logs to RAM only (saves eMMC I/O)
    _JOURNALD_VOL="/etc/systemd/journald.conf.d/volatile.conf"
    if [[ ! -f "$_JOURNALD_VOL" ]]; then
        write_file_sudo "$_JOURNALD_VOL" <<'JDEOF'
[Journal]
Storage=volatile
RuntimeMaxUse=50M
RuntimeMaxFileSize=10M
JDEOF
        run sudo systemctl restart systemd-journald \
            || warn "journald restart failed — volatile storage takes effect on next container start"
        log "Journald set to volatile (RAM-only) storage"
    else
        log "Journald volatile config already exists"
    fi
    unset _JOURNALD_VOL

    # 9c. Master environment profile (shell-agnostic via /etc/profile.d)
    PROFILE_D="/etc/profile.d/ry-crostini-env.sh"
    if [[ ! -f "$PROFILE_D" ]]; then
        write_file_sudo "$PROFILE_D" <<'ENVEOF'
# Crostini environment defaults — managed by ry-crostini.sh
export LANG="en_US.UTF-8"
export EDITOR="vim"
export VISUAL="vim"
export PAGER="less"
export LESS="-R -F -X"

# PATH helper — prepend only if dir exists and is not already in PATH
_ry_crostini_path_prepend() {
    case ":$PATH:" in
        *:"$1":*) ;;
        *) export PATH="$1:$PATH" ;;
    esac
}

# Local bin (user scripts)
[ -d "$HOME/.local/bin" ] && _ry_crostini_path_prepend "$HOME/.local/bin"

unset -f _ry_crostini_path_prepend
ENVEOF
    else
        log "Environment profile already exists"
    fi

    # 9d. Ensure XDG dirs exist
    run mkdir -p "${HOME}/.local/share" "${HOME}/.local/bin" "${HOME}/.config" "${HOME}/.cache" \
        || warn "Cannot create XDG directories"
    if command -v xdg-user-dirs-update &>/dev/null; then
        if run xdg-user-dirs-update; then
            $DRY_RUN || log "XDG user directories updated"
        else
            warn "xdg-user-dirs-update failed"
        fi
    fi

    unset PROFILE_D

    # 9e. Disable background timers (compete for I/O/RAM during gaming)
    if ! $DRY_RUN; then
        # apt-daily.timer: kept enabled — refreshes package lists so `apt upgrade`
        # shows pending security fixes. apt-daily-upgrade.timer: disabled — prevents
        # unattended installs that compete for I/O during gaming.
        run sudo systemctl disable apt-daily-upgrade.timer \
            || warn "Cannot disable apt-daily-upgrade timer"
        # Batch mask — guard with list-unit-files to avoid dead symlinks
        _mask_timers=()
        for _timer in fstrim.timer e2scrub_all.timer man-db.timer; do
            systemctl list-unit-files --no-legend "$_timer" 2>/dev/null | grep -q . && _mask_timers+=("$_timer")
        done
        if [[ "${#_mask_timers[@]}" -gt 0 ]]; then
            run sudo systemctl mask "${_mask_timers[@]}" || true
        fi
        log "Unnecessary timers disabled/masked"
        unset _timer _mask_timers
    else
        log "[DRY-RUN] disable apt-daily-upgrade, fstrim, e2scrub, man-db timers"
    fi

    set_checkpoint 9
    log "Step 9 complete."
fi
# Step 10: Gaming packages
if should_run_step 10; then
    step_banner 10 "Gaming packages (DOSBox-X, ScummVM, RetroArch, FluidSynth soundfont, innoextract/GOG, unrar/unar, box64, qemu-user, DOSBox-X config, run-game launcher)"

    # Native ARM gaming packages — single batch; unrar (non-free) attempted separately below
    install_pkgs_best_effort scummvm fluid-soundfont-gm innoextract unar \
        dosbox-x retroarch retroarch-assets || warn "Some gaming packages failed"
    # Attempt non-free unrar separately; failure is non-fatal
    if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unrar; then
        log "unrar installed ✓"
    else
        log "unrar not available (non-free not enabled) — unar will be used for RAR archives ✓"
    fi

    # RetroArch default config
    _RA_CFG="${HOME}/.config/retroarch/retroarch.cfg"
    if [[ ! -f "$_RA_CFG" ]]; then
        write_file_private "$_RA_CFG" <<'RACFG'
# RetroArch Crostini config — managed by ry-crostini.sh
# Written once on first install; edit freely afterward.

# Video: glcore works on virgl's GL 4.3 core profile and enables slang shaders.
# Threaded video disabled — interferes with video_frame_delay_auto timing and
# frame pacing (Libretro docs). Enable per-core override for N64/PSP if needed.
video_driver = "glcore"
video_threaded = "false"
video_vsync = "true"
video_frame_delay_auto = "true"
# Manual floor — prevents auto algorithm from collapsing to zero in VM (timing jitter)
video_frame_delay = "4"

# Audio: ALSA driver routes through PipeWire's ALSA compatibility layer.
# PipeWire native driver has broken audio_latency control in RetroArch 1.20.0
# (libretro/RetroArch#17685). Switch to audio_driver = "pipewire" after 1.21.0+.
audio_driver = "alsa"
audio_latency = "64"

# Input: late polling reduces input-to-screen latency by polling as late as
# possible in the frame cycle.
input_poll_type_behavior = "2"

# Display: reduce swap chain from default 3 to 2 — cuts display latency by ~16 ms
video_max_swapchain_images = "2"

# Memory: disable rewind (consumes ~20 MB/min buffer on 4 GB device).
# Preemptive Frames: lower-overhead alternative to Run-Ahead; enable per-core
# for 8/16-bit cores only (see README). Requires deterministic frame state.
# Uses run_ahead_frames for count.
rewind_enable = "false"
run_ahead_enabled = "false"
preempt_enable = "false"

# Misc
savestate_compression = "true"
menu_driver = "rgui"
RACFG
    else
        log "RetroArch config already exists — skipping"
    fi
    unset _RA_CFG

    # ScummVM default config
    _SVM_CFG="${HOME}/.config/scummvm/scummvm.ini"
    if [[ ! -f "$_SVM_CFG" ]]; then
        write_file_private "$_SVM_CFG" <<'SVMCFG'
# ScummVM Crostini config — managed by ry-crostini.sh
# Written once on first install; edit freely afterward.
[scummvm]
gfx_mode=opengl
stretch_mode=pixel-perfect
# Alternative: stretch_mode=even-pixels (ScummVM 2.9+) — scales width/height by
# different integer factors for better aspect ratio approximation on 1920×1080.
aspect_ratio=true
filtering=false
vsync=true
music_driver=fluidsynth
soundfont=/usr/share/sounds/sf2/FluidR3_GM.sf2
# Match PipeWire native 48 kHz — eliminates resampling overhead on ARM64
output_rate=48000
# Disable chorus effect — saves 5–8% CPU on SC7180P
fluidsynth_chorus_activate=false
# Linear interpolation — ~30-50% less FluidSynth CPU vs default 4th-order; negligible audible difference
fluidsynth_misc_interpolation=linear
SVMCFG
    else
        log "ScummVM config already exists — skipping"
    fi
    unset _SVM_CFG

    # DOSBox-X default config
    _DBX_CFG="${HOME}/.config/dosbox-x/dosbox-x.conf"
    if [[ ! -f "$_DBX_CFG" ]]; then
        write_file_private "$_DBX_CFG" <<'DBXCFG'
# DOSBox-X Crostini config — managed by ry-crostini.sh
# Written once on first install; edit freely afterward.

[sdl]
# GPU-accelerated rendering via virgl; nearest-neighbor (no bilinear blur)
output=openglnb
# Built-in pixel-perfect GLSL shader
glshader=sharp

[cpu]
# ARM64 dynamic recompiler — 3-4× speedup over interpreter.
# Verify: dosbox-x --version should show C_DYNREC 1.
# Falls back to normal core for 386 protected-mode paging.
core=dynamic_rec
# Real-mode: fixed 5000 cycles; protected-mode: up to 70% host CPU,
# capped at 50000 to enable late 486/Pentium-era DOS games on Kryo 468.
cycles=auto 5000 70% limit 50000
DBXCFG
    else
        log "DOSBox-X config already exists — skipping"
    fi
    unset _DBX_CFG

    # Verify (skip in dry-run — packages were not actually installed)
    if ! $DRY_RUN; then
        if command -v dosbox-x &>/dev/null; then
            _dosbox_ver="$(timeout 3 dosbox-x --version 2>/dev/null | head -1 || true)"
            log "dosbox-x: ${_dosbox_ver:-installed} ✓"
            unset _dosbox_ver
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
        if command -v innoextract &>/dev/null; then
            _innoextract_ver="$(timeout 3 innoextract --version 2>/dev/null | head -1 || true)"
            log "innoextract: ${_innoextract_ver:-installed} ✓"
            unset _innoextract_ver
        else
            warn "innoextract not found"
        fi
        if command -v retroarch &>/dev/null; then
            log "RetroArch: installed ✓"
        else
            warn "RetroArch not found"
        fi
    fi

    log "For advanced gaming (box64/Wine/GOG/cloud): see README.md § Gaming"

    # box64: x86_64 DynaRec emulator (binfmt blocked in unprivileged Crostini; invoke explicitly)
    if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y box64; then
        log "box64 installed ✓"
    else
        warn "box64 install failed"
    fi

    # qemu-user: TCG x86/i386 emulation (do NOT install qemu-user-binfmt — EPERM in unprivileged)
    install_pkgs_best_effort qemu-user || warn "qemu-user install failed"

    # Write ~/.box64rc with SC7180P-tuned defaults
    _BOX64_RC="${HOME}/.box64rc"
    if [[ ! -f "$_BOX64_RC" ]]; then
        write_file_private "$_BOX64_RC" <<'RCEOF'
# box64 config for Crostini SC7180P (Snapdragon 7c Gen 2) — managed by ry-crostini.sh
# Written once on first install; edit freely afterward.
# Reference: https://github.com/ptitSeb/box64/blob/main/docs/USAGE.md

[default]
# Suppress verbose output
BOX64_LOG=0
# CALL/RET optimisation — safe speedup on SC7180P
BOX64_DYNAREC_CALLRET=1
# Purge stale dynarec blocks — reclaims RAM on 4 GB device
BOX64_DYNAREC_PURGE=1
# DynaRec disk cache — saves generated native code for faster subsequent loads.
# 0=off, 1=generate+use, 2=use existing only (default). Requires box64 ≥ v0.3.8.
# Canonical name since v0.3.8; older builds use BOX64_DYNAREC_CACHE.
# Fresh install: no cache exists yet; change to 1 after first run to generate,
# then revert to 2 for faster startup without regeneration overhead.
BOX64_DYNACACHE=2
# Native ARM CPU flags — uses host NEON/etc for flag computation (v0.3.2+)
BOX64_DYNAREC_NATIVEFLAGS=1
# Larger forward gap for DynaRec blocks — default 128; 512 builds bigger
# blocks for better throughput (box64 CHANGELOG: "can get more than 30%")
BOX64_DYNAREC_FORWARD=512
# Map x86 PAUSE→ARM YIELD — better spinlock behavior, lower power on battery
BOX64_DYNAREC_PAUSE=1
# LSE atomics — Cortex-A76 supports natively; faster, smaller generated code.
# Rare programs with unaligned LOCK ops may SIGBUS; disable per-game if needed:
# [gamename] BOX64_DYNAREC_ALIGNED_ATOMICS=0
BOX64_DYNAREC_ALIGNED_ATOMICS=1
# Faster SMC handling — continue running dynablock that writes in its own page.
# Less safe but faster loading; benefits DOS-era code patterns. Requires ≥ v0.3.6.
BOX64_DYNAREC_DIRTY=1
# Limit CPUID-reported core count — prevents emulated programs from spawning
# threads targeting all 8 cores (including LITTLE); aligns with run-game affinity.
BOX64_MAXCPU=4
# BOX64_DYNAREC_SAFEFLAGS=0  # per-game only

[wine]
# 32-bit address space for Wine WoW64 mode
BOX64_MMAP32=1
# Strong memory model — required for Wine correctness on ARM64
BOX64_DYNAREC_STRONGMEM=1
# Larger dynarec blocks for Wine — improves throughput
BOX64_DYNAREC_BIGBLOCK=3
# Larger forward gap for Wine — bigger blocks for DLL-heavy code (default 512 in [default])
BOX64_DYNAREC_FORWARD=1024
RCEOF
        log "Wrote ${_BOX64_RC}"
    else
        log ".box64rc already exists — skipping"
    fi
    unset _BOX64_RC

    # run-x86: convenience wrapper — auto-detects ELF arch, prefers box64 for x86_64
    _RUN_X86="${HOME}/.local/bin/run-x86"
    if [[ ! -f "$_RUN_X86" ]]; then
        sed "s/@@VERSION@@/v${SCRIPT_VERSION}/" <<'WRAPPER' | write_file_exec "$_RUN_X86"
#!/usr/bin/env bash
# run-x86 — convenience wrapper for x86_64 emulation on ARM64 Crostini
# Prefers box64 (DynaRec JIT) when available; falls back to qemu-user (TCG).
# Usage: run-x86 ./program [args...]
# Managed by ry-crostini.sh — edit freely.

set -euo pipefail

case "${1:-}" in
    --help)    printf 'Usage: run-x86 <program> [args...]\nAuto-detects ELF arch; prefers box64 (x86_64), falls back to qemu.\n'; exit 0 ;;
    --version) printf 'run-x86 @@VERSION@@ from ry-crostini.sh\n'; exit 0 ;;
    --)        shift ;;
esac

if [[ $# -lt 1 ]]; then
    printf 'Usage: run-x86 <program> [args...]\n' >&2
    exit 2
fi

prog="$1"

if [[ ! -f "$prog" ]]; then
    printf 'run-x86: file not found: %s\n' "$prog" >&2
    exit 2
fi

# Detect ELF architecture via raw header bytes (od)
# ELF header: bytes 0-3=magic, byte 4=class, bytes 18-19=e_machine (LE)
# String offsets: magic[0:8]=7f454c46, magic[8:2]=class, magic[36:4]=machine
# Verified against QEMU binfmt magic values:
#   x86_64: class=02, machine=3e00
#   i386:   class=01, machine=0300
_detect_arch() {
    local magic
    magic="$(od -A n -t x1 -N 20 -- "$1" 2>/dev/null | tr -d ' \n')" || return 1
    [[ "${magic:0:8}" == "7f454c46" ]] || return 1
    local class="${magic:8:2}"
    local machine="${magic:36:4}"
    if [[ "$class" == "02" && "$machine" == "3e00" ]]; then
        echo "x86_64"; return 0
    elif [[ "$class" == "01" && "$machine" == "0300" ]]; then
        echo "i386"; return 0
    fi
    return 1
}

arch="$(_detect_arch "$prog" 2>/dev/null)" || arch=""

case "$arch" in
    x86_64)
        if command -v box64 &>/dev/null; then
            exec box64 "$@"
        elif command -v qemu-x86_64 &>/dev/null; then
            exec qemu-x86_64 "$@"
        fi
        ;;
    i386)
        if command -v qemu-i386 &>/dev/null; then
            exec qemu-i386 "$@"
        fi
        ;;
    "")
        printf 'run-x86: arch detection failed for %s — assuming x86_64\n' "$prog" >&2
        if command -v box64 &>/dev/null; then
            exec box64 "$@"
        elif command -v qemu-x86_64 &>/dev/null; then
            exec qemu-x86_64 "$@"
        fi
        ;;
esac

printf 'run-x86: no suitable emulator found for %s (arch=%s)\n' "$prog" "${arch:-unknown}" >&2
printf 'Install: sudo apt install qemu-user\n' >&2
exit 1
WRAPPER
    else
        log "run-x86 wrapper already exists — skipping"
    fi
    unset _RUN_X86

    # gog-extract: wrapper to extract GOG .exe (Inno Setup) and .sh (makeself) installers
    _GOG_EXTRACT="${HOME}/.local/bin/gog-extract"
    if [[ ! -f "$_GOG_EXTRACT" ]]; then
        sed "s/@@VERSION@@/v${SCRIPT_VERSION}/" <<'GOGWRAP' | write_file_exec "$_GOG_EXTRACT"
#!/usr/bin/env bash
# gog-extract — extract GOG game installers on ARM64 Linux without Wine
# Handles Windows .exe (via innoextract) and Linux .sh (via makeself --noexec)
# Usage: gog-extract <installer> [output-dir]
# Managed by ry-crostini.sh — edit freely.

set -euo pipefail

case "${1:-}" in
    --help)    printf 'Usage: gog-extract <installer> [output-dir]\nExtracts GOG Windows .exe or Linux .sh installers.\n'; exit 0 ;;
    --version) printf 'gog-extract @@VERSION@@ from ry-crostini.sh\n'; exit 0 ;;
    --)        shift ;;
esac

if [[ $# -lt 1 ]]; then
    printf 'Usage: gog-extract <installer> [output-dir]\n' >&2
    exit 2
fi

installer="$1"

if [[ ! -f "$installer" ]]; then
    printf 'gog-extract: file not found: %s\n' "$installer" >&2
    exit 2
fi

# Default output directory: installer basename without extension, in current dir
_base="$(basename -- "$installer")"
_base="${_base%.*}"
outdir="${2:-$_base}"

case "$installer" in
    *.exe|*.EXE)
        if ! command -v innoextract &>/dev/null; then
            printf 'gog-extract: innoextract not found — install with: sudo apt install innoextract\n' >&2
            exit 1
        fi
        printf 'Extracting GOG Windows installer: %s\n' "$installer"
        # --gog: handle multi-part .bin RAR archives (innoextract v1.9+ handles internally)
        # --exclude-temp: skip files deleted at end of install (temp extractors, etc.)
        innoextract --gog --exclude-temp -d "$outdir" -- "$installer"
        printf 'Extracted to: %s/\n' "$outdir"
        # Show game directory (typically under app/)
        if [[ -d "${outdir}/app" ]]; then
            printf 'Game files: %s/app/\n' "$outdir"
        fi
        ;;
    *.sh|*.SH)
        # Validate makeself archive structure — require ≥2 structural markers
        # (keyword-only checks are bypassable by hostile scripts embedding "makeself")
        _ms_score=0
        _ms_head="$(head -200 -- "$installer" 2>/dev/null)" || _ms_head=""
        [[ "$_ms_head" == *'MS_dd='* || "$_ms_head" == *'MS_dd_Progress='* ]] && ((_ms_score++)) || true
        [[ "$_ms_head" == *'label='* ]]     && ((_ms_score++)) || true
        [[ "$_ms_head" == *'filesizes='* ]] && ((_ms_score++)) || true
        [[ "$_ms_head" == *'TMPROOT='* ]]   && ((_ms_score++)) || true
        [[ "$_ms_head" == *'offset=`head'* ]] && ((_ms_score++)) || true
        if [[ "$_ms_score" -lt 2 ]]; then
            printf 'gog-extract: %s does not appear to be a makeself archive (GOG Linux installer)\n' "$installer" >&2
            printf 'Expected a GOG .sh installer (makeself archive). Aborting for safety.\n' >&2
            printf 'Matched %d/5 makeself structural markers (need ≥2).\n' "$_ms_score" >&2
            exit 1
        fi
        unset _ms_score _ms_head
        printf 'Extracting GOG Linux installer: %s\n' "$installer"
        mkdir -p -- "$outdir"
        # GOG Linux installers are makeself archives; invoke via bash to avoid modifying the original file's permissions
        bash "$installer" --noexec --target="$outdir"
        printf 'Extracted to: %s/\n' "$outdir"
        # GOG Linux .sh contents: data/noarch/game/ contains game files
        if [[ -d "${outdir}/data/noarch/game" ]]; then
            printf 'Game files: %s/data/noarch/game/\n' "$outdir"
        fi
        ;;
    *)
        printf 'gog-extract: unsupported file type: %s\n' "$installer" >&2
        printf 'Expected: .exe (Windows GOG installer) or .sh (Linux GOG installer)\n' >&2
        exit 2
        ;;
esac
GOGWRAP
    else
        log "gog-extract wrapper already exists — skipping"
    fi
    unset _GOG_EXTRACT

    # run-game: CPU affinity + priority launcher for gaming on big.LITTLE SoC
    _RUN_GAME="${HOME}/.local/bin/run-game"
    if [[ ! -f "$_RUN_GAME" ]]; then
        sed "s/@@VERSION@@/v${SCRIPT_VERSION}/" <<'RGWRAP' | write_file_exec "$_RUN_GAME"
#!/usr/bin/env bash
# run-game — launch a game on Cortex-A76 big cores with elevated priority
# SC7180P: cores 6-7 = Cortex-A76, cores 0-5 = Cortex-A55
# Usage: run-game <command> [args...]
# Managed by ry-crostini.sh — edit freely.

set -euo pipefail

case "${1:-}" in
    --help)    printf 'Usage: run-game <command> [args...]\nPins to big cores (auto-detected via /proc/cpuinfo), sets nice -5, ionice -c2 -n0.\n'; exit 0 ;;
    --version) printf 'run-game @@VERSION@@ from ry-crostini.sh\n'; exit 0 ;;
    --)        shift ;;
esac

if [[ $# -lt 1 ]]; then
    printf 'Usage: run-game <command> [args...]\n' >&2
    exit 2
fi

# Build command with optional affinity and priority
_cmd=("$@")
# Pin to big cores on SC7180P (Cortex-A76 = part 0x804, cores 6-7).
# Only applies when both conditions hold: heterogeneous parts detected AND
# Cortex-A76 (0x804) is present. On non-SC7180P SoCs, skips affinity entirely.
_big_cores=""
if [[ -d /sys/devices/system/cpu/cpu0 ]]; then
    _nparts="$(awk '/^CPU part/ {print $4}' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)"
    if [[ "${_nparts:-0}" -ge 2 ]] && grep -q '0x804' /proc/cpuinfo 2>/dev/null; then
        # Collect core indices whose part matches Cortex-A76 (0x804)
        _big_cores="$(awk '/^processor/{p=$3} /^CPU part.*0x804/{print p}' /proc/cpuinfo 2>/dev/null | paste -sd,)"
    fi
fi
if [[ -n "$_big_cores" ]]; then
    _cmd=(taskset -c "$_big_cores" "${_cmd[@]}")
fi
# nice -n -5 requires CAP_SYS_NICE; fall back silently if unprivileged
if nice -n -5 true 2>/dev/null; then
    _cmd=(nice -n -5 ionice -c2 -n0 "${_cmd[@]}")
fi
# Cap glibc malloc arenas — default 8×cores = 64 on SC7180P; wastes RAM
export MALLOC_ARENA_MAX=2
# Disable GL error checking — ~5-10% CPU savings; safe per-game, dangerous globally
# (virgl: invalid GL calls cross VM boundary and can hang host virglrenderer)
export MESA_NO_ERROR=1
# Enable GL threading for games — offloads command batching to separate thread.
# NOT safe globally (crashes Firefox on X11/EGL with virgl); safe per-game.
# Mesa canonical name is lowercase; override: MESA_GLTHREAD=false run-game <cmd>
export mesa_glthread="${MESA_GLTHREAD:-true}"
exec "${_cmd[@]}"
RGWRAP
    else
        log "run-game wrapper already exists — skipping"
    fi
    unset _RUN_GAME

    set_checkpoint 10
    log "Step 10 complete."
fi
# Steps 11-13: Verification — counters span all three steps for --from-step=12/13
_had_failures=0
_no_checks_ran=false
_verify_pass=0
_verify_fail=0
_verify_warn=0

# Inject install-time paths (profile.d not yet sourced in current shell)
[[ -d "${HOME}/.local/bin" && ":${PATH}:" != *":${HOME}/.local/bin:"* ]] && PATH="${HOME}/.local/bin:${PATH}"

if $DRY_RUN; then
    log "[DRY-RUN] Verification runs live (checks are read-only; earlyoom restarted if stopped)"
fi

# Step 11: Verification — tools and config files
if should_run_step 11; then
    step_banner 11 "Verification — tools and config files"

    logprintf '\n%bVerification results:%b\n\n' "$BOLD" "$RESET"

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
            if [[ "$GL_RENDERER" == *virgl* ]]; then
                logprintf '  Mesa driver:   %b✓%b virgl\n' "$GREEN" "$RESET"
                ((_verify_pass++)) || true
            elif [[ "$GL_RENDERER" == *zink* || "$GL_RENDERER" == *Zink* ]]; then
                logprintf '  Mesa driver:   %b⚠%b Zink detected — virgl override not active\n' "$YELLOW" "$RESET"
                ((_verify_warn++)) || true
            fi
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
        logprintf '  Also enable:   chrome://flags/#exo-pointer-lock (mouse capture in games)\n'
    fi
    logprintf '\n'

    # Display
    logprintf '%bDisplay / Wayland:%b\n' "$BOLD" "$RESET"
    if pgrep -x sommelier &>/dev/null; then
        logprintf '  Sommelier:     %b✓%b running\n' "$GREEN" "$RESET"
        ((_verify_pass++)) || true
    else
        logprintf '  Sommelier:     %b⚠%b not running — restart terminal to activate\n' "$YELLOW" "$RESET"
        ((_verify_warn++)) || true
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
        SND_DEV_COUNT="$(find /dev/snd -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)" || true
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
        unset _shared_arr SHARED_N d
    fi
    logprintf '\n'

    # Installed tools — ordered by installation step (3→4→5→6→8→10)
    logprintf '%bInstalled tools:%b\n' "$BOLD" "$RESET"

    # Resolve Debian-renamed commands before parallel dispatch
    _fd_cmd=fdfind;  command -v fd  &>/dev/null && _fd_cmd=fd
    _bat_cmd=batcat; command -v bat &>/dev/null && _bat_cmd=bat

    # Parallel tool checks — all version probes run concurrently (~48 tools)
    _parallel_check_tools \
        "vim|vim" "nano|nano" "curl|curl" "wget|wget" "less|less" \
        "jq|jq" "tmux|tmux" "screen|screen" "htop|htop" "ncdu|ncdu" \
        "strace|strace" "lsof|lsof" "rsync|rsync" "file|file" "tree|tree" \
        "dig|dig" "ssh|ssh" "zip|zip" "unzip|unzip" "7z|7z" \
        "rename|rename" "wl-clipboard|wl-copy" \
        "fzf|fzf" "ripgrep|rg" "fd|${_fd_cmd}" "bat|${_bat_cmd}" \
        "gcc|gcc" "g++|g++" "make|make" "cmake|cmake" "pkg-config|pkg-config" \
        "glxinfo|glxinfo" "vulkaninfo|vulkaninfo" \
        "pactl|pactl" "pavucontrol|pavucontrol" \
        "xterm|xterm" "gnome-disks|gnome-disks" \
        "dosbox-x|dosbox-x" "scummvm|scummvm" "retroarch|retroarch" "innoextract|innoextract"
    unset _fd_cmd _bat_cmd

    # unrar: non-free; unar is a functional equivalent — handle separately
    if command -v unrar &>/dev/null; then
        check_tool "unrar"   unrar
    elif command -v unar &>/dev/null; then
        logprintf '  %-14s %b✓%b  not installed — unar present (adequate for GOG/RAR4+RAR5)\n' \
            "unrar" "$GREEN" "$RESET"
        ((_verify_pass++)) || true
    else
        logprintf '  %-14s %b✗%b  not found\n' "unrar" "$RED" "$RESET"
        ((_verify_fail++)) || true
    fi

    # Remaining tools (parallel — fast commands; unrar handled conditionally above)
    _parallel_check_tools \
        "unar|unar" "box64|box64" "qemu-x86_64|qemu-x86_64" \
        "run-x86|run-x86" "gog-extract|gog-extract" "run-game|run-game" \
        "earlyoom|earlyoom"
    logprintf '\n'

    # Config files
    logprintf '%bConfig files written:%b\n' "$BOLD" "$RESET"

    check_config "/etc/apt/apt.conf.d/90parallel"                "Apt download tuning"
    check_config "/etc/systemd/system/ry-crostini-cros-pin.service" "cros.list cleanup service"
    check_config "${HOME}/.config/environment.d/gpu.conf"       "GPU env"
    check_config "${HOME}/.config/environment.d/sommelier.conf"  "Sommelier scaling + keys"
    check_config "${HOME}/.config/environment.d/qt.conf"         "Qt scaling/theming"
    # Step 7: Qt GTK platform themes (at least one should be present)
    if dpkg -s qt5-gtk-platformtheme &>/dev/null || dpkg -s adwaita-qt &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "Qt5 GTK platform theme"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "Qt5 GTK platform theme not found"
        ((_verify_warn++)) || true
    fi
    if dpkg -s qt6-gtk-platformtheme &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "Qt6 GTK platform theme"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "Qt6 GTK platform theme not found"
        ((_verify_warn++)) || true
    fi
    check_config "${HOME}/.config/gtk-3.0/settings.ini"          "GTK 3 theme + fonts"
    check_config "${HOME}/.config/gtk-4.0/settings.ini"          "GTK 4 theme + fonts"
    check_config "${HOME}/.gtkrc-2.0"                            "GTK 2 theme (legacy)"
    check_config "${HOME}/.Xresources"                           "Xft DPI + rendering"
    check_config "${HOME}/.config/fontconfig/fonts.conf"         "Fontconfig OLED AA"
    check_config "${HOME}/.icons/default/index.theme"            "Cursor theme"
    check_config "/etc/profile.d/ry-crostini-env.sh"                "Shell env + PATH"
    check_config "/etc/systemd/system/tmp.mount.d/override.conf" "/tmp tmpfs 512M cap"
    check_config "${HOME}/.config/pipewire/pipewire.conf.d/10-ry-crostini-gaming.conf"        "PipeWire gaming quantum"
    check_config "${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-ry-crostini-gaming.conf"   "PipeWire-Pulse gaming"
    check_config "${HOME}/.config/wireplumber/wireplumber.conf.d/51-crostini-alsa.conf"        "WirePlumber ALSA tuning"
    check_config "/etc/systemd/journald.conf.d/volatile.conf"                                  "Journald volatile storage"
    check_config "${HOME}/.config/retroarch/retroarch.cfg"    "RetroArch config"
    check_config "${HOME}/.config/scummvm/scummvm.ini"                                       "ScummVM config"
    check_config "${HOME}/.box64rc"                                                           "box64 SC7180P config"
    check_config "${HOME}/.config/dosbox-x/dosbox-x.conf"                                    "DOSBox-X ARM64 config"
    # PipeWire audio chain verification
    if systemctl --user is-active pipewire-pulse.socket &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "PipeWire-pulse active"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "PipeWire-pulse not running — restart terminal"
        ((_verify_warn++)) || true
    fi
    # earlyoom OOM killer
    check_config "/etc/default/earlyoom"                                                           "earlyoom OOM config"
    # earlyoom may have been killed during heavy apt operations; restart if needed
    if ! $DRY_RUN && ! systemctl is-active earlyoom.service &>/dev/null; then
        sudo systemctl start earlyoom.service 2>/dev/null || true
    fi
    if systemctl is-active earlyoom.service &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "earlyoom OOM killer active"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "earlyoom not running"
        ((_verify_warn++)) || true
    fi
    # apt-daily-upgrade timer (unattended installs disabled; apt-daily list refresh kept)
    if ! systemctl is-enabled apt-daily-upgrade.timer &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "apt-daily-upgrade.timer disabled"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "apt-daily-upgrade.timer still enabled"
        ((_verify_warn++)) || true
    fi
    # RetroArch video_threaded sanity check
    if [[ -f "${HOME}/.config/retroarch/retroarch.cfg" ]]; then
        if grep -q 'video_threaded *= *"false"' "${HOME}/.config/retroarch/retroarch.cfg"; then
            logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "RetroArch video_threaded=false"
            ((_verify_pass++)) || true
        elif grep -q 'video_threaded *= *"true"' "${HOME}/.config/retroarch/retroarch.cfg"; then
            logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "RetroArch video_threaded still true — update config"
            ((_verify_warn++)) || true
        fi
    fi
    logprintf '\n'

    set_checkpoint 11
    log "Step 11 complete."
fi
# Step 12: Verification — scripts and assets
if should_run_step 12; then
    step_banner 12 "Verification — scripts and assets"

    logprintf '%bScripts and assets:%b\n' "$BOLD" "$RESET"

    check_config "/usr/share/sounds/sf2/FluidR3_GM.sf2"                                     "FluidSynth GM soundfont"
    check_config "${HOME}/.local/bin/run-x86"                                                 "x86 emulation wrapper"
    check_config "${HOME}/.local/bin/gog-extract"                                              "GOG installer extractor"
    check_config "${HOME}/.local/bin/run-game"                                                "CPU affinity game launcher"
    logprintf '\n'

    set_checkpoint 12
    log "Step 12 complete."
fi
# Step 13: Verification summary
if should_run_step 13; then
    step_banner 13 "Verification summary"

    logprintf '%bQuick-test commands:%b\n' "$BOLD" "$RESET"
    logprintf '  GPU/Audio:   glxgears / vulkaninfo --summary / pactl info\n'
    logprintf '  Display:     xdpyinfo | grep resolution / fc-match sans-serif / fc-match monospace\n'
    logprintf '  Gaming:      glxinfo | grep renderer / printenv MESA_NO_ERROR / pw-top / dosbox-x --version\n'
    logprintf '\n'

    # Reminders
    logprintf '%bReminders:%b\n' "$YELLOW" "$RESET"
    logprintf '  • Manual .deb downloads: always get the arm64 variant\n'
    logprintf '  • If GPU not active: reboot entire Chromebook (not just container)\n'
    logprintf '  • Gaming (box64/Wine/GOG/cloud): see README.md § Gaming\n'
    logprintf '\n'

    logprintf '%bLog file:%b %s\n' "$BOLD" "$RESET" "$LOG_FILE"

    # Verification summary
    logprintf '\n%bVerification totals:%b  ' "$BOLD" "$RESET"
    logprintf '%b%s passed%b' "$GREEN" "$_verify_pass" "$RESET"
    [[ "$_verify_warn" -gt 0 ]] && logprintf '  %b%s warnings%b' "$YELLOW" "$_verify_warn" "$RESET"
    [[ "$_verify_fail" -gt 0 ]] && logprintf '  %b%s failed%b' "$RED" "$_verify_fail" "$RESET"
    logprintf '\n'

    # Print result banner — only claim success after verification passes
    _had_failures="$_verify_fail"
    if [[ $((_verify_pass + _verify_fail + _verify_warn)) -eq 0 ]]; then
        logprintf '\n%bNO CHECKS RAN%b — use --verify for full verification\n' "$YELLOW" "$RESET"
    elif [[ "$_had_failures" -eq 0 ]]; then
        logprintf '\n%bRY-CROSTINI COMPLETE%b\n' "$GREEN" "$RESET"
    else
        logprintf '\n%bRY-CROSTINI FINISHED WITH %s FAILURE(S)%b\n' "$RED" "$_had_failures" "$RESET"
    fi

    if [[ $((_verify_pass + _verify_fail + _verify_warn)) -eq 0 ]]; then
        # No checks ran (e.g. --from-step=13) — do not advance checkpoint
        _no_checks_ran=true
        log "No verification checks were executed — use --verify to validate."
    elif [[ "$_had_failures" -eq 0 ]]; then
        # All checks passed — mark step 13 complete and remove checkpoint
        set_checkpoint 13
        if $DRY_RUN; then
            log "[DRY-RUN] would remove checkpoint file"
        else
            rm -f -- "$STEP_FILE"
            log "Checkpoint file removed. Setup fully complete."
        fi
    else
        # Verification failed — do not advance checkpoint; --verify re-runs steps 11-13
        log "Verification failures detected. Fix issues above, then run: bash ry-crostini.sh --verify"
    fi

    # Clean up verification variables
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

    # Live-reload environment.d vars and restart sommelier so changes apply without container restart
    if ! $DRY_RUN; then
        # Import updated environment.d variables into the systemd user session
        if systemctl --user import-environment 2>/dev/null; then
            log "Imported environment.d variables into user session"
        fi
        # Restart sommelier (Wayland + X11 bridge) to pick up new env vars
        if systemctl --user restart sommelier@0.service sommelier-x@0.service 2>/dev/null; then
            # Brief settle — sommelier needs ~1 s to re-establish the display socket
            sleep 1
            if pgrep -x sommelier &>/dev/null; then
                log "Sommelier restarted — environment changes are live"
            else
                logprintf '\n%bSommelier restart failed — shut down Linux (Settings → Developers) and reopen Terminal.%b\n\n' "$BOLD" "$RESET"
            fi
        else
            logprintf '\n%bRestart the Terminal app to apply all environment changes.%b\n\n' "$BOLD" "$RESET"
        fi
    else
        logprintf '\n%b[DRY-RUN] Would restart sommelier to apply environment changes.%b\n\n' "$BOLD" "$RESET"
    fi
    log "Step 13 complete."
fi

if $_no_checks_ran; then
    exit 2
fi
if [[ "$_had_failures" -gt 0 ]]; then
    exit 1
fi
exit 0
