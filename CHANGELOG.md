ry-crostini changelog

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
