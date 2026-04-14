ry-crostini changelog

2026-04-13  v8.1.30
- `_has_capture_dev()`: replaced `find /dev/snd | grep -q` pipeline with glob loop. Pipefail-immune; covers all four call sites (steps 1, 6, 11).

2026-04-13  v8.1.29
- Box64 [default]: BOX64_DYNAREC_ALIGNED_ATOMICS 1→0 and BOX64_DYNAREC_DIRTY 1→0 (upstream USAGE.md: both can SIGBUS/crash; per-game only).
- Box64 [default]: BOX64_MAXCPU 4→0 (restore upstream default; run-game already taskset-pins to A76 big cores).
- APT: added `DPkg::Options:: "--force-unsafe-io"` to 90parallel; reduces eMMC write amplification.
- Earlyoom: re-added `-r 3600` to EARLYOOM_ARGS (default 1s report flooded the 50 MB volatile cap).
- profile.d MAKEFLAGS comment: dropped stale BOX64_MAXCPU=4 reference; -j4 cap is OOM protection.
- DOSBox-X (trixie): added `aspect=true` under [sdl] and `[mixer] rate=48000` (matches PipeWire quantum).
- WirePlumber ALSA: added `~alsa_input.*` match in 51-crostini-alsa.conf; virtio-snd capture PCMs were defaulted.
- RetroArch: audio_latency 64→32 ms; added `video_refresh_rate = "60.000000"` (required for DRC AV sync on virgl).
- run-game: added `-t` to ionice (Crostini eMMC may use 'none' scheduler).
- Journald volatile.conf: removed inert `SystemMaxUse`/`SystemMaxFileSize`; added `ForwardToSyslog=no`.

2026-04-13  v8.1.28
- README condensation pass (−11 lines, no content removed): step 6 inline version numbers, Generated Files intro, system/user prose, run-game/Atomic-writes cells, Vulkan/WirePlumber/Flatpak/Sommelier/Controller limitations.

2026-04-13  v8.1.27
- Fixed 4 README table separator rows with off-by-one dash counts (L235, L247, L375, L436). All 22 separators now match header-width+2.

2026-04-13  v8.1.26
- Gaming Reference intro: removed incorrect DOSBox-X from default-configs list (trixie-only; bookworm skips the write).

2026-04-13  v8.1.25
- README Gaming Reference condensed (−48 lines): RetroArch CRT shaders, Run-Ahead+Preemptive merged into Latency Reduction, x86 Translation tightened, Game Launcher CPU part-IDs removed (duplicated from script), GOG/Cloud Gaming tables merged.

2026-04-13  v8.1.24
- README Design table: marker notation corrected to `ry-crostini:VERSION` with note that comment syntax is file-format-appropriate (`//`, `<!-- -->`, `#`).
- README x86 Translation: documented third `run-x86` dispatch path (unrecognized ELF → exits 2).

2026-04-13  v8.1.23
- Step 2 trixie elif: renames leftover `bookworm-backports.list` to `.pre-trixie` before the rewrite loop. Loop skips `*backports*` files, so the bookworm list was silently surviving the upgrade and pinning bookworm packages on a trixie host.
- Step 11 `pactl info` probe wrapped in `timeout 5` to match the other 9 timeouted probes.
- Step 2: dropped dead `${_cur_codename:-unknown}` fallback (validation at L1201-1206 already dies on empty/malformed).
- Header sudo-call count corrected ~69 → ~60.
- profile.d parallel-make: hardened with `${_ry_nproc:-2}` defaults and `2>/dev/null` on the test.
- `check_config` renamed to `check_file` (already used for systemd units, soundfont blob, three wrappers). 27 callsites + def + docstring updated.
- Three `find … -printf '.' | wc -c` idioms replaced with `find … | wc -l` (steps 1, 6, 11).
- Step 8 `adwaita-icon-theme` comment rewritten to disambiguate "removed in trixie".
- README marker-file count corrected 9 → 12 files (predated v8.1.22 marker additions).
- README run-game big-core part-ID list expanded to 11 entries (matches v8.1.17 regex broadening).
- README footer copyright year aligned to LICENSE (2026).

