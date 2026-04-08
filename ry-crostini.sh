#!/usr/bin/env bash
# ry-crostini.sh — Crostini post-install bootstrap for Lenovo Duet 5 (82QS0001US)
# Version: 8.1.8
# Date:    2026-04-08
# Arch:    aarch64 / arm64 (Qualcomm Snapdragon 7c Gen 2 — SC7180P)
# Target:  Debian Bookworm container under ChromeOS Crostini (primary target).
#          Trixie upgrade is opt-in via --upgrade-trixie. Bookworm path uses
#          bookworm-backports for pipewire 1.4 / wireplumber 0.5 and falls back
#          to vanilla dosbox + qemu-user (no dosbox-x, no box64).
# Usage:   bash ry-crostini.sh [--interactive] [--upgrade-trixie] [--from-step=N] [--verify] [--reset [--force]] [--help] [--version] [--]
# Fully unattended by default — use --interactive for ChromeOS toggle prompts.
# NOTE: Script uses sudo internally (~70 calls). A background keepalive renews credentials every 60 s. Run `sudo true` first to cache the initial credential.
# WARNING: Steam is x86-only; box64/box86 community translation exists but is unusable on 4 GB RAM / virgl.
# NOTE: Default flow stays on bookworm and pulls pipewire/wireplumber from bookworm-backports. Pass --upgrade-trixie to perform the legacy bookworm->trixie codename rewrite (requires container restart mid-script).
# NOTE: Trixie mounts /tmp as tmpfs (RAM-backed); bookworm /tmp is disk-backed. Step 2d gates the tmpfs cap accordingly.

set -euo pipefail
# Propagate ERR trap to functions/subshells; inherit errexit in $(command substitution)
set -E
shopt -s inherit_errexit
# Standard umask — all write_file variants set explicit permissions (644/600/700)
umask 022

# Constants
readonly SCRIPT_NAME="ry-crostini.sh"
readonly SCRIPT_VERSION="8.1.8"
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

# Log file creation deferred until after --help/--version short-circuit (see arg parse)

UNATTENDED=true
# set by --upgrade-trixie to opt INTO codename rewrite
UPGRADE_TRIXIE=false
# set true at global init when codename=bookworm
IS_BOOKWORM=false
_DEFERRED_CHECKPOINT=""
_DEFERRED_CHECKPOINT_MSG=""
_CHECKPOINT_OVERRIDE=""
_LOCK_ACQUIRED=false
_received_signal=""
_SUDO_KEEPALIVE_PID=""
_PARALLEL_TMPDIR=""
_SUDO_TMPFILE=""

# Signal handler — stores signal name, triggers EXIT trap via exit (POSIX 128+N)
# shellcheck disable=SC2317,SC2329
_handle_signal() {
    _received_signal="$1"
    case "$1" in
        HUP)  exit 129 ;;
        INT)  exit 130 ;;
        QUIT) exit 131 ;;
        PIPE) exit 141 ;;
        TERM) exit 143 ;;
        *)    exit 1   ;;
    esac
}

