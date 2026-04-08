ry-crostini changelog

2026-04-08  Ryan Musante

- Tagged as v8.1.9
- Sudo keepalive `fuser /var/lib/dpkg/lock-frontend` lock-held guard replaced with `pgrep -x apt-get || pgrep -x apt || pgrep -x dpkg`. The fuser probe silently short-circuited false on any container without psmisc, and psmisc is not installed until step 3 of the script — so on a stock `--upgrade-trixie` first-run against a fresh Crostini container, the guard was inert during step 2's libpam/libc6 replacement. After ~15 minutes of transient `sudo -n -v` failures the keepalive would `kill -TERM $$` and abort the run. pgrep is from procps (Priority: important on Debian) which is always preinstalled. Flock on the lock file directly was considered and rejected: /var/lib/dpkg/lock-frontend is mode 640 root:root, so an unprivileged flock always fails on permission and would falsely report "held" forever, masking real credential failures.
- Log file creation switched from `touch + chmod 600` to `( umask 077; : > "$LOG_FILE" )`. The file is now born at mode 0600 rather than existing briefly at 0644, closing a (very small, single-user) permission window. Matches the "0600 sensitive" user pref.
- `PIPE` dropped from the signal trap set (handler case, trap list, cleanup allowlist, and cleanup's trap-reset — all four sites). SIGPIPE is unlike INT/TERM/HUP/QUIT: it's not a user-initiated cancellation, it's a downstream reader closing the pipe. The previous trap would exit 141 on `bash ry-crostini.sh | head`, which was surprising. Default bash SIGPIPE handling restored.
- New unconditional cros-* stale-hold sweep runs just before step 1. apt-mark showhold is filtered through an anchored regex matching only this script's own step-2 hold set, and any matches are unheld via `run sudo apt-mark unhold`. Fixes the edge case where a mid-step-2 crash between `apt-mark hold` and `apt-mark unhold` left packages permanently held — previously recoverable only by default-resume (which re-entered step 2), but not by `--from-step=3+` resume (which skipped step 2 entirely). On trixie, cros-guest-tools is excluded from the sweep because step 2 intentionally keeps it held there.
- Step 2 "all holds released" log path fixed. The log `"cros-guest-tools remains held (cros-im unavailable on Trixie)"` previously fired unconditionally whenever `_CROS_UNHOLD_PKGS` was non-empty, including on bookworm where cros-guest-tools had just been added to the unhold set. Now branches on `$IS_BOOKWORM` and emits the correct message on each path.
- Step 3 earlyoom post-write validation: dropped unnecessary `sudo` from `grep -Eq` on /etc/default/earlyoom. The file is mode 644 (write_file_sudo chmods 644); sudo was wasteful. Parity with step 11 verify which was de-sudo'd in v8.1.7.
- Step 10 inline version probes (`timeout 3 <cmd> --version` for dosbox, scummvm, innoextract) and step 11 wireplumber version probe all raised to `timeout 5`, matching the check_tool raise in v8.1.8.
- Step 8 gnome-disk-utility install switched from bare `run sudo apt-get install -y` to `install_pkgs_best_effort`, restoring parity with every other package install in the script and gaining the batch-then-per-package fallback.
- Step 11 earlyoom auto-restart routed through `run()` instead of `sudo systemctl start ... 2>>"$LOG_FILE"`. Consistent with every other command in the verify steps; gains PIPESTATUS capture and errexit/pipefail save/restore.
- Step 8/9 `run mkdir -p` calls replaced with plain `mkdir -p ... 2>>"$LOG_FILE"`. `run()` is for commands whose output matters; silent idempotent mkdir doesn't need the tee pipeline.
- Step 2 trixie codename rewrites (sources.list, cros.list, .sources/.list loop, Suites: lines) all gained `\<...\>` word-boundary anchors around `${_cur_codename}`. Behaviorally identical for all real Debian sources; defense-in-depth against a hypothetical suite name containing the codename as an internal substring.
- Step 13 `systemctl --user import-environment` now routes stderr to the log file and emits a `warn` on failure instead of swallowing it with `2>/dev/null`. Mirrors the earlyoom auto-restart pattern.
- `_parallel_check_tools` gained a preamble comment documenting why the subshell's LOG_FILE=/dev/null + _verify_*=0 reassignments generate SC2030/2031 notes and why the pattern must not be "fixed" by hoisting.
- CORE_PKGS `psmisc` comment updated — no longer required by the sudo keepalive (pgrep from procps now handles the lock-held detection), but kept for general sysadmin use.

2026-04-08  Ryan Musante

- Tagged as v8.1.8
- Step 2 `VERSION_CODENAME` empty-check hoisted above the `--upgrade-trixie` branch. Step 1 dies on empty codename but `--from-step=2` skips step 1 entirely — the prior empty-guard at step 2 only fired on NON-empty invalid values, so an empty codename fell through to `log "Staying on ;"` and silently skipped the `bookworm-backports` enable. Now dies explicitly at step 2 entry; the downstream `else die "Cannot determine..."` branch is reworded to "Unhandled release codename" since it's no longer reachable via empty.
- Step 2 trixie suite-rewrite loop now skips `*backports*` source files. On a re-run where step 2a previously wrote `bookworm-backports.list`, `--upgrade-trixie` would mechanically rewrite it to `trixie-backports`, which may not exist at upgrade time and breaks the subsequent `apt-get update`. The backports source is now logged and skipped; user can re-enable trixie-backports manually after upgrade.
- Step 3 adds `psmisc` to CORE_PKGS. The sudo-keepalive's `fuser /var/lib/dpkg/lock-frontend` probe silently false-negatives on minimal Debian containers where psmisc is not preinstalled, causing the keepalive to count dpkg-lock-held ticks as failures during long Trixie upgrades. `psmisc` is small and its absence was a latent dependency.
- Steps 1/6/11 microphone capture detection replaced with a `_has_capture_dev` helper using `find /dev/snd -name 'pcmC*D*c'`. The prior literal `pcmC0D0c || pcmC1D0c` check missed any card index ≥2 — rare in Crostini but possible after USB audio pass-through.
- Step 13 environment.d parser fixes: (1) blank-line check now matches `^[[:space:]]*$` instead of `${_eline// }` so tab-only lines are correctly skipped; (2) surrounding single-quote stripping added alongside double-quote stripping — systemd environment.d accepts both forms and the prior parser fed quoted values through verbatim.
- Step 10 `run-game` CPU-part grep anchored to `^CPU part[[:space:]]*:` so a stray `0x804`/`0xd0b` substring elsewhere in `/proc/cpuinfo` cannot false-positive the big.LITTLE detection.
- `check_tool` version-probe timeout raised from 3s to 5s (3 call sites). Cold `vulkaninfo --version` on first run after Mesa shader-cache invalidation can exceed 3s on SC7180P, producing a spurious "version unverified" warn in step 11.
- Changelog footer: removed stale `dry-run` reference; the `--dry-run` mode was fully removed in v8.1.5.

2026-04-07  Ryan Musante

- Tagged as v8.1.7
- Step 10 `run-x86` arch fallback hardened. The wrapper previously printed "arch detection failed — assuming x86_64" and exec'd box64 anyway, producing confusing emulator-level errors when the file was actually i386, ARM64-native, or non-ELF. Now exits 2 with a clear message instructing the user to verify with `file <prog>`. No more silent guesses.
- Step 10 `gog-extract` makeself marker check broadened. The legacy `offset=\`head` pattern only matched makeself ≤2.4 archives; modern installers (makeself ≥2.5) use `offset=$(head` or `_offset_=`. Both new patterns are now accepted, fixing false-negative refusals on current GOG Linux installers. Added explicit comment that the marker check is a sanity check and not a security boundary.
- Step 13 `import-environment` scoped to explicit keys. Previously called with no arguments, which imported the *entire* current shell environment into the systemd user session — leaking script-internal vars (`LOG_FILE`, `_verify_*`, `IS_BOOKWORM`, `_PROGRESS_*`, etc.) into every user-session service launched afterward. Now parses `~/.config/environment.d/*.conf` for KEY names and passes only those to `systemctl --user import-environment`.
- Step 13 sommelier restart enumerates active instances. The hardcoded `sommelier@0.service sommelier-x@0.service` pair was a no-op on any session that landed on a different instance number. Now uses `systemctl --user list-units --type=service --state=active 'sommelier@*.service' 'sommelier-x@*.service'` to find all live units and restarts the actual set.
- Step 9 `apt-daily-upgrade.timer` is now masked, not just disabled. A future package upgrade preset can re-enable a disabled unit but cannot re-enable a masked one. Step 11 verification updated to check for the `masked` state.
- Step 5 + step 11 glxinfo parse collapsed to a single awk pass. Previously read the glxinfo output through three separate `grep | head | cut | xargs` pipelines; now reads it once and emits all three fields. Cosmetic, but removes 6 forks per verify run.
- Step 7 `xrdb -merge` now gated on `[[ -n "$DISPLAY" ]]`. The merge always failed silently on first install when sommelier had not yet brought up an X display, producing a benign-but-confusing WARN in the log. Logs a clean "skipping" message instead.
- Step 9 locale.gen sed pattern broadened to `^#[[:space:]]*` so a tab between `#` and `en_US.UTF-8` (rare but possible after manual edit) no longer prevents uncommenting.
- Step 9 timer existence probe replaced. `systemctl list-unit-files --no-legend "$_timer" | grep -q .` works but is non-canonical; `systemctl cat "$_timer" &>/dev/null` is the standard form.
- Step 10 `box64` install now gated on `apt-cache policy` candidate probe (parity with the `unrar` handling at step 10). Bare `apt-get install` produced a noisy WARN on any future Debian release where box64 lacks a candidate; the probe makes it a clean log line.
- Step 10 `.box64rc` `BOX64_DYNACACHE` default flipped from 2 (use existing only) to 1 (generate+use). The previous default required manual user intervention to ever populate the cache on a fresh install — flipping to 1 is correct for first-run and the comment now documents flipping to 2 only as a read-only mode.
- Step 11 dropped unnecessary `sudo` on `grep` of `/etc/default/earlyoom`. The file is mode 644 by default; `sudo` was wasteful.
- Step 11 silenced the last SC2031 false positive at the earlyoom restart line. `LOG_FILE` here is main-shell scope; the subshell taint at line 549 (parallel verify) is contained and was already disabled at the re-aggregation site.
- Step 2 `apt modernize-sources` probe replaced fragile `apt --help | grep` with the canonical `apt modernize-sources --help &>/dev/null` subcommand probe.
- Internal cleanup: cached `command -v fdfind/batcat` results before symlinking (no double resolution); renamed `_had_nullglob` → `_nullglob_was_set` in the deb822 loop for clarity. No behavior change.

2026-04-07  Ryan Musante

- Tagged as v8.1.6
- Step 11 Vulkan parse fixed. The previous code grepped `vulkaninfo --summary` for `"GPU name"` and `"apiVersion"`, but the actual field name is `deviceName` (the wrong grep meant `VK_GPU` was always empty and the script unconditionally reported "Vulkan: not available (virgl does not support Vulkan)" — even on systems where Vulkan was actually present). Changed to `grep "deviceName"`. The apiVersion grep was always correct.
- Step 11 RetroArch threaded check now warns on the missing-line case. Previously the check had two branches (`video_threaded="false"` ✓, `video_threaded="true"` ⚠) and silently no-op'd if the line was absent entirely — masking the gap. Added a third branch that warns "video_threaded line missing from config".
- Step 11 WirePlumber version probe added. The JSON `51-crostini-alsa.conf` is silently ignored by 0.4.x (only consumed by 0.5+). On bookworm the script tries to refresh from bookworm-backports in step 6, but if that install fails the verify step never noticed — the user's gaming-tuning config did nothing. Now probes `wireplumber --version`, parses the major.minor, and warns if < 0.5 with explicit message that the JSON config is ignored.
- Step 11 `apt-daily.timer` complementary check added. The script intentionally KEEPS this timer enabled for security-list refreshes (only `apt-daily-upgrade.timer` is disabled to prevent unattended installs during gaming). Verify only checked the disabled half — accidental disable of `apt-daily.timer` (e.g. user mass-mask) was invisible. Added a positive-side check that warns if it's not enabled.
- Step 11 earlyoom `--prefer` regex re-validated at verify time. Step 3 validates the regex at WRITE time and dies on malformed output, but post-install corruption (manual edit, dpkg-overlay, apt-purge restoring stock config) was invisible because `check_config` only verified file existence and non-emptiness. Verify now greps the same `^EARLYOOM_ARGS=.*--prefer \([^)]*\|[^)]*\)` anchor that the write-time check uses and reports a hard fail (not warn) on missing or corrupt regex.

2026-04-07  Ryan Musante

- Tagged as v8.1.5
- Removed `--dry-run` mode entirely. The flag, the `DRY_RUN` global, the `--dry-run) DRY_RUN=true ;;` arg parser case, the usage() row, the README options table row, and the Design table row are all gone. Every `if $DRY_RUN; then ... fi`, `if ! $DRY_RUN; then ... fi`, `if $DRY_RUN; then DRY; else REAL; fi`, `if $DRY_RUN; then DRY; elif COND; then REAL; fi`, `if ! $DRY_RUN && ! $UNATTENDED; then REAL; elif $DRY_RUN && ! $UNATTENDED; then DRY; fi`, and `$DRY_RUN || cmd` construct in the script body has been collapsed to its live-mode branch and unindented one level. The architecture mismatch in step 1a, previously a warn-and-continue under dry-run, is now an unconditional `die`. Net 121 lines removed (2983 → 2862). Breaking change: anyone with `--dry-run` in muscle memory will now get `Unknown option: --dry-run` from the arg parser.

2026-04-07  Ryan Musante

- Tagged as v8.1.4
- Comment cleanup pass. Multi-line comment blocks joined into single lines (labeled-field blocks like the script header are preserved); trailing inline comments hoisted above their code with matching indent; heredoc bodies untouched. Net 47 lines removed.
- Removed dead `--skip-trixie` no-op handler. The flag was a backward-compat alias from when trixie-stay was the default (before v8.1.0); never documented in usage() or README; removing it now that several minor versions have passed.
- Cleared stale historical references. The `_tee_log` upstream-noise filter comment now uses plain prose. The step 2 hard-stop warn and the README `--upgrade-trixie` row no longer reference an older version by number — replaced with the underlying technical reason: dpkg replaces libc6/dbus/systemd under a running container.
- README System table corrected from 6 → 7 files. The `bookworm-backports.list` write added in v8.1.1 was never reflected. Both code paths still write 6 system files (bookworm: backports.list, no tmp.mount.d; trixie: tmp.mount.d, no backports.list), but the union is 7. Idempotency note unchanged — the 6 self-healing marker files are a separate set.

2026-04-07  Ryan Musante

- Tagged as v8.1.3
- cleanup() no longer calls `wait` on the disowned sudo keepalive PID. After `disown` the keepalive is no longer in this shell's job table, so `wait` returned immediately with "not a child of this shell" (suppressed by `2>/dev/null || true`) — pure dead code. The preceding `kill` is sufficient and the parent is exiting anyway. Removed the wait line and updated the inline comment to document why wait is impossible after disown.
- Old-log rotation now also sweeps orphaned `_strip_log_ansi` tmpfiles. The existing `find ~ -name 'ry-crostini-*.log' -mtime +7 -delete` glob does not match `${LOG_FILE}.strip_XXXXXXXX` files (the trailing `.strip_*` puts them outside the `*.log` pattern). Added a second find with `-name 'ry-crostini-*.log.strip_*' -mtime +1 -delete` (1-day window — these are always transient).
- retroarch.cfg, scummvm.ini, dosbox-x.conf, and .box64rc now write at mode 644 via `write_file` instead of mode 600 via `write_file_private`. None of these contain secrets, and the other 15 user config files are all 644. Existing installs are unaffected (file-existence skip gate); only fresh installs pick up the new mode. The now-unused `write_file_private` helper has been removed; `write_file` (644) and `write_file_exec` (700) remain.

2026-04-07  Ryan Musante

- Tagged as v8.1.2
- Step 13 live-reload of `~/.config/environment.d/*.conf` no longer corrupts values containing shell metacharacters. The previous `set -a; . "$f"; set +a` block ran each file through the bash parser, which treats `;` as a statement separator — so qt.conf's `QT_QPA_PLATFORM=wayland;xcb` exported `QT_QPA_PLATFORM=wayland` and silently ran `xcb` as a command (swallowed by `2>/dev/null || true`). Replaced with an explicit per-line KEY=VALUE parser: skips blanks/comments, validates key as a POSIX identifier, strips optional surrounding double quotes, expands `${HOME}` / `$HOME` via literal string substitution, and `export`s the result without re-invoking the shell parser.
- Removed unused `SKIP_TRIXIE` global. The variable was assigned at init and by the flag handlers but never read anywhere — `UPGRADE_TRIXIE` is the actual gate.

2026-04-07  Ryan Musante

- Tagged as v8.1.1
- Step 3 earlyoom config write no longer corrupts the `--prefer` regex. The previous `sed -e "s|@@PREFER@@|${_EOOM_PREFER}|"` template used `|` as the sed delimiter while `_EOOM_PREFER` itself contained `|` separators (`retroarch|wine|...`). On bookworm sed silently truncated the substitution to the first field, so earlyoom ran with `--prefer (retroarch)` only. On trixie the five-field replacement collided with sed's flag parser and exited 1 with `unknown option to s`, leaving an empty `/etc/default/earlyoom` (`check_config` only WARNs on empty files, so the failure was invisible). Fix: drop sed entirely and build the file with `printf` + direct shell interpolation, then validate the written file with `grep -Eq` and `die` on malformed output.
- Step 2a bookworm-backports `.list` is now written via `write_file_sudo` instead of `printf | run sudo tee`, restoring parity with every other system-file write in the script.
- Step 11 verification's silent earlyoom auto-restart now routes stderr to the log file and emits a `warn` on failure. Combined with the earlyoom config validation above, broken earlyoom configs are no longer invisible to the user.
- `run-game` core-affinity parser now validates `_big_cores` against `^[0-9]+(,[0-9]+)*$` before passing it to `taskset -c`.
- Old log file rotation is now gated on `! $DRY_RUN`. Previously `--dry-run` runs still deleted prior logs from disk.
- README System and User generated-files tables now document the bookworm deltas (5 system files instead of 6, 17 user files instead of 19).

2026-04-07  Ryan Musante

- Tagged as v8.1.0
- Bookworm becomes the primary target. The script now stays on the current codename by default and enables `bookworm-backports` for pipewire 1.4 / wireplumber 0.5; the `bookworm`→`trixie` codename rewrite is opt-in via `--upgrade-trixie`. Bookworm gating in step 2 (skip `/tmp` tmpfs cap), step 3 (use vanilla dosbox in earlyoom prefer regex; pull p7zip-full for the canonical `7z`), step 6 (refresh pipewire-audio + wireplumber from backports), step 8 (add adwaita-icon-theme-full), step 10 (vanilla `dosbox` in place of `dosbox-x`; skip box64 + .box64rc + dosbox-x.conf writes), step 11 (parallel verify uses `dosbox|dosbox`; skip box64 row), step 13 (gaming quick-test uses `dosbox --version`).
- `_did_trixie_rewrite` gate. Step 2 hard-stop only fires when sources were genuinely rewritten; already-trixie containers and bookworm-default runs continue in-session.

Older history archived; the entries above cover the current bookworm-primary architecture. The script remains unchanged in spirit: idempotent atomic writes, checkpoint resume, parallel verification, dry-run, `~/ry-crostini-YYYYMMDD-HHMMSS.log` (mode 600, rotated after 7 days).