2026-04-13  v8.1.22
- Step 1: new sub-step adds `$USER` to `input` group via `usermod -aG`. Idempotent (`id -nG` check). Without this, gamepad/joystick devices return EACCES and RetroArch/DOSBox-X silently fall back to keyboard-only.
- Step 3: added `bind9-host` and `iputils-ping` to CORE_PKGS (default Crostini ships neither; troubleshooting docs assume both).
- Step 3 earlyoom: `-s 10` → `-s 100` (disable swap-based kill path; appropriate for 4 GB + zram); `-r 3600` removed.
- Step 5: pre-creates `~/.cache/mesa_shader_cache` after writing gpu.conf. Eliminates concurrent-launch race between RetroArch and DOSBox-X on cold start.
- Step 2 APT 90parallel: `Pipeline-Depth` 0 → 5; added version marker; self-heal on bump.
- Step 9 journald: added `SystemMaxUse=50M` / `SystemMaxFileSize=10M` as defence-in-depth (currently unreachable under `Storage=volatile`).
- Step 9 profile.d: self-heal on bump; new parallel-make block exports `MAKEFLAGS="-j${_ry_nproc}"` with `min(nproc, 4)` cap (4 GB OOM protection).
- Comment trim pass (15 multi-line blocks → single lines, −59 lines). Skipped script header, three wrapper headers, `_gpu_conf_content()` virtio_gpu explainer, profile.d heredoc body.
- README ToC converted to GitHub-rendered ordered list with nested bullets under Gaming Reference.

2026-04-09  v8.1.21
- Step 6: restarts pipewire/pipewire-pulse/wireplumber after audio config writes, gated on `_audio_config_changed`. Without this, daemons kept pre-install config until terminal restart (written ≠ effective).
- Step 11: GTK theme / Xft DPI / Font readback lines relabeled `(configured)` to signal file content vs runtime state.
- Step 11: added `Xft DPI (live)` cross-check via `xrdb -query`. Three states: match (✓), differ (⚠ + remediation), absent (⚠ + `xrdb -merge` hint).

2026-04-09  v8.1.20
- `_gpu_conf_content()`: `MESA_LOADER_DRIVER_OVERRIDE=virgl` → `=virtio_gpu`. Fix for silent software-rendering bug present since v4.7.8 — Mesa DRI loader matches `<n>_dri.so` filename, not Gallium driver name. Loadable module is `virtio_gpu_dri.so`, not `virgl_dri.so`. Auto-rewritten via existing version marker; restores hardware acceleration on all affected systems.
- Step 11 GPU verify: sources `~/.config/environment.d/gpu.conf` into subshell before `glxinfo`/`vulkaninfo`. Manual KEY=VALUE parser (no `set -a; source`) to avoid arbitrary execution. Now validates configured state, not ambient shell.
- Comment block above `MESA_LOADER_DRIVER_OVERRIDE` rewritten to document the loader-vs-Gallium distinction.
- Step 11 Zink warning updated to match new env var value.

2026-04-09  v8.1.19
- Step 11 GPU verify: software rendering no longer passes silently. Replaced render-node-existence proxy with explicit case on Mesa renderer string (virgl ✓, Zink ⚠, llvmpipe/softpipe/swrast/Software ✗ + remediation, empty ⚠, unknown ?).
- Step 11 Vulkan: lavapipe (`deviceName=llvmpipe`) and SwiftShader demoted from ✓ to ⚠ "(software)".
- Step 11 PipeWire-pulse: now requires both `.service` and `.socket` active for ✓ (catches crashed daemon behind listening socket).
- Step 11 earlyoom: removed in-verify auto-restart side effect. Inactive earlyoom is now ✗ with status hint.
- Step 11 WirePlumber version regex: anchored on `libwireplumber|^wireplumber` before the version triple extraction.
- Step 11 apt-daily.timer: replaced `is-enabled &>/dev/null` with exact `== "enabled"` match.

2026-04-09  v8.1.18
- Sommelier detection fixed on aarch64 Crostini. Steps 1, 11, 13 used `pgrep -x sommelier`, but on ARM the kernel comm is `ld-linux-aarch6` (TASK_COMM_LEN=16) because sommelier is exec'd via the loader. All three sites now use `systemctl --user list-units 'sommelier@*.service'` / `is-active`. x86_64 unaffected.

2026-04-08  v8.1.17
- `_write_file_impl` / `write_file_sudo`: dead post-mktemp `[[ -L "$tmp" ]]` check replaced with meaningful pre-mktemp `[[ -L "$dest" ]]` (refuses to clobber destination symlink).
- Step 2a: `bookworm-backports.list` switched http → https for parity with existing preflight.
- Step 10 run-game big-core part-ID detection broadened from A76+Kryo Gold to A77/A78/X1/A710/X2/A715/X3/A720/X4 (10 IDs total).
- README Gaming Reference: non-free enable command rewritten as deb822-aware idempotent form with `(^| )non-free( |$)` boundaries (distinguishes from `non-free-firmware`).

