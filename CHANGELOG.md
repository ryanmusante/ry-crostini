ry-crostini changelog

2026-04-07  Ryan Musante

- Tagged as v8.1.2
- fix(MED): step 13 live-reload of `~/.config/environment.d/*.conf` no longer corrupts values containing shell metacharacters. The previous `set -a; . "$f"; set +a` block ran each file through the bash parser, which treats `;` as a statement separator — so qt.conf's `QT_QPA_PLATFORM=wayland;xcb` exported `QT_QPA_PLATFORM=wayland` and silently ran `xcb` as a command (swallowed by `2>/dev/null || true`). The xcb fallback was unavailable in the freshly imported user session until the next container restart, at which point systemd-environment-d-generator parsed the on-disk file correctly and self-healed. Replaced with an explicit per-line KEY=VALUE parser: skips blanks/comments, validates key as a POSIX identifier, strips optional surrounding double quotes, expands `${HOME}` / `$HOME` via literal string substitution (the only variable reference any of the script's environment.d files use), and `export`s the result without re-invoking the shell parser. Reproduced both the broken sourcing and the corrected parser before committing.
- fix(LOW): removed unused `SKIP_TRIXIE` global (SC2034). The variable was assigned at init, by `--upgrade-trixie`, and by `--skip-trixie`, but never read anywhere — `UPGRADE_TRIXIE` is the actual gate. The `--skip-trixie` flag is preserved as a pure no-op alias for backward compat.

2026-04-07  Ryan Musante

- Tagged as v8.1.1
- fix(CRITICAL): step 3 earlyoom config write no longer corrupts the `--prefer` regex. The previous `sed -e "s|@@PREFER@@|${_EOOM_PREFER}|"` template used `|` as the sed delimiter while `_EOOM_PREFER` itself contained `|` separators (`retroarch|wine|...`). On bookworm sed silently truncated the substitution to the first field, so earlyoom ran with `--prefer (retroarch)` only — wine, dosbox, scummvm were never preferred for OOM kill. On trixie the five-field replacement collided with sed's flag parser and exited 1 with `unknown option to s`, leaving an empty `/etc/default/earlyoom` (`check_config` only WARNs on empty files, so the failure was invisible). Fix: drop sed entirely and build the file with `printf` + direct shell interpolation, then validate the written file with `grep -Eq '^EARLYOOM_ARGS=.*--prefer \([^)]*\|[^)]*\)'` and `die` on malformed output. Reproduced both broken cases and the corrected output before committing.
- fix(MED): step 2a bookworm-backports `.list` is now written via `write_file_sudo` (atomic tmpfile + mv + symlink-refusal) instead of `printf | run sudo tee`, restoring parity with every other system-file write in the script.
- fix(MED): step 2d `/tmp` tmpfs cap `else` branch was indented one level too shallow (body at column 4, matching the `if/else/fi` itself), making the nesting unreadable. Reindented the entire body to column 8.
- fix(MED): step 11 verification's silent earlyoom auto-restart (`sudo systemctl start earlyoom.service 2>/dev/null || true`) now routes stderr to the log file and emits a `warn` on failure. Combined with the F1 fix above, broken earlyoom configs are no longer invisible to the user.
- fix(MED): stale comment at the step 11 `_had_failures` snapshot referenced "line ~2755" — the actual final assignment is ~160 lines later. Replaced the brittle line number with a stable description ("step 13's final assignment to _had_failures").
- fix(LOW): `run-game` core-affinity parser now validates `_big_cores` against `^[0-9]+(,[0-9]+)*$` before passing it to `taskset -c`. Defends against the awk pipeline emitting whitespace-only output if `/proc/cpuinfo` ever orders `CPU part` lines before `processor` lines.
- fix(LOW): old log file rotation (`find ~ -name 'ry-crostini-*.log' -mtime +7 -delete`) is now gated on `! $DRY_RUN`. Previously `--dry-run` runs still deleted prior logs from disk.
- fix(LOW): step 1g network-check budget comment now documents the true ~17s worst-case (3 attempts × max-time 5s + retry-delay) instead of leaving the apparent 5s to be misread.
- doc: README System and User generated-files tables now document the bookworm deltas (5 system files instead of 6: `tmp.mount.d/override.conf` is trixie-only; 17 user files instead of 19: `dosbox-x.conf` and `.box64rc` are trixie-only).

