ry-crostini changelog


8.0.2 (2026-04-05)

- fix: detect big cores dynamically via /proc/cpuinfo part 0x804.
- fix: note earlyoom restart side-effect in DRY-RUN message.
- clarify DYNACACHE=2 is a no-op on fresh install.

8.0.1 (2026-04-05)

- fix: exit 2 when --from-step=13 runs no verification checks.
- fix: track tmpfile in _SUDO_TMPFILE for cleanup trap.
- refactor: unify write_file variants into _write_file_impl.
- refactor: extract _gtk_settings_content (−12 lines duplication).
- add -- option terminator to run-x86, gog-extract, run-game.

8.0.0 (2026-04-05)

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

7.9.9 (2026-04-05)

- fix: atomic .box64rc rename via write_file_private.
- fix: guard earlyoom restart with DRY_RUN check.
- fix: pipe heredocs through sed before write_file_exec.
- fix: rewrite stty sane guard as if/then (SC2015).
- trim multiline comments to single line (−17 lines).

7.9.8 (2026-04-05)

- WirePlumber ALSA headroom 256→8192 (fixes audio glitches).
- box64: rename DYNAREC_CACHE→DYNACACHE; add 4 new flags.
- retroarch.cfg: add video_frame_delay=4; PipeWire warning.
- PipeWire: add cpu.zero.denormals=true.
- earlyoom: add -p, --prefer, --sort-by-rss.
- journald: add RuntimeMaxUse=50M, RuntimeMaxFileSize=10M.
- scummvm.ini: add output_rate=48000, interpolation=linear.
- bash: add set -E, inherit_errexit.
- refactor: version-marker gates replace elif chains (−66 lines).

7.9.7 (2026-04-02)

- fix: LOG_FILE readonly killed subshells — removed readonly.
- fix: umask 077 created mode-700 parent dirs; add chmod 755.
- fix: inverted earlyoom config gate for fresh installs.
- fix: attempt systemctl start before is-active check.
- fix: stty sane in EXIT trap after sudo keepalive kill.

7.9.4 (2026-04-02)

- fix: add check_config for /etc/default/earlyoom (6/6 files).
- fix: renumber step 9 sub-labels; update parallel tool count.

7.9.3 (2026-04-02)

- parallel check_tool: ~42 concurrent probes.
- batch package installs, systemctl calls, dpkg-query.
- remove 7 redundant mkdir -p calls.
- fix: subshell stderr, tmpdir cleanup, batch systemctl warnings.

7.9.2 (2026-04-02)

- fix: 5-marker makeself validation for gog-extract.
- fix: verify heterogeneous CPU parts before big.LITTLE affinity.
- extract _pw_pulse_gaming_content (−heredoc duplication).

7.9.1 (2026-04-01)

- README: update ScummVM, Moonlight Qt, Chiaki-ng, virgl, ChromeOS facts.

7.9.0 (2026-03-31)

- retroarch.cfg: video_threaded false, input_poll_type_behavior=2.
- gpu.conf: remove mesa_glthread, GALLIUM_DRIVER.
- PipeWire quantum 256→512; new dosbox-x.conf.
- new run-game wrapper: big-core affinity, nice/ionice.
- earlyoom installed; disable man-db/fstrim/e2scrub timers.
- user file count 17→19.

7.8.0 – 7.8.3 (2026-03-31)

- fix: DRY_RUN guard on unrar install.
- sudo credential keepalive (60s loop).
- split verification into steps 11–13.

7.7.0 – 7.7.2 (2026-03-30)

- remove --minimal flag and deprecated ChromeOS flags.

7.6.0 – 7.6.4 (2026-03-29 – 2026-03-30)

- remove qt5ct, systemd v257 APT pin.
- Mesa shader cache, PipeWire mlock, WirePlumber ALSA tuning.
- fix: local-outside-function, non-atomic upgrades, nullglob.

7.5.0 – 7.5.1 (2026-03-29)

- README restructured for GitHub readability.
- Trixie package fixes: 7zip, adwaita-qt.
- RetroArch native pipewire driver.

7.4.0 – 7.4.2 (2026-03-28)

- remove all sysctl settings (read-only in Crostini).
- add ry-crostini-cros-pin.service.

7.0.0 – 7.3.0 (2026-03-27)

- consolidate 15→11 steps, mandatory Trixie.
- switch RetroArch to native .deb; add DOSBox-X/unrar/unar.

6.0.0 – 6.0.1 (2026-03-26)

- rename crostini-setup-duet5 → ry-crostini.

5.0.0 – 5.5.0 (2026-03-24 – 2026-03-26)

- progress bar, qemu-user, run-x86/gog-extract wrappers, box64.

4.0.0 – 4.12.0 (2026-03-19 – 2026-03-24)

- dual-target Bookworm/Trixie, deb822 migration, PipeWire audio.

3.0.0 – 3.22.0 (2026-03-15 – 2026-03-19)

- run() pipefail fix, signal handling, --from-step, --verify.

2.0.0 – 2.9.0 (2026-03-08 – 2026-03-15)

- full rewrite: checkpoint resume, --dry-run, --interactive.

1.0.0 – 1.1.0 (2026-03-08)

- initial release.