# Cleanup trap
# shellcheck disable=SC2317,SC2329
cleanup() {
    local rc=$?
    # Prevent recursive cleanup from nested signals
    trap - EXIT INT TERM HUP PIPE QUIT WINCH
    # Disable set -e inside cleanup to guarantee full execution. Safe: cleanup is the final code path before exit; no restore needed.
    set +e
    # Restore terminal scroll region before any output
    _progress_cleanup
    # Strip ANSI escape codes from log file (single-pass; replaces racy per-line sed)
    _strip_log_ansi
    # Stop sudo credential keepalive (disowned — kill by raw PID; wait is impossible because the process is no longer in this shell's job table after disown)
    if [[ -n "${_SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$_SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
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
    # Re-raise caught signal for correct 128+N exit code to parent. Allowlist defends against $_received_signal being clobbered.
    if [[ -n "${_received_signal:-}" ]]; then
        case "$_received_signal" in
            INT|TERM|HUP|PIPE|QUIT) kill -"$_received_signal" "$$" ;;
            *) : ;;
        esac
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

# _read_os_release: print a single /etc/os-release field, with fallback. Usage: _read_os_release FIELD [FALLBACK] Sources /etc/os-release in a subshell to avoid polluting caller scope.
_read_os_release() {
    local field="$1" fallback="${2:-}"
    [[ -f /etc/os-release ]] || { printf '%s' "$fallback"; return 0; }
    (
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null || true
        printf '%s' "${!field:-$fallback}"
    )
}

# _has_capture_dev: true if /dev/snd has any ALSA capture node (pcmC*D*c). Covers card indices ≥2 that the prior C0/C1 literal check missed.
_has_capture_dev() {
    [[ -d /dev/snd ]] || return 1
    find /dev/snd -maxdepth 1 -name 'pcmC*D*c' 2>/dev/null | grep -q .
}

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
    # mktemp on Linux already creates with 0600 — no chmod needed
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
    # In-memory override for --from-step/--verify
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

# _tee_log: tee stdin to terminal + log file. ANSI stripped at exit by _strip_log_ansi. Filters known-benign upstream noise: dpkg usrmerge residue, udisks2 udevadm trigger EPERM, dpkg t64 ABI transition libcrypto.so.3 lookup. Patterns are anchored and will not match script output.
_tee_log() {
    grep --line-buffered -vE \
        -e "^dpkg: warning: unable to delete old directory '/[^']+': Directory not empty[[:space:]]*\$" \
        -e "^[a-z0-9]+: Failed to write 'change' to '/sys/.+/uevent': Permission denied[[:space:]]*\$" \
        -e "^systemctl: error while loading shared libraries: libcrypto\.so\.3: cannot open shared object file: No such file or directory[[:space:]]*\$" \
        | tee -a "$LOG_FILE"
}

# run: execute "$@" directly. stderr merged into stdout (2>&1) for log capture.
run() {
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

# _write_file_impl: atomic write stdin to path with given mode
_write_file_impl() {
    local dest="$1" mode="$2"
    mkdir -p "$(dirname "$dest")" || die "Cannot create parent dir for $dest"
    local tmp
    tmp="$(mktemp "$(dirname "$dest")/.tmp_XXXXXXXX")" || die "Cannot create tmpfile for $dest"
    # Refuse to write through a symlink (TOCTOU defence)
    [[ -L "$tmp" ]] && { rm -f -- "$tmp"; die "Refusing to write $dest: tmpfile is a symlink"; }
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
# write_file_exec: atomic write stdin to path, mode 700. For user scripts/wrappers.
write_file_exec() { _write_file_impl "$1" 700; }

# write_file_sudo: atomic write via sudo. Output mode 644.
write_file_sudo() {
    local dest="$1"
    sudo mkdir -p "$(dirname "$dest")" || die "Cannot create parent dir for $dest"
    local tmp
    tmp="$(sudo mktemp "$(dirname "$dest")/.tmp_XXXXXXXX")" || die "Cannot create tmpfile for $dest"
    # Track for cleanup trap — signal between mktemp and mv would leak this file
    _SUDO_TMPFILE="$tmp"
    # Refuse to write through a symlink (TOCTOU defence — parity with ry-install)
    if ! sudo test ! -L "$tmp"; then
        sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""
        die "Refusing to write $dest: tmpfile is a symlink"
    fi
    sudo tee "$tmp" > /dev/null || { sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""; die "Cannot write $dest"; }
    sudo chmod 644 "$tmp" || { sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""; die "Cannot chmod tmpfile for $dest"; }
    sudo mv -- "$tmp" "$dest" || { sudo rm -f -- "$tmp"; _SUDO_TMPFILE=""; die "Cannot move $dest into place"; }
    _SUDO_TMPFILE=""
    log "Wrote $dest (sudo)"
}

# install_pkgs_best_effort: batch install, fallback to per-package. Returns 1 if any failed.
install_pkgs_best_effort() {
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
    [dosbox]=""
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
            ver="$(timeout 5 "$cmd" $flag 2>/dev/null | head -1)" || true
            # Some tools (e.g. 7z i on older p7zip) emit a blank first line before the version banner.
            if [[ -z "$ver" ]]; then
                # shellcheck disable=SC2086
                ver="$(timeout 5 "$cmd" $flag 2>/dev/null | grep -m1 .)" || true
            fi
            if [[ -z "$ver" ]]; then
                # Capture stderr-only (no pipe — avoids SIGPIPE on large output)
                local _raw
                # shellcheck disable=SC2086
                _raw="$(timeout 5 "$cmd" $flag 2>&1 1>/dev/null)" || true
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
            # Suppress LOG_FILE writes inside subshell — replay handles logging. Note: this assignment is subshell-local (SC2030/2031); parent's LOG_FILE binding is unaffected, so the "clobber" is purely scoped.
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
                # shellcheck disable=SC2031  # main-shell scope; subshell taint at line 571 is contained
                ((_verify_pass += _pct_p)) || true
                # shellcheck disable=SC2031
                ((_verify_fail += _pct_fl)) || true
                # shellcheck disable=SC2031
                ((_verify_warn += _pct_w)) || true
            else
                printf '%s\n' "$_pct_line"
                # shellcheck disable=SC2031  # LOG_FILE is main-shell here
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
    --interactive  Prompt for ChromeOS toggles (default: unattended)
    --upgrade-trixie  Opt INTO Debian Trixie codename upgrade in step 2.
                      Default behavior is to stay on the current codename
                      (bookworm). Trixie upgrade requires a container restart
                      mid-script.
    --from-step=N  Start (or restart) from step N (1-13; N=11 is same as --verify)
    --verify       Run only steps 11-13 (verification and summary)
    --help         Show this help message
    --version      Show version
    --reset        Clear checkpoint and start from step 1 (prompts; add --force to skip)
    --force        With --reset: skip confirmation (required when stdin is not a tty)
    --             Stop processing options (remaining args ignored)

STEPS PERFORMED:
     1  Preflight + ChromeOS integration (arch, bash ≥5.0, Crostini,
        Debian version, disk, GPU, network, root, sommelier, mic, USB,
        folders, ports, disk-resize; --interactive)
     2  System update (apt tuning, man-db trigger disable, bookworm-
        backports enable; optional bookworm->trixie upgrade with
        --upgrade-trixie, cros pkg hold, deb822 migration, /tmp tmpfs
        cap, cros-pin service)
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

# Pre-scan argv for --help / --version before any LOG_FILE creation so they work in read-only $HOME and never leave a stray log file behind. Also catches them ahead of die() calls in the full arg-parse loop (which would create the log file at default umask via err()'s >> redirection).
for _arg in "$@"; do
    case "$_arg" in
        --help)    usage ;;
        --version) echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
    esac
done
unset _arg

# Create log file with restrictive permissions (deferred past --help/--version)
# shellcheck disable=SC2031  # LOG_FILE is main-shell here; taint from the legitimate subshell at line 571
if ! touch "$LOG_FILE" || ! chmod 600 "$LOG_FILE"; then
    printf 'FATAL: cannot create log file %s\n' "$LOG_FILE" >&2
    exit 1
fi

# Argument parsing
# shellcheck disable=SC2031  # LOG_FILE references in this loop are main-shell, not subshell
for arg in "$@"; do
    case "$arg" in
        --interactive) UNATTENDED=false ;;
        --upgrade-trixie) UPGRADE_TRIXIE=true ;;
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
        # already handled by pre-scan above
        --help|--version) ;;
        --reset)
            # Detect --force anywhere in argv (order-independent)
            _reset_force=false
            for _a in "$@"; do
                [[ "$_a" == "--force" ]] && { _reset_force=true; break; }
            done
            unset _a
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
            # Confirm before destroying checkpoint + log unless --force or non-interactive without tty
            if ! $_reset_force; then
                if [[ -t 0 ]]; then
                    printf '%s\n' "About to delete:"
                    [[ -f "$STEP_FILE" ]] && printf '  %s\n' "$STEP_FILE"
                    [[ -f "$LOG_FILE"  ]] && printf '  %s\n' "$LOG_FILE"
                    printf 'Proceed? [y/N] '
                    read -r _ans
                    [[ "$_ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
                    unset _ans
                else
                    die "--reset is destructive; pass --force to confirm in non-interactive mode"
                fi
            fi
            unset _reset_force
            rm -f -- "$STEP_FILE"; rm -f -- "$LOG_FILE" 2>/dev/null; echo "Checkpoint and lock cleared."; exit 0
            ;;
        --force)
            # Only meaningful with --reset; warn if passed standalone so typos like `--forced` → `--force` don't silently do nothing.
            _has_reset=false
            for _a in "$@"; do [[ "$_a" == "--reset" ]] && { _has_reset=true; break; }; done
            unset _a
            $_has_reset || warn "--force has no effect without --reset; ignoring"
            unset _has_reset
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
# Mark ownership immediately after successful mkdir — closes the window where a signal between mkdir and PID-file write would orphan the lock dir. cleanup() will now remove it on any failure path below.
_LOCK_ACQUIRED=true
_pid_tmp="$(mktemp "$LOCK_FILE/.pid_XXXXXXXX")" \
    || die "Cannot create PID tmpfile"
printf '%s\n' "$$" > "$_pid_tmp"
mv -- "$_pid_tmp" "$LOCK_FILE/pid" \
    || { rm -f -- "$_pid_tmp"; die "Cannot write PID file"; }
unset _pid_tmp

# Apply deferred checkpoint (must be inside lock to avoid race with concurrent instances)
if [[ -n "$_DEFERRED_CHECKPOINT" ]]; then
    # In-memory override ensures should_run_step works without needing to read STEP_FILE
    _CHECKPOINT_OVERRIDE="$_DEFERRED_CHECKPOINT"
    set_checkpoint "$_DEFERRED_CHECKPOINT" || die "Cannot write checkpoint file ${STEP_FILE} — is \$HOME writable?"
    log "$_DEFERRED_CHECKPOINT_MSG"
fi
unset _DEFERRED_CHECKPOINT _DEFERRED_CHECKPOINT_MSG

# Global IS_BOOKWORM detection — runs every invocation (resume, --verify, --from-step). Bookworm is the primary target; trixie is opt-in via --upgrade-trixie.
_global_codename="$(_read_os_release VERSION_CODENAME)"
if [[ "$_global_codename" == "bookworm" ]] && ! $UPGRADE_TRIXIE; then
    IS_BOOKWORM=true
    log "Detected: Debian bookworm (primary target)"
elif [[ "$_global_codename" == "bookworm" ]] && $UPGRADE_TRIXIE; then
    log "Detected: Debian bookworm; --upgrade-trixie set, step 2 will rewrite sources -> trixie and exit"
elif [[ "$_global_codename" == "trixie" ]]; then
    log "Detected: Debian trixie (secondary target)"
fi
unset _global_codename

# Note: DEBIAN_FRONTEND is re-applied per-callsite as `sudo DEBIAN_FRONTEND=...` because sudo's env_reset strips it. A global export here would be redundant.

# Sudo credential keepalive — renew every 60 s; killed in cleanup(). Aborts loudly only after 15 consecutive failures (~15 min) so the main loop doesn't silently stall on apt-get sudo timeouts after credential expiry, while still tolerating the transient `sudo -n -v` failures that happen mid-Trixie-upgrade when sudo/libpam-* are themselves being replaced by dpkg. Failures while the dpkg frontend lock is held do not count — the foreground apt already has its credentials and the keepalive's job is moot until dpkg releases the lock.
(
    _ka_fails=0
    while true; do
        if sudo -n -v 2>/dev/null; then
            _ka_fails=0
        elif command -v fuser >/dev/null 2>&1 \
            && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            # dpkg frontend lock held — apt is running and may be replacing sudo/PAM right now. Don't count this tick.
            :
        else
            _ka_fails=$((_ka_fails + 1))
            if (( _ka_fails >= 15 )); then
                printf '\n[FATAL] sudo keepalive failed %d times (~15 min) — credentials expired or revoked. Aborting.\n' \
                    "$_ka_fails" >&2
                kill -TERM "$$" 2>/dev/null
                exit 1
            fi
        fi
        sleep 60
    done
) &
_SUDO_KEEPALIVE_PID=$!
disown "$_SUDO_KEEPALIVE_PID"

# Initialize progress bar (requires terminal, checkpoint, and color globals)
_progress_init

# Rotate old log files — keep last 7 days. Second find sweeps orphaned _strip_log_ansi tmpfiles (.log.strip_XXXXXXXX) that the main glob does not match — these only exist if a prior run was killed mid-strip between mktemp and the success/failure cleanup branches.
find "$HOME" -maxdepth 1 -name 'ry-crostini-*.log' -mtime +7 -delete 2>/dev/null || true
find "$HOME" -maxdepth 1 -name 'ry-crostini-*.log.strip_*' -mtime +1 -delete 2>/dev/null || true

# _gpu_conf_content: emit gpu.conf heredoc. Called by step 5 (fresh-write and upgrade-path).
_gpu_conf_content() {
    cat <<'EOF'
# Crostini GPU acceleration environment — managed by ry-crostini.sh
# ry-crostini:@@VERSION@@
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
# ry-crostini:@@VERSION@@
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
# ry-crostini:@@VERSION@@
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
        die "Expected architecture ${EXPECTED_ARCH}, got ${CURRENT_ARCH}. This script is for the Duet 5 (ARM64) only."
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
        _os_pretty="$(_read_os_release PRETTY_NAME unknown)"
        _os_codename="$(_read_os_release VERSION_CODENAME)"
        if [[ -z "$_os_codename" ]]; then
            die "VERSION_CODENAME missing from /etc/os-release — aborting (step 2 cannot proceed)"
        fi
        if [[ ! "$_os_codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
            die "VERSION_CODENAME '${_os_codename}' contains unexpected characters — aborting"
        fi
        log "Container OS: ${_os_pretty} (${_os_codename}) ✓"
        unset _os_pretty
    else
        die "/etc/os-release missing — cannot determine Debian release"
    fi

    # 1e. Disk space check (need at least 2 GB free) — cached for reuse in 1o
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

    # 1g. Network connectivity (uses detected codename for repo URL) Worst-case budget: 3 attempts × max-time 5s + 2 × retry-delay 1s ≈ 17s
    if curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 3 --max-time 5 --retry 2 --retry-delay 1 "https://deb.debian.org/debian/dists/${_os_codename}/Release.gpg" -o /dev/null 2>/dev/null; then
        log "Network connectivity: ✓"
    else
        warn "Cannot reach deb.debian.org. Some steps may fail without network."
    fi

    # 1h. Not running as root
    if [[ "$EUID" -eq 0 ]]; then
        die "Do not run this script as root. Run as your normal user (sudo is used internally where needed)."
    fi
    log "Running as user: $(whoami) ✓"

    # 1i. Sommelier (Wayland bridge) — needed for all GUI apps
    if pgrep -x sommelier &>/dev/null; then
        log "Sommelier (Wayland bridge): running ✓"
    else
        log "Sommelier not yet active — will start on terminal restart ✓"
    fi

    unset CURRENT_ARCH AVAIL_KB _os_codename

    # 1j. GPU acceleration + pointer lock (ChromeOS integration)
    if [[ -e /dev/dri/renderD128 ]]; then
        log "GPU acceleration: ALREADY ACTIVE ✓"
        log "Pointer lock: verify chrome://flags/#exo-pointer-lock is Enabled (required for mouse capture in games)"
    else
        log "GPU acceleration not detected."
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
    fi

    # 1k. Microphone access
    if _has_capture_dev; then
        log "Microphone capture device: detected ✓"
    else
        log "Microphone not detected."
        if ! $UNATTENDED; then
            _prompt '%b  → Toggle "Allow Linux to access your microphone" → On%b\n\n' "$YELLOW" "$RESET"
            open_chromeos_url "chrome://os-settings/crostini"
            sleep 2
            _prompt '%bPress Enter after enabling microphone (or to continue)...%b' "$YELLOW" "$RESET"
            read -r -t 300 _ </dev/tty || true
        fi
        if _has_capture_dev; then
            log "Microphone now available ✓"
        else
            warn "Microphone still not detected. May need container restart."
        fi
    fi

    # 1l. USB device passthrough
    if ! $UNATTENDED; then
        log "Opening USB device management..."
        _prompt '%b  → Toggle on any USB devices you need (drives, Arduino, etc.)%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/usbPreferences"
        sleep 2
        _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r -t 300 _ </dev/tty || true
    fi

    # 1m. Shared folders
    if [[ -d /mnt/chromeos ]]; then
        SHARED_COUNT="$(find /mnt/chromeos -maxdepth 2 -mindepth 2 -type d -printf '.' 2>/dev/null | wc -c)" || true
        if [[ "$SHARED_COUNT" -gt 0 ]]; then
            log "Shared ChromeOS folders: ${SHARED_COUNT} detected ✓"
        else
            log "No shared folders."
            if ! $UNATTENDED; then
                _prompt '%b  → Click "Share folder" to make ChromeOS folders visible at /mnt/chromeos/%b\n\n' "$YELLOW" "$RESET"
                open_chromeos_url "chrome://os-settings/crostini/sharedPaths"
                sleep 2
                _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
                read -r -t 300 _ </dev/tty || true
            fi
        fi
        unset SHARED_COUNT
    fi

    # 1n. Port forwarding
    if ! $UNATTENDED; then
        log "Opening port forwarding settings..."
        _prompt '%b  → Add any dev server ports (3000, 5000, 8080, etc.)%b\n' "$YELLOW" "$RESET"
        _prompt '%b  → Crostini also auto-detects listening ports in most cases.%b\n\n' "$YELLOW" "$RESET"
        open_chromeos_url "chrome://os-settings/crostini/portForwarding"
        sleep 2
        _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
        read -r -t 300 _ </dev/tty || true
    fi

    # 1o. Disk size advisory (reuses cached AVAIL_MB from 1e)
    AVAIL_MB_NOW="$AVAIL_MB"
    if [[ "$AVAIL_MB_NOW" -lt 10240 ]]; then
        log "Disk under 10 GB free."
        if ! $UNATTENDED; then
            _prompt '%b  → Consider increasing Linux disk allocation (20-30 GB recommended).%b\n\n' "$YELLOW" "$RESET"
            open_chromeos_url "chrome://os-settings/crostini"
            sleep 2
            _prompt '%bPress Enter to continue...%b' "$YELLOW" "$RESET"
            read -r -t 300 _ </dev/tty || true
        fi
    else
        log "Disk space: ${AVAIL_MB_NOW} MB free — adequate"
    fi

    unset AVAIL_MB AVAIL_MB_NOW
    set_checkpoint 1
    log "Step 1 complete."
fi
# Step 2: System update
if should_run_step 2; then
    step_banner 2 "System update (apt tuning, man-db trigger disable, optional Trixie upgrade with --upgrade-trixie, bookworm-backports enable, cros pkg hold, deb822 migration, /tmp tmpfs cap, cros-pin service)"

    # APT tuning: retries + skip translations + per-scheme connection queue
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
        log "APT tuning config already exists"
    fi
    unset APT_PARALLEL

    # Disable man-db auto-update trigger (30-60 s on ARM64 per apt install)
    if command -v debconf-communicate &>/dev/null; then
        if echo "set man-db/auto-update false" | sudo debconf-communicate &>/dev/null; then
            log "man-db auto-update disabled (run 'sudo mandb' manually when needed)"
        else
            warn "man-db auto-update disable failed — non-fatal"
        fi
    fi

    # 2a. Bookworm-primary path: stay on current codename unless --upgrade-trixie
    _did_trixie_rewrite=false
    _cur_codename="$(_read_os_release VERSION_CODENAME)"
    # Empty check: step 1 normally dies on empty VERSION_CODENAME, but --from-step=2 skips step 1 entirely. Re-validate here so step 2 cannot fall through with an empty codename (previously: silent "Staying on unknown" + missed backports-enable).
    if [[ -z "$_cur_codename" ]]; then
        die "VERSION_CODENAME missing from /etc/os-release — cannot proceed with step 2"
    fi
    if [[ ! "$_cur_codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
        die "VERSION_CODENAME '${_cur_codename}' contains unexpected characters — aborting"
    fi
    if ! $UPGRADE_TRIXIE; then
        log "Staying on ${_cur_codename:-unknown}; --upgrade-trixie not set, skipping codename rewrite"
        if [[ "$_cur_codename" == "bookworm" ]]; then
            IS_BOOKWORM=true
            log "Enabling bookworm-backports for pipewire 1.4 / wireplumber 0.5"
            _BPO_LIST="/etc/apt/sources.list.d/bookworm-backports.list"
            if [[ ! -f "$_BPO_LIST" ]] && ! grep -rq "bookworm-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
                printf 'deb http://deb.debian.org/debian bookworm-backports main\n' \
                    | write_file_sudo "$_BPO_LIST"
            else
                log "bookworm-backports already configured"
            fi
            unset _BPO_LIST
        fi
    elif [[ "$_cur_codename" != "trixie" ]] && [[ -n "$_cur_codename" ]]; then
        log "Current release: ${_cur_codename} — upgrading to Trixie (Debian 13)"
        _did_trixie_rewrite=true
        # Legacy /etc/apt/sources.list is OPTIONAL — recent Crostini bookworm containers ship deb822-only (debian.sources, no legacy file). The *.sources loop below handles those. Only process the legacy file when it actually exists.
        if [[ -f /etc/apt/sources.list ]]; then
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
        else
            log "No legacy /etc/apt/sources.list — deb822-only layout; deferring to *.sources loop"
        fi
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
        _nullglob_was_set=false
        shopt -q nullglob && _nullglob_was_set=true
        shopt -s nullglob
        for _sfile in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [[ -f "$_sfile" ]] || continue
            # Skip any *-backports source — mechanical rewrite would produce `trixie-backports` which may not yet exist at upgrade time (breaks apt-get update mid-run). The bookworm-backports.list written by step 2a is the common case on re-run.
            case "$(basename -- "$_sfile")" in
                *backports*) log "Skipping backports source: ${_sfile}"; continue ;;
            esac
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
        $_nullglob_was_set || shopt -u nullglob
        unset _sfile _sfile_bak _nullglob_was_set
    elif [[ "$_cur_codename" == "trixie" ]]; then
        log "Already running Trixie — no upgrade needed"
    else
        die "Unhandled release codename '${_cur_codename}' — aborting"
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
        run sudo apt-mark hold "${_CROS_HOLD_PKGS[@]}" \
            || warn "apt-mark hold failed — Crostini packages may be upgraded (risky)"
        log "Held Crostini packages: ${_CROS_HOLD_PKGS[*]}"
    fi

    if run sudo DEBIAN_FRONTEND=noninteractive apt-get update; then
        # NOTE: dpkg /lib/* "Directory not empty" warnings during Trixie upgrade are harmless (UsrMerge)
        log "NOTE: dpkg /lib/* directory warnings during upgrade are expected (UsrMerge transition)"
        # full-upgrade only — plain `upgrade` keeps back ~160 pkgs on codename transition because it cannot add/remove. Running both wastes ~4 min and risks SIGTERM. --force-confdef --force-confold: prevent interactive dpkg prompts during upgrade
        run sudo DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            || warn "apt-get full-upgrade had issues"
    else
        warn "apt update failed — skipping upgrade (stale package indices)"
    fi

    # @@WHY: cros-guest-tools stays held permanently (cros-im unavailable on Trixie) On bookworm, cros-im IS available — unhold everything.
    _CROS_UNHOLD_PKGS=()
    for _cpkg in "${_CROS_HOLD_PKGS[@]}"; do
        if ! $IS_BOOKWORM; then
            [[ "$_cpkg" == "cros-guest-tools" ]] && continue
        fi
        _CROS_UNHOLD_PKGS+=("$_cpkg")
    done
    if [[ "${#_CROS_UNHOLD_PKGS[@]}" -gt 0 ]]; then
        run sudo apt-mark unhold "${_CROS_UNHOLD_PKGS[@]}" || warn "apt-mark unhold failed"
        log "cros-guest-tools remains held (cros-im unavailable on Trixie)"
    fi
    unset _CROS_HOLD_PKGS _CROS_UNHOLD_PKGS _cpkg

    # @@WHY: No --purge — conffiles may be needed by Crostini packages at next boot
    run sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || warn "apt autoremove had issues"

    # 2c. Verify upgrade landed on Trixie
    _post_codename="$(_read_os_release VERSION_CODENAME)"
    if [[ "$_post_codename" == "trixie" ]]; then
        log "Trixie upgrade verified: $(_read_os_release PRETTY_NAME 'Debian 13')"
    elif [[ -n "$_post_codename" ]]; then
        warn "Expected trixie after upgrade, got ${_post_codename} — partial upgrade?"
        warn "Re-run the script or manually: sudo apt update && sudo apt full-upgrade"
    fi
    unset _post_codename

    # 2d. Cap /tmp tmpfs at 512M (OOM mitigation for 4 GB RAM; write before first Trixie restart) Skipped on bookworm: bookworm /tmp is disk-backed, not tmpfs.
    if $IS_BOOKWORM; then
        log "Skipping /tmp tmpfs cap on bookworm (disk-backed /tmp)"
    else
        _TMP_DROPIN="/etc/systemd/system/tmp.mount.d/override.conf"
        if [[ ! -f "$_TMP_DROPIN" ]]; then
            write_file_sudo "$_TMP_DROPIN" <<'TMPEOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=512M,nr_inodes=1m
TMPEOF
            run sudo systemctl daemon-reload \
                || warn "daemon-reload failed — /tmp cap takes effect on next container start"
            log "/tmp tmpfs capped at 512M (OOM mitigation)"
        else
            log "tmp.mount drop-in already exists"
        fi
        unset _TMP_DROPIN
    fi

    # 2e. Migrate APT sources to deb822 format
    if apt modernize-sources --help &>/dev/null; then
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
    if $_did_trixie_rewrite; then
        warn "Trixie dist-upgrade replaced libc6/dbus/systemd under a running container."
        warn "REQUIRED: 'Shut down Linux' from the ChromeOS shelf, then re-run this script."
        warn "Checkpoint saved — re-run will resume at step 3 automatically."
        warn "Hard-stop: continuing in-session risks SIGTERM mid-run when dpkg replaces libc6/dbus/systemd."
        exit 0
    fi
    log "No codename rewrite performed: continuing in-session to step 3 (no restart required)."
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
        # psmisc: provides fuser — used by sudo-keepalive to detect dpkg frontend lock
        psmisc

        # Misc
        tmux screen man-db bash-completion locales

        # Wayland clipboard (wl-copy / wl-paste for terminal ↔ GUI integration)
        wl-clipboard

        # Rust CLI alternatives — enhanced replacements for grep/find/cat
        ripgrep fd-find fzf bat
    )

    install_pkgs_best_effort "${CORE_PKGS[@]}" || warn "Some core CLI packages unavailable — non-fatal"

    # bookworm: 7zip package provides 7zz, not 7z. Add p7zip-full for the canonical `7z` command.
    if $IS_BOOKWORM; then
        install_pkgs_best_effort p7zip-full || warn "p7zip-full install failed — 7z command may be unavailable"
    fi

    # Create common symlinks for renamed Debian packages
    if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        _fd_path="$(command -v fdfind)"
        if run sudo ln -sf "$_fd_path" /usr/local/bin/fd; then
            log "Symlinked fdfind → fd"
        else
            warn "Symlink fdfind → fd failed"
        fi
        unset _fd_path
    fi
    if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        _bat_path="$(command -v batcat)"
        if run sudo ln -sf "$_bat_path" /usr/local/bin/bat; then
            log "Symlinked batcat → bat"
        else
            warn "Symlink batcat → bat failed"
        fi
        unset _bat_path
    fi

    unset CORE_PKGS

    # earlyoom: userspace OOM killer — kernel OOM too late in containers, systemd-oomd needs cgroup v2
    if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom; then
        _EARLYOOM_CONF="/etc/default/earlyoom"
        # bookworm: no box64/dosbox-x; use vanilla dosbox in the prefer regex
        _EOOM_PREFER="retroarch|box64|wine|dosbox-x|scummvm"
        $IS_BOOKWORM && _EOOM_PREFER="retroarch|wine|dosbox|scummvm"
        # @@WHY: marker check is self-healing — apt upgrade loss or version bump both trigger re-write
        if [[ ! -f "$_EARLYOOM_CONF" ]] || ! grep -Fq "ry-crostini:${SCRIPT_VERSION}" "$_EARLYOOM_CONF"; then
            # Direct interpolation — sed substitution corrupted the value because _EOOM_PREFER contains the sed delimiter character `|`. Build the file with printf and write atomically via write_file_sudo's stdin.
            printf '%s\n' \
                "# earlyoom config — managed by ry-crostini.sh" \
                "# ry-crostini:${SCRIPT_VERSION}" \
                "EARLYOOM_ARGS=\"-m 10 -s 10 -p --prefer (${_EOOM_PREFER}) --avoid (^|/)(init|systemd|dbus-daemon|garcon|sommelier)\$ --sort-by-rss -r 3600\"" \
                | write_file_sudo "$_EARLYOOM_CONF"
            # Post-write validation — guards against future template regressions
            if ! sudo grep -Eq '^EARLYOOM_ARGS=.*--prefer \([^)]*\|[^)]*\)' "$_EARLYOOM_CONF"; then
                die "earlyoom config malformed after write — --prefer regex missing or truncated: $_EARLYOOM_CONF"
            fi
        fi
        run sudo systemctl enable --now earlyoom.service \
            || warn "earlyoom enable failed"
        log "earlyoom installed and enabled"
        unset _EARLYOOM_CONF _EOOM_PREFER
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
            # Single awk pass extracts vendor/renderer/version in one fork
            {
                read -r GL_VENDOR
                read -r GL_RENDERER
                read -r GL_VERSION
            } < <(glxinfo 2>/dev/null | awk -F': ' '
                /^OpenGL vendor string/   {v=$2}
                /^OpenGL renderer string/ {r=$2}
                /^OpenGL version string/  {ver=$2}
                END {print v; print r; print ver}
            ' || printf '\n\n\n')
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
    if [[ ! -f "$GPU_ENV_FILE" ]] || ! grep -Fq "ry-crostini:${SCRIPT_VERSION}" "$GPU_ENV_FILE" 2>/dev/null; then
        _gpu_conf_content | sed "s/@@VERSION@@/${SCRIPT_VERSION}/" | write_file "$GPU_ENV_FILE"
    else
        log "GPU env up-to-date — skipping"
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

    # bookworm: refresh pipewire-audio + wireplumber from bookworm-backports (1.4.x / 0.5.x). Required because the WirePlumber JSON .conf written below needs >= 0.5.
    if $IS_BOOKWORM; then
        if run sudo DEBIAN_FRONTEND=noninteractive apt-get -y -t bookworm-backports install \
                pipewire-audio wireplumber; then
            log "PipeWire + WirePlumber upgraded from bookworm-backports"
        else
            warn "bookworm-backports pipewire/wireplumber install failed — JSON WP config will be ignored by 0.4.x"
        fi
    fi

    # Mask legacy PulseAudio daemon if present; ensure PipeWire audio chain is active
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

    # libavcodec-extra is now included in AUDIO_PKGS above (same transaction).

    # Verify audio
    if [[ -d /dev/snd ]]; then
        SND_DEV_COUNT="$(find /dev/snd -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)" || true
        log "Audio devices in /dev/snd: ${SND_DEV_COUNT} ✓"
        if _has_capture_dev; then
            log "Microphone capture device: detected ✓"
        else
            warn "No capture device. Enable mic: Settings → Developers → Linux → Microphone"
        fi
    else
        warn "/dev/snd not found. Audio may not work until container restart."
    fi

    # PipeWire gaming overrides — counteract KVM VM auto-detection (min-quantum=1024)
    _PW_GAMING="${HOME}/.config/pipewire/pipewire.conf.d/10-ry-crostini-gaming.conf"
    if [[ ! -f "$_PW_GAMING" ]] || ! grep -Fq "ry-crostini:${SCRIPT_VERSION}" "$_PW_GAMING" 2>/dev/null; then
        _pw_gaming_content | sed "s/@@VERSION@@/${SCRIPT_VERSION}/" | write_file "$_PW_GAMING"
    else
        log "PipeWire gaming config up-to-date"
    fi
    unset _PW_GAMING

    # PipeWire-Pulse user-level gaming override — disable pulse-layer VM quantum override
    _PW_PULSE_GAMING="${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-ry-crostini-gaming.conf"
    if [[ ! -f "$_PW_PULSE_GAMING" ]] || ! grep -Fq "ry-crostini:${SCRIPT_VERSION}" "$_PW_PULSE_GAMING" 2>/dev/null; then
        _pw_pulse_gaming_content | sed "s/@@VERSION@@/${SCRIPT_VERSION}/" | write_file "$_PW_PULSE_GAMING"
    else
        log "PipeWire-Pulse gaming config up-to-date"
    fi
    unset _PW_PULSE_GAMING

    # WirePlumber ALSA tuning — optimizes ALSA node buffer parameters for gaming latency
    _WP_ALSA="${HOME}/.config/wireplumber/wireplumber.conf.d/51-crostini-alsa.conf"
    if [[ ! -f "$_WP_ALSA" ]] || ! grep -Fq "ry-crostini:${SCRIPT_VERSION}" "$_WP_ALSA" 2>/dev/null; then
        sed "s/@@VERSION@@/${SCRIPT_VERSION}/" <<'WPEOF' | write_file "$_WP_ALSA"
# WirePlumber ALSA tuning for Crostini gaming — managed by ry-crostini.sh
# ry-crostini:@@VERSION@@
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
        log "WirePlumber ALSA config up-to-date"
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
    # Apply Xresources — only if an X display is reachable (sommelier may not be up yet on first install)
    if [[ -n "${DISPLAY:-}" ]] && command -v xrdb &>/dev/null; then
        if run xrdb -merge "$XRESOURCES"; then
            log "Xresources merged"
        else
            warn "xrdb merge failed — Xresources not applied until next session"
        fi
    else
        log "Skipping xrdb merge — no DISPLAY (will apply on next terminal session)"
    fi

    # 7g. Fontconfig (grayscale AA for OLED, Noto defaults)
    FC_LOCAL="${HOME}/.config/fontconfig/fonts.conf"
    if [[ ! -f "$FC_LOCAL" ]] || ! grep -Fq "ry-crostini:${SCRIPT_VERSION}" "$FC_LOCAL" 2>/dev/null; then
        sed "s/@@VERSION@@/${SCRIPT_VERSION}/" <<'FCEOF' | write_file "$FC_LOCAL"
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- ry-crostini:@@VERSION@@ -->
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
        log "Fontconfig up-to-date — skipping"
    fi
    if command -v fc-cache &>/dev/null; then
        if run timeout 60 fc-cache -f; then
            log "Font cache rebuilt"
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

    # bookworm: adwaita-icon-theme 43-1 does NOT include the full set; add separate package.
    if $IS_BOOKWORM; then
        install_pkgs_best_effort adwaita-icon-theme-full || warn "adwaita-icon-theme-full unavailable on bookworm"
    fi

    # gnome-disk-utility — heavy GNOME deps but useful for disk management
    run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-disk-utility \
        || warn "gnome-disk-utility install failed"

    # Ensure desktop applications directory exists (garcon integration)
    if run mkdir -p "${HOME}/.local/share/applications"; then
        log "Desktop applications directory: ${HOME}/.local/share/applications ✓"
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
            if run sudo sed -i 's/^#[[:space:]]*\(en_US\.UTF-8\)/\1/' /etc/locale.gen; then
                if run timeout 120 sudo locale-gen; then
                    run sudo rm -f -- /etc/locale.gen.bak || true
                    log "en_US.UTF-8 locale generated"
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
            log "XDG user directories updated"
        else
            warn "xdg-user-dirs-update failed"
        fi
    fi

    unset PROFILE_D

    # 9e. Disable background timers (compete for I/O/RAM during gaming)
    # apt-daily.timer: kept enabled — refreshes package lists so `apt upgrade` shows pending security fixes. apt-daily-upgrade.timer: masked (not just disabled) so a future package upgrade preset cannot re-enable it.
    run sudo systemctl mask apt-daily-upgrade.timer \
        || warn "Cannot mask apt-daily-upgrade timer"
    # Batch mask — guard with `systemctl cat` to avoid attempts on absent units
    _mask_timers=()
    for _timer in fstrim.timer e2scrub_all.timer man-db.timer; do
        systemctl cat "$_timer" &>/dev/null && _mask_timers+=("$_timer")
    done
    if [[ "${#_mask_timers[@]}" -gt 0 ]]; then
        run sudo systemctl mask "${_mask_timers[@]}" || true
    fi
    log "Unnecessary timers disabled/masked"
    unset _timer _mask_timers

    set_checkpoint 9
    log "Step 9 complete."
fi
# Step 10: Gaming packages
if should_run_step 10; then
    step_banner 10 "Gaming packages (DOSBox-X, ScummVM, RetroArch, FluidSynth soundfont, innoextract/GOG, unrar/unar, box64, qemu-user, DOSBox-X config, run-game launcher)"

    # Native ARM gaming packages — single batch; unrar (non-free) attempted separately below bookworm: dosbox-x is not in main or backports — fall back to vanilla `dosbox` (0.74).
    if $IS_BOOKWORM; then
        install_pkgs_best_effort scummvm fluid-soundfont-gm innoextract unar \
            dosbox retroarch retroarch-assets || warn "Some gaming packages failed"
        log "bookworm: installed vanilla dosbox in place of dosbox-x (dosbox-x not available)"
    else
        install_pkgs_best_effort scummvm fluid-soundfont-gm innoextract unar \
            dosbox-x retroarch retroarch-assets || warn "Some gaming packages failed"
    fi
    # Probe candidate before install — Trixie moves unrar to non-free-non-free. Attempting install with no candidate exits 100 and generates a noisy WARN.
    _unrar_cand="$(apt-cache policy unrar 2>/dev/null | awk '/Candidate:/ {print $2}')"
    if [[ -n "$_unrar_cand" && "$_unrar_cand" != "(none)" ]]; then
        if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unrar; then
            log "unrar installed ✓"
        else
            warn "unrar install failed — unar will be used for RAR archives"
        fi
    else
        log "unrar not available (non-free not enabled) — unar will be used for RAR archives ✓"
    fi
    unset _unrar_cand

    # RetroArch default config
    _RA_CFG="${HOME}/.config/retroarch/retroarch.cfg"
    if [[ ! -f "$_RA_CFG" ]]; then
        write_file "$_RA_CFG" <<'RACFG'
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
        write_file "$_SVM_CFG" <<'SVMCFG'
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
    if $IS_BOOKWORM; then
        log "bookworm: skipping DOSBox-X config write (dosbox-x not installed; vanilla dosbox uses incompatible format)"
    elif [[ ! -f "$_DBX_CFG" ]]; then
        write_file "$_DBX_CFG" <<'DBXCFG'
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

    # Verify installed gaming tools
    # bookworm: vanilla dosbox; trixie: dosbox-x
    _dbx_bin=dosbox-x
    $IS_BOOKWORM && _dbx_bin=dosbox
    if command -v "$_dbx_bin" &>/dev/null; then
        _dosbox_ver="$(timeout 3 "$_dbx_bin" --version 2>/dev/null | head -1 || true)"
        log "${_dbx_bin}: ${_dosbox_ver:-installed} ✓"
        unset _dosbox_ver
    else
        warn "${_dbx_bin} not found"
    fi
    unset _dbx_bin
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

    log "For advanced gaming (box64/Wine/GOG/cloud): see README.md § Gaming"

    # box64: x86_64 DynaRec emulator (binfmt blocked in unprivileged Crostini; invoke explicitly) Not in Debian main; bookworm has no candidate. Skip quietly there — run-x86 falls back to qemu-user.
    if $IS_BOOKWORM; then
        log "bookworm: skipping box64 (not in Debian repos); run-x86 will use qemu-user"
    else
        # Probe candidate before install — symmetric with unrar handling above
        _box64_cand="$(apt-cache policy box64 2>/dev/null | awk '/Candidate:/ {print $2}')"
        if [[ -n "$_box64_cand" && "$_box64_cand" != "(none)" ]]; then
            if run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y box64; then
                log "box64 installed ✓"
            else
                warn "box64 install failed"
            fi
        else
            log "box64 not available in current repos — run-x86 will use qemu-user"
        fi
        unset _box64_cand
    fi

    # qemu-user: TCG x86/i386 emulation (do NOT install qemu-user-binfmt — EPERM in unprivileged)
    install_pkgs_best_effort qemu-user || warn "qemu-user install failed"

    # Write ~/.box64rc with SC7180P-tuned defaults (skip on bookworm — box64 not installed)
    _BOX64_RC="${HOME}/.box64rc"
    if $IS_BOOKWORM; then
        log "bookworm: skipping .box64rc write (box64 not installed)"
    elif [[ ! -f "$_BOX64_RC" ]]; then
        write_file "$_BOX64_RC" <<'RCEOF'
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
# 0=off, 1=generate+use, 2=use existing only. Requires box64 ≥ v0.3.8.
# Default 1: generate on first run AND reuse. Switch to 2 only if you want a
# read-only cache (no new entries written) — useful after a known-good warmup.
BOX64_DYNACACHE=1
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
        printf 'run-x86: arch detection failed for %s\n' "$prog" >&2
        printf 'run-x86: refusing to guess — file is not a recognized x86_64 or i386 ELF.\n' >&2
        printf 'run-x86: verify with: file %s\n' "$prog" >&2
        exit 2
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
        # (keyword-only checks are bypassable by hostile scripts embedding "makeself").
        # Patterns cover legacy makeself (≤2.4 backtick `head`) and modern (≥2.5 $(head), _offset_).
        _ms_score=0
        _ms_head="$(head -200 -- "$installer" 2>/dev/null)" || _ms_head=""
        [[ "$_ms_head" == *'MS_dd='* || "$_ms_head" == *'MS_dd_Progress='* ]] && ((_ms_score++)) || true
        [[ "$_ms_head" == *'label='* ]]     && ((_ms_score++)) || true
        [[ "$_ms_head" == *'filesizes='* ]] && ((_ms_score++)) || true
        [[ "$_ms_head" == *'TMPROOT='* ]]   && ((_ms_score++)) || true
        [[ "$_ms_head" == *'offset=`head'* || "$_ms_head" == *'offset=$(head'* || "$_ms_head" == *'_offset_='* ]] && ((_ms_score++)) || true
        if [[ "$_ms_score" -lt 2 ]]; then
            printf 'gog-extract: %s does not appear to be a makeself archive (GOG Linux installer)\n' "$installer" >&2
            printf 'Expected a GOG .sh installer (makeself archive). Aborting for safety.\n' >&2
            printf 'Matched %d/5 makeself structural markers (need ≥2).\n' "$_ms_score" >&2
            exit 1
        fi
        unset _ms_score _ms_head
        printf 'Extracting GOG Linux installer: %s\n' "$installer"
        mkdir -p -- "$outdir"
        # NOTE: marker check is a sanity check, not a security boundary.
        # Only invoke gog-extract on installers from trusted sources.
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
# Pin to big cores: SC7180P Kryo Gold = part 0x804, generic Cortex-A76 = 0xd0b.
# Only applies when both conditions hold: heterogeneous parts detected AND
# a known A76-class part is present. Otherwise skips affinity entirely.
_big_cores=""
if [[ -d /sys/devices/system/cpu/cpu0 ]]; then
    _nparts="$(awk '/^CPU part/ {print $4}' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)"
    if [[ "${_nparts:-0}" -ge 2 ]] && grep -qE '^CPU part[[:space:]]*:[[:space:]]*0x(804|d0b)' /proc/cpuinfo 2>/dev/null; then
        # Collect core indices whose part matches Kryo Gold (0x804) or Cortex-A76 (0xd0b)
        _big_cores="$(awk '/^processor/{p=$3} /^CPU part.*0x(804|d0b)/{print p}' /proc/cpuinfo 2>/dev/null | paste -sd,)"
        # Reject anything that isn't a clean comma-separated digit list
        # (defends against awk emitting empty p, stray whitespace, or unexpected lines)
        [[ "$_big_cores" =~ ^[0-9]+(,[0-9]+)*$ ]] || _big_cores=""
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


# Step 11: Verification — tools and config files
if should_run_step 11; then
    # Inject install-time paths (profile.d not yet sourced in current shell). Scoped to step 11 — no value to earlier steps and avoids unnecessary PATH mutation on --from-step=1..10 runs.
    [[ -d "${HOME}/.local/bin" && ":${PATH}:" != *":${HOME}/.local/bin:"* ]] && PATH="${HOME}/.local/bin:${PATH}"

    step_banner 11 "Verification — tools and config files"

    logprintf '\n%bVerification results:%b\n\n' "$BOLD" "$RESET"

    # System
    logprintf '%bSystem:%b\n' "$BOLD" "$RESET"
    logprintf '  Architecture:  %s\n' "$(uname -m)"
    logprintf '  Kernel:        %s\n' "$(uname -r)"
    logprintf '  OS:            %s\n' "$(_read_os_release PRETTY_NAME unknown)"
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
            {
                read -r GL_VENDOR
                read -r GL_RENDERER
                read -r GL_VERSION
            } < <(glxinfo 2>/dev/null | awk -F': ' '
                /^OpenGL vendor string/   {v=$2}
                /^OpenGL renderer string/ {r=$2}
                /^OpenGL version string/  {ver=$2}
                END {print v; print r; print ver}
            ' || printf '\n\n\n')
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
            # vulkaninfo --summary uses `deviceName = ...` and `apiVersion = ...`
            # NOT `GPU name = ...` — earlier versions of this check grepped for
            # the wrong field name and never matched, silently reporting Vulkan
            # as unavailable even on systems where it works.
            VK_GPU="$(printf '%s\n' "$_vk_out" | grep "deviceName" | head -1 | cut -d= -f2 | xargs -r || true)"
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
    if _has_capture_dev; then
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

    # bookworm uses vanilla dosbox; trixie uses dosbox-x
    _dbx_check="dosbox-x|dosbox-x"
    $IS_BOOKWORM && _dbx_check="dosbox|dosbox"

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
        "${_dbx_check}" "scummvm|scummvm" "retroarch|retroarch" "innoextract|innoextract"
    unset _fd_cmd _bat_cmd _dbx_check

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

    # Remaining tools (parallel — fast commands; unrar handled conditionally above) bookworm: box64 not installed (not in Debian repos)
    if $IS_BOOKWORM; then
        _parallel_check_tools \
            "unar|unar" "qemu-x86_64|qemu-x86_64" \
            "run-x86|run-x86" "gog-extract|gog-extract" "run-game|run-game" \
            "earlyoom|earlyoom"
    else
        _parallel_check_tools \
            "unar|unar" "box64|box64" "qemu-x86_64|qemu-x86_64" \
            "run-x86|run-x86" "gog-extract|gog-extract" "run-game|run-game" \
            "earlyoom|earlyoom"
    fi
    logprintf '\n'

    # Config files
    logprintf '%bConfig files written:%b\n' "$BOLD" "$RESET"

    check_config "/etc/apt/apt.conf.d/90parallel"                "Apt download tuning"
    check_config "/etc/systemd/system/ry-crostini-cros-pin.service" "cros.list cleanup service"
    check_config "${HOME}/.config/environment.d/gpu.conf"       "GPU env"
    check_config "${HOME}/.config/environment.d/sommelier.conf"  "Sommelier scaling + keys"
    check_config "${HOME}/.config/environment.d/qt.conf"         "Qt scaling/theming"
    # Step 7: Qt GTK platform themes — check qt5-gtk-platformtheme and adwaita-qt independently
    if dpkg -s qt5-gtk-platformtheme &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "qt5-gtk-platformtheme"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "qt5-gtk-platformtheme not installed"
        ((_verify_warn++)) || true
    fi
    if dpkg -s adwaita-qt &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "adwaita-qt (Qt5 dark theme)"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "adwaita-qt not installed"
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
    $IS_BOOKWORM || check_config "/etc/systemd/system/tmp.mount.d/override.conf" "/tmp tmpfs 512M cap"
    check_config "${HOME}/.config/pipewire/pipewire.conf.d/10-ry-crostini-gaming.conf"        "PipeWire gaming quantum"
    check_config "${HOME}/.config/pipewire/pipewire-pulse.conf.d/10-ry-crostini-gaming.conf"   "PipeWire-Pulse gaming"
    check_config "${HOME}/.config/wireplumber/wireplumber.conf.d/51-crostini-alsa.conf"        "WirePlumber ALSA tuning"
    # WirePlumber version probe — the JSON .conf above is silently ignored by 0.4.x.
    # On bookworm this catches the case where the bookworm-backports refresh in step 6
    # failed and the system is still on stock 0.4.13 (config has no effect).
    # `wireplumber --version` prints the version on line 2 ("Compiled with libwireplumber X.Y.Z"),
    # not line 1 — grep across the full output, don't head it first.
    if command -v wireplumber &>/dev/null; then
        _wp_ver="$(timeout 3 wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if [[ -n "$_wp_ver" ]]; then
            _wp_major="${_wp_ver%%.*}"
            _wp_rest="${_wp_ver#*.}"
            _wp_minor="${_wp_rest%%.*}"
            if [[ "$_wp_major" -gt 0 || "$_wp_minor" -ge 5 ]]; then
                logprintf '  %b✓%b  %-44s %s\n' "$GREEN" "$RESET" "WirePlumber version" "$_wp_ver"
                ((_verify_pass++)) || true
            else
                logprintf '  %b⚠%b  %-44s %s (JSON config ignored — needs ≥ 0.5)\n' "$YELLOW" "$RESET" "WirePlumber version" "$_wp_ver"
                ((_verify_warn++)) || true
            fi
            unset _wp_major _wp_minor _wp_rest
        else
            logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "WirePlumber version unparseable"
            ((_verify_warn++)) || true
        fi
        unset _wp_ver
    fi
    check_config "/etc/systemd/journald.conf.d/volatile.conf"                                  "Journald volatile storage"
    check_config "${HOME}/.config/retroarch/retroarch.cfg"    "RetroArch config"
    check_config "${HOME}/.config/scummvm/scummvm.ini"                                       "ScummVM config"
    $IS_BOOKWORM || check_config "${HOME}/.box64rc"                                                           "box64 SC7180P config"
    $IS_BOOKWORM || check_config "${HOME}/.config/dosbox-x/dosbox-x.conf"                                    "DOSBox-X ARM64 config"
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
    # Re-validate the --prefer regex shape — step 3 validates at write time, but the
    # file could be corrupted later by manual edit, dpkg-overlay, or apt-purge restoring stock.
    # Same anchor pattern as the post-write check in step 3.
    if [[ -s /etc/default/earlyoom ]]; then
        if grep -Eq '^EARLYOOM_ARGS=.*--prefer \([^)]*\|[^)]*\)' /etc/default/earlyoom 2>/dev/null; then
            logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "earlyoom --prefer regex valid"
            ((_verify_pass++)) || true
        else
            logprintf '  %b✗%b  %-44s\n' "$RED" "$RESET" "earlyoom --prefer regex missing/corrupt"
            ((_verify_fail++)) || true
        fi
    fi
    # earlyoom may have been killed during heavy apt operations; restart if needed
    if ! systemctl is-active earlyoom.service &>/dev/null; then
        # shellcheck disable=SC2031  # LOG_FILE is main-shell here; subshell taint at line 549 is contained
        sudo systemctl start earlyoom.service 2>>"$LOG_FILE" \
            || warn "earlyoom auto-restart failed — check /etc/default/earlyoom and 'systemctl status earlyoom'"
    fi
    if systemctl is-active earlyoom.service &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "earlyoom OOM killer active"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "earlyoom not running"
        ((_verify_warn++)) || true
    fi
    # apt-daily-upgrade timer (unattended installs masked; apt-daily list refresh kept)
    if [[ "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)" == "masked" ]]; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "apt-daily-upgrade.timer masked"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "apt-daily-upgrade.timer not masked"
        ((_verify_warn++)) || true
    fi
    # apt-daily.timer (kept enabled — refreshes package lists for security visibility)
    if systemctl is-enabled apt-daily.timer &>/dev/null; then
        logprintf '  %b✓%b  %-44s\n' "$GREEN" "$RESET" "apt-daily.timer enabled (security refresh)"
        ((_verify_pass++)) || true
    else
        logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "apt-daily.timer disabled — security refresh inactive"
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
        else
            logprintf '  %b⚠%b  %-44s\n' "$YELLOW" "$RESET" "RetroArch video_threaded line missing from config"
            ((_verify_warn++)) || true
        fi
    fi
    logprintf '\n'

    set_checkpoint 11
    # Snapshot failure count so cleanup() prints the correct message if an exit occurs between here and step 13's final assignment to _had_failures.
    _had_failures="$_verify_fail"
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
    _had_failures="$_verify_fail"
    log "Step 12 complete."
fi
# Step 13: Verification summary
if should_run_step 13; then
    step_banner 13 "Verification summary"

    logprintf '%bQuick-test commands:%b\n' "$BOLD" "$RESET"
    logprintf '  GPU/Audio:   glxgears / vulkaninfo --summary / pactl info\n'
    logprintf '  Display:     xdpyinfo | grep resolution / fc-match sans-serif / fc-match monospace\n'
    if $IS_BOOKWORM; then
        logprintf '  Gaming:      glxinfo | grep renderer / printenv MESA_NO_ERROR / pw-top / dosbox --version\n'
    else
        logprintf '  Gaming:      glxinfo | grep renderer / printenv MESA_NO_ERROR / pw-top / dosbox-x --version\n'
    fi
    logprintf '\n'

    # Reminders
    logprintf '%bReminders:%b\n' "$YELLOW" "$RESET"
    logprintf '  • Manual .deb downloads: always get the arm64 variant\n'
    logprintf '  • If GPU not active: reboot entire Chromebook (not just container)\n'
    logprintf '  • Gaming (box64/Wine/GOG/cloud): see README.md § Gaming\n'
    logprintf '\n'

    # shellcheck disable=SC2031  # LOG_FILE is main-shell here
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
        rm -f -- "$STEP_FILE"
        log "Checkpoint file removed. Setup fully complete."
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
    # Parse environment.d files as KEY=VALUE (systemd format) rather than sourcing them as shell. Sourcing breaks values containing shell metachars — e.g. qt.conf's `QT_QPA_PLATFORM=wayland;xcb` would be split at the `;` and the exported value would be just "wayland". The on-disk file is parsed correctly by systemd-environment-d-generator on next session start; this block exists only to make the changes live in the current session.
    if [[ -d "${HOME}/.config/environment.d" ]]; then
        _had_nullglob_env=false
        shopt -q nullglob && _had_nullglob_env=true
        shopt -s nullglob
        for _envf in "${HOME}/.config/environment.d/"*.conf; do
            while IFS= read -r _eline || [[ -n "$_eline" ]]; do
                # Skip blank lines (any whitespace) and comments
                [[ "$_eline" =~ ^[[:space:]]*$ ]] && continue
                [[ "${_eline#"${_eline%%[![:space:]]*}"}" == \#* ]] && continue
                # Require KEY=VALUE shape; strip leading whitespace
                _eline="${_eline#"${_eline%%[![:space:]]*}"}"
                [[ "$_eline" == *=* ]] || continue
                _ek="${_eline%%=*}"
                _ev="${_eline#*=}"
                # Validate key: identifier chars only (defends against pathological lines)
                [[ "$_ek" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
                # Strip optional surrounding double OR single quotes (systemd environment.d accepts both forms)
                if [[ "$_ev" == \"*\" && ${#_ev} -ge 2 ]]; then
                    _ev="${_ev:1:${#_ev}-2}"
                elif [[ "$_ev" == \'*\' && ${#_ev} -ge 2 ]]; then
                    _ev="${_ev:1:${#_ev}-2}"
                fi
                # Expand ${HOME} / $HOME — the only variable reference systemd environment.d files in this script use (gpu.conf MESA_SHADER_CACHE_DIR). Done as literal string substitution to avoid re-invoking the shell parser.
                _ev="${_ev//\$\{HOME\}/$HOME}"
                _ev="${_ev//\$HOME/$HOME}"
                export "$_ek=$_ev"
            done < "$_envf"
        done
        $_had_nullglob_env || shopt -u nullglob
        unset _envf _eline _ek _ev _had_nullglob_env
    fi
    # Import only the keys actually defined in environment.d files into the systemd user session.
    # Unscoped `import-environment` would leak script-internal vars (LOG_FILE, _verify_*, IS_BOOKWORM, etc.).
    if [[ -d "${HOME}/.config/environment.d" ]]; then
        _import_keys=()
        _had_nullglob_imp=false
        shopt -q nullglob && _had_nullglob_imp=true
        shopt -s nullglob
        for _envf in "${HOME}/.config/environment.d/"*.conf; do
            while IFS= read -r _eline || [[ -n "$_eline" ]]; do
                [[ "$_eline" =~ ^[[:space:]]*$ ]] && continue
                [[ "${_eline#"${_eline%%[![:space:]]*}"}" == \#* ]] && continue
                _eline="${_eline#"${_eline%%[![:space:]]*}"}"
                [[ "$_eline" == *=* ]] || continue
                _ek="${_eline%%=*}"
                [[ "$_ek" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && _import_keys+=("$_ek")
            done < "$_envf"
        done
        $_had_nullglob_imp || shopt -u nullglob
        if [[ "${#_import_keys[@]}" -gt 0 ]] && systemctl --user import-environment "${_import_keys[@]}" 2>/dev/null; then
            log "Imported ${#_import_keys[@]} environment.d key(s) into user session"
        fi
        unset _envf _eline _ek _import_keys _had_nullglob_imp
    fi
    # Restart sommelier — enumerate active instances rather than hardcoding @0
    mapfile -t _somm_units < <(systemctl --user list-units --type=service --state=active --no-legend 'sommelier@*.service' 'sommelier-x@*.service' 2>/dev/null | awk '{print $1}')
    if [[ "${#_somm_units[@]}" -gt 0 ]] && systemctl --user restart "${_somm_units[@]}" 2>/dev/null; then
        # Brief settle — sommelier needs ~1 s to re-establish the display socket
        sleep 1
        if pgrep -x sommelier &>/dev/null; then
            log "Sommelier restarted (${_somm_units[*]}) — environment changes are live"
        else
            logprintf '\n%bSommelier restart failed — shut down Linux (Settings → Developers) and reopen Terminal.%b\n\n' "$BOLD" "$RESET"
        fi
    else
        logprintf '\n%bRestart the Terminal app to apply all environment changes.%b\n\n' "$BOLD" "$RESET"
    fi
    unset _somm_units
    log "Step 13 complete."
fi

if $_no_checks_ran; then
    exit 2
fi
if [[ "$_had_failures" -gt 0 ]]; then
    exit 1
fi
exit 0