2026-04-07  Ryan Musante

- Tagged as v8.1.0
- feat(MAJOR): bookworm is now the primary target. The default flow stays on the current codename (no `bookworm`→`trixie` rewrite, no mandatory container restart). Trixie upgrade is opt-in via `--upgrade-trixie`. Already-on-trixie containers are unaffected — the script detects the codename and runs the existing trixie path. Bookworm-on-arrival is the documented Crostini default in 2026.
- feat(HIGH): step 2 enables `bookworm-backports` automatically when running on bookworm. Step 6 then refreshes `pipewire-audio` + `wireplumber` from backports (1.4.2 / 0.5.8) so the WirePlumber 0.5+ JSON `.conf` written by step 6 is honored. Without this, bookworm's stock wireplumber 0.4.13 (Lua-only) silently ignores the gaming-tuning config.
- feat(HIGH): step 3 adds `p7zip-full` on bookworm to provide the `7z` command. Bookworm's `7zip` package only ships `7zz`; the existing verification check for `7z` would otherwise fail.
- feat(HIGH): step 8 adds `adwaita-icon-theme-full` on bookworm. Bookworm's `adwaita-icon-theme` 43-1 does not include the full set; trixie's 45.0-4+ does and the package is unnecessary there.
- feat(HIGH): step 10 falls back to vanilla `dosbox` 0.74 on bookworm (`dosbox-x` is not in bookworm main or backports). The DOSBox-X config heredoc is skipped on bookworm since the format is incompatible. The earlyoom `--prefer` regex is templated and uses `dosbox` on bookworm, `dosbox-x` on trixie. The dosbox version probe in step 10 verification is dispatched to the right binary name.
- feat(HIGH): step 10 skips `box64` on bookworm with an informational log instead of a noisy WARN (`box64` is not in any Debian repo). `run-x86` already falls back to `qemu-user`. The `.box64rc` heredoc is skipped on bookworm.
- feat(MED): step 2 cros-package hold gating is now bookworm-aware. `cros-guest-tools` is unheld with the rest on bookworm (cros-im is available there); the permanent hold remains for trixie.
- feat(MED): step 2d `/tmp` tmpfs cap is skipped on bookworm. Bookworm's `/tmp` is disk-backed; the cap is only meaningful on trixie's tmpfs `/tmp`.
- feat(MED): step 11 verification adapts to the codename: tool-presence checks for `dosbox` vs `dosbox-x`, drops `box64` on bookworm, and skips the `tmp.mount` / `dosbox-x.conf` / `.box64rc` config-file checks on bookworm.
- feat(LOW): new `IS_BOOKWORM` global is set at script init (after argument parsing, before any `should_run_step` gate) so resume runs (`--from-step=N`, `--verify`) and standalone verify runs see the same value as fresh runs. Detection is gated on `! $UPGRADE_TRIXIE` so bookworm-with-upgrade-flag still applies trixie-targeted behavior in step 2 (cros hold, `/tmp` cap) before the rewrite.
- feat(LOW): step 2 hard-stop is now driven by `_did_trixie_rewrite`, set true only inside the actual rewrite branch. Previously the original v8.0.9 hard-stopped unconditionally even on already-trixie containers; v8.1.0 hard-stops only when sources were genuinely rewritten (i.e., the libc6/dbus/systemd swap actually happened).
- doc: header comments, `usage()` text, and step 2 banner reframed bookworm-primary. `--skip-trixie` is accepted as a backward-compat alias for the new default behavior.
- compat: trixie path is preserved bit-for-bit. All bookworm gates fall through to original trixie behavior when `IS_BOOKWORM=false`. Verified across four scenarios: bookworm default, bookworm + `--upgrade-trixie`, trixie default, trixie + `--upgrade-trixie` (no-op).

