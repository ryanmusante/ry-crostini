ry-crostini changelog

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