2026-04-08  v8.1.16
- Step 10 wrapper marker idempotency fixed: v8.1.15 sed produced `ry-crostini:v8.1.15` while grep guard searched for `ry-crostini:8.1.15`. Split into `@@VERSION@@` (marker, no prefix) and `@@VTAG@@` (--version output).
- Step 2 cros.list backup: replaced `cp ... || true` with explicit if/elif/warn (no longer swallows cp failure).
- Step 2 backup `cp` calls: added `--no-dereference --preserve=all` for parity with `_write_file_impl` symlink-refusal hardening.
- Step 3: `7zip` codename-gated (bookworm: p7zip-full; trixie: 7zip 24.x). Eliminates noisy WARN on bookworm.
- Step 9 locale: post-verifies `locale -a | grep -q '^en_US\.utf8$'`.
- Step 13 sommelier restart: replaced fixed `sleep 1` with 0.2s × 25 poll (5s ceiling).
- Script header and step-13 comment re-wrapped after v8.1.15 collapse regression.
- run-game nice/ionice probe comment: documents shared CAP_SYS_NICE.

2026-04-08  v8.1.15
- Step 2e: replaced broken `apt modernize-sources --help &>/dev/null` probe with `dpkg --compare-versions ge 2.9~`.
- run-x86, gog-extract, run-game: added `# ry-crostini:VERSION` markers and grep-gated rewrite. (Shipped broken — see v8.1.16.)
- `--reset` lock-dir cleanup deferred until after y/N confirmation.
- Step 2 trixie rewrites: first-backup-wins guards on sources.list, cros.list, *.sources/*.list loop.
- `_strip_log_ansi` sed pipeline: added DCS handler ahead of catch-all.
- Comment trim pass: all multi-line prose blocks collapsed to single lines (−105 lines, 3025 → 2920). Shellcheck directives and version markers preserved.

2026-04-08  v8.1.14
- Step 11/12: `set_checkpoint` calls gated on `_verify_fail==0`. Fixes false COMPLETE banner after step-11 failures.
- `_progress_resize` / `_progress_cleanup`: added `# shellcheck disable=SC2317,SC2329`.
- Step 13 environment.d parser consolidated from two passes into one.

2026-04-08  v8.1.13
- README condensed 689 → 561 lines (Troubleshooting collapsed, Quick Start tightened, Trixie Upgrade table trimmed, Usage pared, Gaming subsections folded).

2026-04-08  v8.1.12
- README "What's new" callout removed (redundant with changelog); restored inline `[changelog](CHANGELOG.md)` link.

2026-04-08  v8.1.11
- README "First Run vs. Re-run" section removed (redundant with Design → Safety table).
- Confirmed Uninstall/Rollback in 7-row footprint form.

2026-04-08  v8.1.10
- README rewritten: Troubleshooting (8 named failure modes), Uninstall/Rollback footprint table, Logs subsection, "What's new" callout, arch/platform badges, motivation, expanded Quick Start. Documented `--force`, run-game env exports, mode 600 attribution.

2026-04-08  v8.1.9
- Sudo keepalive: `fuser` lock probe replaced with `pgrep -x apt-get || apt || dpkg`. fuser silently false-negatived on containers without psmisc, aborting keepalive after ~15 min on fresh `--upgrade-trixie`.
- Log file creation: `touch + chmod 600` → `( umask 077; : > "$LOG_FILE" )`.
- `PIPE` dropped from signal trap set.
- Unconditional cros-* stale-hold sweep added before step 1.
- Step 2: "all holds released" log path branches on `$IS_BOOKWORM`.
- Step 3 earlyoom: dropped unnecessary sudo on `grep -Eq`.
- Step 10/11 inline version probes raised 3s → 5s.
- Step 8: gnome-disk-utility switched to `install_pkgs_best_effort`.
- Step 11 earlyoom auto-restart routed through `run()`.
- Step 8/9: `run mkdir -p` → plain `mkdir -p ... 2>>"$LOG_FILE"`.
- Step 2 trixie rewrites: gained `\<...\>` word-boundary anchors.
- Step 13 `import-environment` errors routed to log + warn.

2026-04-08  v8.1.8
- Step 2: VERSION_CODENAME empty-check hoisted above `--upgrade-trixie` branch (prior guard didn't fire on `--from-step=2`).
- Step 2 trixie suite-rewrite loop: skips `*backports*` files.
- Step 3: added `psmisc` to CORE_PKGS.
- Steps 1/6/11: mic capture detection → `_has_capture_dev` helper.
- Step 13 environment.d parser: blank-line check matches `^[[:space:]]*$`; single-quote stripping added.
- Step 10 run-game CPU-part grep anchored to `^CPU part[[:space:]]*:`.
- `check_tool` version-probe timeout 3s → 5s.

2026-04-07  v8.1.7
- Step 10 run-x86 arch fallback: exits 2 with clear message instead of silently exec'ing box64 on non-x86_64 input.
- Step 10 gog-extract: makeself marker check broadened for ≥2.5 patterns.
- Step 13 import-environment: scoped to explicit keys parsed from environment.d (no longer leaks script-internal vars).
- Step 13 sommelier restart: enumerates active instances via `list-units` instead of hardcoded `@0`.
- Step 9 apt-daily-upgrade.timer: masked instead of disabled.
- Step 5 + 11 glxinfo parse collapsed to single awk pass.
- Step 7 `xrdb -merge` gated on `[[ -n "$DISPLAY" ]]`.
- Step 9 locale.gen sed broadened to `^#[[:space:]]*`.
- Step 9 timer existence probe → `systemctl cat &>/dev/null`.
- Step 10 box64 install gated on `apt-cache policy` candidate probe.
- Step 10 .box64rc: `BOX64_DYNACACHE` 2 → 1 for fresh-install correctness.
- Step 11: dropped unnecessary sudo on grep of `/etc/default/earlyoom`; silenced last SC2031 false positive.
- Step 2 apt modernize-sources probe via `--help &>/dev/null` (later corrected v8.1.15).
- Cached `command -v fdfind/batcat`; renamed `_had_nullglob` → `_nullglob_was_set`.

2026-04-07  v8.1.6
- Step 11 Vulkan parse: grep `deviceName` instead of `GPU name`. Previously reported Vulkan unavailable on working systems.
- Step 11 RetroArch threaded check: warns on missing-line case.
- Step 11 WirePlumber version probe added; warns on < 0.5 (JSON config silently ignored).
- Step 11 apt-daily.timer complementary check added.
- Step 11 earlyoom `--prefer` regex re-validated at verify time.

2026-04-07  v8.1.5
- Removed `--dry-run` mode entirely (flag, global, parser case, usage row, README rows, every branch). Step 1a arch mismatch now unconditional die. −121 lines (2983 → 2862). Breaking change.

2026-04-07  v8.1.4
- Comment cleanup pass: multi-line blocks joined to single lines (labeled-field blocks preserved); trailing inline comments hoisted. −47 lines.
- Removed dead `--skip-trixie` no-op handler.
- Cleared stale historical references in `_tee_log` filter, step 2 hard-stop warn, README `--upgrade-trixie` row.

2026-04-07  v8.1.3
- cleanup() no longer calls `wait` on disowned sudo keepalive PID.
- Old-log rotation also sweeps orphaned `_strip_log_ansi` tmpfiles via second find.
- retroarch.cfg, scummvm.ini, dosbox-x.conf, .box64rc now write at mode 644 via `write_file`. Removed unused `write_file_private` helper.
- README System table corrected 6 → 7 files.

2026-04-07  v8.1.2
- Step 13 environment.d live-reload no longer corrupts values with shell metacharacters. Replaced `set -a; . "$f"; set +a` with explicit per-line KEY=VALUE parser (was splitting `QT_QPA_PLATFORM=wayland;xcb` at the `;`).
- Removed unused `SKIP_TRIXIE` global.

2026-04-07  v8.1.1
- Step 3 earlyoom write: no longer corrupts `--prefer` regex (sed delimiter `|` collided with regex `|`). Replaced sed template with printf + interpolation; validates with `grep -Eq`.
- Step 2a bookworm-backports `.list` → `write_file_sudo`.
- Step 11 silent earlyoom auto-restart: stderr to log + warn on failure.
- run-game core-affinity parser: validates `_big_cores` against `^[0-9]+(,[0-9]+)*$` before passing to taskset.
- Old log rotation gated on `! $DRY_RUN`.
- README System/User generated-files tables document bookworm deltas.

2026-04-07  v8.1.0
- Bookworm becomes primary target. Script stays on current codename by default; enables `bookworm-backports` for pipewire 1.4 / wireplumber 0.5. `bookworm`→`trixie` rewrite is opt-in via `--upgrade-trixie`. Bookworm gating added in steps 2/3/6/8/10/11/13.
- `_did_trixie_rewrite` gate: step 2 hard-stop only fires when sources were genuinely rewritten.

Older history archived. Idempotent atomic writes, checkpoint resume, parallel verification, `~/ry-crostini-YYYYMMDD-HHMMSS.log` (mode 600, rotated after 7 days).