2026-04-07  Ryan Musante

- Tagged as v8.0.9
- fix(HIGH): step 2 now hard-exits after the Trixie dist-upgrade instead of emitting a soft WARN. Root cause of the v8.0.8 +14m03s SIGTERM (exit 143) during step 11 verification: dpkg replaces libc6/dbus/systemd mid-run, and any subsequent long-lived interaction with stale processes (dbus, sommelier, session manager) can trip the container into killing the script. The v8.0.7 recommendation was advisory and ignorable; v8.0.9 saves the checkpoint, prints the required action, and exits 0. Re-running resumes cleanly at step 3.
- fix(LOW): step 10 now probes `apt-cache policy unrar` before attempting install. Trixie moves unrar to `non-free-non-free`; the previous unconditional attempt exited 100 and produced a noisy `Command exited 100` WARN in every log. The probe is silent when no candidate exists and the script falls through to `unar` as before.
- chore(LOW): `_tee_log` now filters three anchored upstream-benign noise patterns before logging — (a) dpkg `unable to delete old directory '/…': Directory not empty` (Trixie usrmerge residue), (b) `…: Failed to write 'change' to '/sys/…/uevent': Permission denied` (udisks2 postinst `udevadm trigger` against read-only Crostini /sys), (c) `systemctl: error while loading shared libraries: libcrypto.so.3: …` (transient libssl3 → libssl3t64 t64 ABI transition). Patterns are line-anchored and will not match unrelated dpkg warnings or other systemctl errors.

2026-04-07  Ryan Musante

- Tagged as v8.0.8
- fix(HIGH): sudo keepalive no longer kills the script mid-`apt-get full-upgrade`. Root cause of the +4m20s (v8.0.6) and +8m53s (v8.0.7) SIGTERMs: during the Trixie dist-upgrade, dpkg replaces sudo + libpam-modules + libpam-modules-bin + libpam-runtime + libpam-systemd, and `sudo -n -v` legitimately fails for a stretch in the middle. The 3-strike (~3 min) tolerance tripped and the keepalive sent SIGTERM to the very apt operation it was supposed to protect. Now: (a) failures are not counted while `/var/lib/dpkg/lock-frontend` is held — the foreground apt already has its credentials; (b) threshold raised from 3 to 15 (~15 min) so the safety net only fires when sudo is genuinely dead.

2026-04-07  Ryan Musante

- Tagged as v8.0.7
- fix(HIGH): step 2 dropped the redundant `apt-get upgrade` that preceded `apt-get full-upgrade`. On a bookworm→trixie codename transition `upgrade` keeps back ~160 packages because it cannot add/remove, so the work was redone seconds later by `full-upgrade`. The wasted ~4 min of duplicate dpkg activity caused the in-container wall-clock SIGTERM observed at +4m20s.
- fix(MED): step 2 now emits a prominent WARN at completion recommending `Shut down Linux` from the ChromeOS shelf before resuming. Trixie dist-upgrade replaces libc6/dbus/systemd under the running container (dpkg itself prints `A reboot is required to replace the running dbus-daemon`); subsequent steps in the same session can interact with stale long-running processes.

2026-04-07  Ryan Musante

- Tagged as v8.0.6
- fix(LOW): cleanup() now prints the correct "Verification failed — run --verify" message when an exit occurs inside step 11 or 12. `_had_failures` is snapshotted from `$_verify_fail` at the end of each verification step instead of only at step 13, closing a window where the trap saw `_had_failures=0` despite non-zero `_verify_fail` and fell through to the generic "resume from checkpoint" path.
- fix(LOW): bare `--force` (without `--reset`) now emits a warning instead of being silently consumed as a no-op. Catches typos like `--forced` collapsing to `--force`.
- cleanup(LOW): step 11's `$HOME/.local/bin` PATH injection moved inside the `should_run_step 11` guard. Previously ran unconditionally on every invocation including `--from-step=1..10` where it was wasted work.

2026-04-06  Ryan Musante

- Tagged as v8.0.5
- fix(MED): step 2a no longer hard-die()s on missing /etc/apt/sources.list. cp/sed gated on `[[ -f ]]`; deb822-only containers are handled by the *.sources loop.
- fix(LOW): version-marker self-heal greps switched to `grep -Fq` — `${SCRIPT_VERSION}` dots no longer interpreted as regex (5 user sites + earlyoom).
- fix(LOW): /etc/default/earlyoom gains `# ry-crostini:@@VERSION@@` marker, sed-substituted at write time. Self-heals on version bump instead of relying on a bare `'ry-crostini'` literal.
- fix(LOW): _LOCK_ACQUIRED set immediately after successful mkdir, before PID-file write. Closes the window where a signal would orphan the lock dir.
- fix(LOW): step 1o reuses cached AVAIL_MB from step 1e — one df invocation per step 1.
- doc(INFO): SC2031 disable annotations on the 4 main-shell sites tainted by the legitimate subshell at line 571.
- cleanup: dropped redundant `chmod 600` after mktemp in `_strip_log_ansi` (mktemp creates 0600).

2026-04-06  Ryan Musante

- Tagged as v8.0.4
- fix(HIGH): EARLYOOM_ARGS dropped literal single quotes around --prefer/--avoid regexes — systemd EnvironmentFile preserves inner quotes verbatim, so earlyoom regcomp'd "'(retroarch|...)'" and never matched. Prefer/avoid tuning was silently no-op since v7.9.8.
- fix(MED): step 13 sources ~/.config/environment.d/*.conf into the script shell before `systemctl --user import-environment` so MESA_LOADER_DRIVER_OVERRIDE / GSK_RENDERER / QT_QPA_PLATFORM are actually imported (no-args import-environment captures the calling shell's env, not environment.d files).
- fix(MED): apt 90parallel comment now matches behaviour ("retries + skip translations + per-scheme queue") — Pipeline-Depth=0 disables pipelining and Queue-Mode=access serializes per scheme; the "parallel/pipelining" claim was wrong.
- fix(MED): step 1d die()s on missing/empty VERSION_CODENAME instead of silently defaulting to "bookworm" — step 2a already aborted on the same condition; preflight is the right place to fail.
- fix(LOW): tmp.mount drop-in restores upstream `strictatime` and `nr_inodes=1m` (drop-in replaces Options entirely; the v8.0.0 cap was dropping these).
- fix(LOW): step 11 splits Qt5 verification into two distinct dpkg -s checks (qt5-gtk-platformtheme, adwaita-qt) — previous OR-fallback logged "Qt5 GTK platform theme ✓" when only adwaita-qt was installed.
- fix(LOW): self-healing version-marker idempotency on the 5 user files with `# ry-crostini:VERSION` markers (gpu.conf, pipewire gaming, pipewire-pulse gaming, wireplumber alsa, fontconfig fonts.conf). Upgraded users now receive content updates instead of stale 8.0.2 configs forever.
- fix(LOW): version markers in those 5 heredocs use `@@VERSION@@` placeholder, sed-substituted at write time (parity with run-x86 / gog-extract / run-game wrappers).
- fix(LOW): added a pre-scan loop for --help / --version that runs before LOG_FILE is touched; main arg-parse loop runs after touch+chmod 600 so any die() in arg-parse still gets a properly-mode-600 log file. --version now works in read-only $HOME and neither --help nor --version leave a stray log file behind.
- fix(LOW): run-game big-core detection accepts standard ARM Cortex-A76 (part 0xd0b) in addition to Qualcomm Kryo Gold (0x804), enabling affinity on RPi5 and other generic A76 hosts.
- doc(INFO): shellcheck SC2031 disable comments suppress 3 false positives where LOG_FILE is referenced from main shell after the legitimate subshell taint at line 571.

2026-04-06  Ryan Musante

- Tagged as v8.0.3
- fix(HIGH): sudo keepalive aborts loudly after 3 consecutive failures instead of silently spinning forever after credential expiry (was masking 30s apt-get sudo timeouts in main loop).
- fix(MED): write_file_sudo refuses to write through a symlink — `sudo test ! -L "$tmp"` guard between mktemp and tee (parity with ry-install).
- fix(MED): _write_file_impl gets the same symlink guard for $HOME writes.
- fix(MED): --reset now prompts for confirmation before deleting checkpoint+log; require --force in non-interactive mode.
- fix(MED): Trixie network probe gains `--retry 2 --retry-delay 1` (was single attempt, no retry, no fallback).
- fix(MED): remove redundant global `export DEBIAN_FRONTEND=noninteractive`; already re-exported per sudo callsite (sudo strips it via env_reset).
- fix(LOW): _handle_signal exits 128+N per POSIX (HUP=129, INT=130, QUIT=131, PIPE=141, TERM=143) instead of generic exit 1.
- fix(LOW): cleanup re-raise gains explicit signal allowlist (defence-in-depth against $_received_signal clobber).
- refactor(LOW): extract _read_os_release helper; consolidates 6 duplicate `. /etc/os-release` call sites.
- doc(LOW): clarifying comment on `set +e` in cleanup (safe — final code path before exit).
- doc(LOW): clarifying comment on subshell-local LOG_FILE in _parallel_check_tools (SC2030/2031 — not a clobber).

2026-04-05  Ryan Musante

- Tagged as v8.0.2
- fix: detect big cores dynamically via /proc/cpuinfo part 0x804.
- fix: note earlyoom restart side-effect in DRY-RUN message.
- clarify DYNACACHE=2 is a no-op on fresh install.
- Tagged as v8.0.1
- fix: exit 2 when --from-step=13 runs no verification checks.
- fix: track tmpfile in _SUDO_TMPFILE for cleanup trap.
- refactor: unify write_file variants into _write_file_impl.
- refactor: extract _gtk_settings_content (−12 lines duplication).
- add -- option terminator to run-x86, gog-extract, run-game.
- Tagged as v8.0.0
- gpu.conf: add GSK_RENDERER=ngl, MESA_SHADER_CACHE_DIR.
- gpu.conf: move MESA_NO_ERROR=1 to run-game wrapper.
- WirePlumber: remove disable-batch, headroom 8192→2048, period 256→512.
- PipeWire: max-quantum 1024→2048, add link.max-buffers=16.
- retroarch.cfg: audio_driver pipewire→alsa, latency 96→64.
- scummvm.ini: fix stretch_mode to pixel-perfect (hyphenated).
- earlyoom: -m 5→-m 10 (10% = 400 MB safer threshold).
- Xresources: Xft.dpi 120→96.
- remove LC_ALL export, keep only LANG.
- run-game: add MESA_NO_ERROR=1, mesa_glthread overridable.
- fontconfig: add lcdfilter=lcdnone.
- apt: keep apt-daily.timer, only disable apt-daily-upgrade.timer.
- umask 077→022 (single-user; write_file sets explicit chmod).
- remove all upgrade paths (−187 lines): clean-install only.
- Tagged as v7.9.9
- fix: atomic .box64rc rename via write_file_private.
- fix: guard earlyoom restart with DRY_RUN check.
- fix: pipe heredocs through sed before write_file_exec.
- fix: rewrite stty sane guard as if/then (SC2015).
- trim multiline comments to single line (−17 lines).
- Tagged as v7.9.8
- WirePlumber ALSA headroom 256→8192 (fixes audio glitches).
- box64: rename DYNAREC_CACHE→DYNACACHE; add 4 new flags.
- retroarch.cfg: add video_frame_delay=4; PipeWire warning.
- PipeWire: add cpu.zero.denormals=true.
- earlyoom: add -p, --prefer, --sort-by-rss.
- journald: add RuntimeMaxUse=50M, RuntimeMaxFileSize=10M.
- scummvm.ini: add output_rate=48000, interpolation=linear.
- bash: add set -E, inherit_errexit.
- refactor: version-marker gates replace elif chains (−66 lines).

2026-04-02  Ryan Musante

- Tagged as v7.9.7
- fix: LOG_FILE readonly killed subshells — removed readonly.
- fix: umask 077 created mode-700 parent dirs; add chmod 755.
- fix: inverted earlyoom config gate for fresh installs.
- fix: attempt systemctl start before is-active check.
- fix: stty sane in EXIT trap after sudo keepalive kill.
- Tagged as v7.9.4
- fix: add check_config for /etc/default/earlyoom (6/6 files).
- fix: renumber step 9 sub-labels; update parallel tool count.
- Tagged as v7.9.3
- parallel check_tool: ~42 concurrent probes.
- batch package installs, systemctl calls, dpkg-query.
- remove 7 redundant mkdir -p calls.
- fix: subshell stderr, tmpdir cleanup, batch systemctl warnings.
- Tagged as v7.9.2
- fix: 5-marker makeself validation for gog-extract.
- fix: verify heterogeneous CPU parts before big.LITTLE affinity.
- extract _pw_pulse_gaming_content (−heredoc duplication).

2026-04-01  Ryan Musante

- Tagged as v7.9.1
- README: update ScummVM, Moonlight Qt, Chiaki-ng, virgl, ChromeOS facts.

2026-03-31  Ryan Musante

- Tagged as v7.9.0
- retroarch.cfg: video_threaded false, input_poll_type_behavior=2.
- gpu.conf: remove mesa_glthread, GALLIUM_DRIVER.
- PipeWire quantum 256→512; new dosbox-x.conf.
- new run-game wrapper: big-core affinity, nice/ionice.
- earlyoom installed; disable man-db/fstrim/e2scrub timers.
- user file count 17→19.
- Tagged as v7.8.0 – v7.8.3
- fix: DRY_RUN guard on unrar install.
- sudo credential keepalive (60s loop).
- split verification into steps 11–13.

2026-03-30  Ryan Musante

- Tagged as v7.7.0 – v7.7.2
- remove --minimal flag and deprecated ChromeOS flags.
- Tagged as v7.6.0 – v7.6.4
- remove qt5ct, systemd v257 APT pin.
- Mesa shader cache, PipeWire mlock, WirePlumber ALSA tuning.
- fix: local-outside-function, non-atomic upgrades, nullglob.

2026-03-29  Ryan Musante

- Tagged as v7.5.0 – v7.5.1
- README restructured for GitHub readability.
- Trixie package fixes: 7zip, adwaita-qt.
- RetroArch native pipewire driver.

2026-03-28  Ryan Musante

- Tagged as v7.4.0 – v7.4.2
- remove all sysctl settings (read-only in Crostini).
- add ry-crostini-cros-pin.service.

2026-03-27  Ryan Musante

- Tagged as v7.0.0 – v7.3.0
- consolidate 15→11 steps, mandatory Trixie.
- switch RetroArch to native .deb; add DOSBox-X/unrar/unar.

2026-03-26  Ryan Musante

- Tagged as v6.0.0 – v6.0.1
- rename crostini-setup-duet5 → ry-crostini.
- Tagged as v5.0.0 – v5.5.0
- progress bar, qemu-user, run-x86/gog-extract wrappers, box64.

2026-03-19  Ryan Musante

- Tagged as v4.0.0 – v4.12.0
- dual-target Bookworm/Trixie, deb822 migration, PipeWire audio.

2026-03-15  Ryan Musante

- Tagged as v3.0.0 – v3.22.0
- run() pipefail fix, signal handling, --from-step, --verify.

2026-03-08  Ryan Musante

- Tagged as v2.0.0 – v2.9.0
- full rewrite: checkpoint resume, --dry-run, --interactive.
- Tagged as v1.0.0 – v1.1.0
- initial release.
