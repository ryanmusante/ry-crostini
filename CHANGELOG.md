ry-crostini changelog

2026-04-13  v8.1.22
- Step 1 gains sub-step 1p: adds `$USER` to the `input` group via `usermod -aG input`. Gamepad and joystick device nodes under `/dev/input/js*` and the corresponding `/dev/input/event*` nodes are created mode `660 root:input` by udev, so a user not in `input` gets `EACCES` from `open(2)` and RetroArch/DOSBox-X silently fall back to keyboard-only — no error message, just no controller. Idempotent: checks `id -nG` first and logs a no-op `already in 'input' group` on re-runs. Takes effect on next login (supplementary groups are latched at session start); README "Informational" table documents the Terminal restart requirement, mirroring the existing sommelier-not-running row. Warning branch handles the rare case where `usermod` itself fails (read-only /etc, immutable passwd db) without aborting the run.
- Step 3 CORE_PKGS: `bind9-host` and `iputils-ping` added to the network utilities group. Default Crostini images ship without `host(1)` and without `ping(8)` — the latter because it requires `CAP_NET_RAW` which the container can actually grant, just not pre-installed. Every troubleshooting procedure in the README and every `diag_network` entry in userPreferences assumes both commands are present; they now are. `bind9-host` is the modern replacement for the legacy `host` binary (the `dnsutils` metapackage pulls in `dig` and `nslookup` but no longer `host` as of bookworm).
- Step 3 earlyoom `EARLYOOM_ARGS`: `-s 10` → `-s 100` and `-r 3600` removed. The `-s` flag is the swap-free *percentage* threshold for SIGKILL (not SIGTERM — that's `-m`), and `-s 10` meant "start SIGKILL'ing when swap is ≥ 90% full", which on a 4 GB container with zram often triggered on legitimate compile jobs and Chromium tabs before the kernel's own oom_reaper got a chance. `-s 100` disables the swap-based kill path entirely and leaves memory-pressure (`-m 10` = SIGTERM at 90% RAM used) as the sole trigger — appropriate for a RAM-constrained device where swap thrash is expected and not itself a failure mode. `-r 3600` (report interval) was producing hourly info lines in journald that the new volatile 50 MB cap (see v8.1.22 F07 below) cannot afford; earlyoom already logs every kill action regardless of `-r`, so dropping the periodic report loses no diagnostic signal.
- Step 5 GPU env block: pre-creates `~/.cache/mesa_shader_cache` with `mkdir -p` immediately after writing `gpu.conf`. Mesa lazy-creates the shader cache directory on first GL context creation, and on a fresh install step 10's `run-game` wrappers often launch RetroArch and DOSBox-X concurrently (via `&` in test runs, or user-initiated double-launch) — both daemons race to `mkdir` the same path and one loses with `EEXIST` on the intermediate `.cache/mesa_shader_cache.tmp.$PID` directory, producing a one-shot shader compile storm on the losing process's next cold start. Pre-creating the dir eliminates the race window entirely. `MESA_SHADER_CACHE_DIR` is already set in `_gpu_conf_content()` at line 873, so this is just backfilling the directory the env var already points at.
- Step 2 APT tuning (`/etc/apt/apt.conf.d/90parallel`): `Acquire::http::Pipeline-Depth` bumped from `0` (disabled) to `5`, config gained a `// ry-crostini:${SCRIPT_VERSION}` marker, and the write path converted to self-heal on version bump (mirrors the earlyoom/gpu.conf/profile.d/journald pattern). Pipeline-Depth was zeroed out years ago as a workaround for broken HTTP/1.1 proxies; modern deb.debian.org and the CachyOS-style `http2`-capable mirrors benefit from request pipelining, and Crostini's network stack is not behind any legacy proxy. Depth 5 is the APT documentation's recommended value for well-behaved mirrors. Heredoc converted from quoted (`<<'EOF'`) to unquoted (`<<EOF`) so `${SCRIPT_VERSION}` in the marker line expands at write time; the body contains no `$`, backtick, or backslash sequences that would break under expansion.
- Step 9 journald volatile config: `SystemMaxUse=50M` and `SystemMaxFileSize=10M` added alongside the existing `RuntimeMax*` caps, marker line added, self-heal on version bump. `RuntimeMaxUse` only governs `/run/log/journal` (volatile/tmpfs); if any future change flips `Storage=` away from `volatile` — or if a dpkg-installed drop-in does — the `SystemMax*` caps prevent `/var/log/journal` from silently growing to the journald default (10% of filesystem, capped at 4 GB) on a device with ≤ 32 GB eMMC. Defence in depth: the current config still uses `Storage=volatile` so `SystemMax*` is unreachable, but the floor is now set should that ever change. Same heredoc-quoting swap as F06.
- Step 9 profile.d `/etc/profile.d/ry-crostini-env.sh`: self-heal on version bump (marker check), and a new parallel-make block exports `MAKEFLAGS="-j${_ry_nproc}"` with `_ry_nproc = min(nproc, 4)`. The cap matches `BOX64_MAXCPU=4` and the big-core count on heterogeneous ARM SoCs (SC7180/FD618 Kryo 4× Gold + 4× Silver; step 10's `run-game` affinity logic already pins to the 4 big cores). Without a cap, `nproc` on an 8-core container under C++ compile (AUR build via pamac is a common next-step, kernel headers, or any `make -j$(nproc)` in `README.md` examples) peaks at 8 parallel `cc1plus` processes × ~500 MB RSS each = 4 GB working set = instant OOM-kill cascade on a 4 GB device. `nproc` is evaluated inside a quoted heredoc so it runs at every login, reflecting the current container CPU allocation (user may change it via chrome://os-settings/crostini) rather than the install-time value — the v8.1.22 profile.d file is portable across reallocations. Write path converted from single heredoc to `{ printf marker; cat <<'ENVEOF' ... ENVEOF; } | write_file_sudo` pattern (precedent: earlyoom at line 1499) so the marker line gets interpolation while the body stays literal.
- Comment trim pass (second, targeted). Fifteen multi-line prose comment blocks in the script body collapsed to single lines per v8.1.15 policy, skipping everything v8.1.16 re-wrapped and everything embedded in heredocs: the 25-line script header (diff/blame readability), the three wrapper-script headers inside `run-x86` / `gog-extract` / `run-game` heredoc bodies, the `_gpu_conf_content()` virtio_gpu override explainer (v8.1.20 rewrote that deliberately to prevent the v4.7.8 regression from recurring), and the new F03 parallel-make comment inside the profile.d heredoc body (ends up in the generated `/etc/profile.d/ry-crostini-env.sh` verbatim). Blocks collapsed: step 1 sommelier check (1044), Mesa shader cache pre-create (1610), audio-config-changed flag (1685), pipewire/wireplumber restart (1740), verify gpu.conf sourcing (2602), render-node accel check (2638), lavapipe demotion (2669), step 11 sommelier authority (2697), configured-vs-live readback (2709), Xft.dpi cross-check (2718), PipeWire audio chain (2909), earlyoom observe-only (2935), apt-daily.timer exact-match (2954), step 13 environment.d live-reload (3078), sommelier-readiness poll (3132). Net: 15 blocks, −59 lines (3162 → 3103). Shellcheck clean against baseline (2 pre-existing SC2030 info messages, unchanged).
- README Table of Contents converted to a GitHub-rendered ordered list with nested unordered sub-list under Gaming Reference — 13 numbered top-level entries (`1.` through `13.`) with 10 bulleted sub-entries beneath `Gaming Reference`. Matches the standard GitHub README convention (numbered top sections, nested bullets for subsections), scannable on both desktop and mobile, and renders correctly on github.com without HTML hacks. Anchors unchanged; validated all 25 against actual `##`/`###` header slugs post-conversion.

2026-04-09  v8.1.21
- Step 6 now restarts pipewire / pipewire-pulse / wireplumber after writing the three audio config files, gated on at least one of the units being currently active. Previously the script wrote the gaming-quantum override, the pulse-layer override, and the WirePlumber ALSA tuning to disk and moved on — running daemons continued with their pre-install config because PipeWire/WirePlumber only read `conf.d/*.conf` at startup. Every install since the audio tuning was added shipped the files but not the effect; users had to restart their terminal (or log out) before any of it took hold, and no documentation said so. Same class of bug as gpu.conf's `virgl`/`virtio_gpu` fix: written ≠ effective. Restart is guarded by a `_audio_config_changed` flag so re-runs that hit "up-to-date" on all three files don't needlessly drop audio. When triggered, the restart polls `systemctl --user is-active` on all three units (pipewire, pipewire-pulse, wireplumber) with a 5 s ceiling (0.2 s × 25) — matches the pattern used in step 13's sommelier restart and tolerates slow containers under eMMC contention. Three outcomes: restart+ready → `PipeWire/WirePlumber restarted — audio tuning is live`; restart+timeout → warn; none active → `tuning applies on next terminal restart` (normal on `--from-step` runs before the audio stack has come up).
- Step 11 GTK theme / Xft DPI / Font readback lines relabeled `(configured)` to signal that they report file content, not running runtime state. Previously the output implied live values — a user could read `Xft DPI: 96` and assume xrdb was actually serving that, when on a fresh install the merge may have been skipped (step 7 gates `xrdb -merge` on `$DISPLAY` being set, which often isn't on first run before sommelier has come up).
- Step 11 gains an `Xft DPI (live)` cross-check via `xrdb -query | awk '/^Xft\.dpi:/ {print $2; exit}'`. Three states: file matches live → ✓ pass; file differs from live → ⚠ warn with both values shown and a remediation hint (`restart terminal or re-run xrdb -merge`); Xft.dpi absent from xrdb entirely → ⚠ warn with a `xrdb -merge ~/.Xresources` command to fix. Only runs when `$DISPLAY` is set and `xrdb` is available — skipped gracefully on headless or pre-sommelier states. Complements v8.1.20's gpu.conf verify-sourcing: now both the GL renderer and the Xft DPI are verified against what the system is actually running, not just what's written to disk.

2026-04-09  v8.1.20
- `_gpu_conf_content()`: `MESA_LOADER_DRIVER_OVERRIDE=virgl` → `MESA_LOADER_DRIVER_OVERRIDE=virtio_gpu`. This is the fix for a silent software-rendering bug that has been present since v4.7.8. The Mesa DRI loader matches this env var against the loadable `<n>_dri.so` filename, not against the internal Gallium driver name. The Gallium driver for virtio-gpu is called "virgl" (that's the confusion), but the loadable module is `virtio_gpu_dri.so`. Setting the override to `virgl` causes Mesa to `dlopen("virgl_dri.so")`, which does not exist, and silently fall through to `swrast_dri.so` (llvmpipe). Confirmed on SC7180/FD618 Chromebook, kernel virtio_gpu with full `+virgl +edid +resource_blob +host_visible +context_init` capability, bookworm Mesa 22.3.6, DRI `.so` present at 23 MB: the loader was asking for a file that was never there. After the fix (and `sed -i 's/virgl$/virtio_gpu/'` on the existing `gpu.conf`), `glxinfo | grep renderer` reports `virgl (FD618)` — host-side freedreno accelerating Adreno 618 through virglrenderer, the architecturally correct path. Every game, emulator, and GL application on the affected systems has been running on CPU since v4.7.8; this restores hardware acceleration. gpu.conf is auto-rewritten on re-run via the existing version-marker mechanism (`grep -Fq "ry-crostini:${SCRIPT_VERSION}"` in step 5), so no separate migration shim is needed.
- Step 11 GPU verification now sources `~/.config/environment.d/gpu.conf` into a subshell before invoking `glxinfo` and `vulkaninfo`. systemd `environment.d` files are only loaded into user sessions at login, so the bash shell running ry-crostini.sh (which predates `gpu.conf`'s existence on a fresh install) never inherits `MESA_LOADER_DRIVER_OVERRIDE` or the other Mesa env vars. Without this sourcing, verify always ran the GL probe against stale parent-shell env and would have reported llvmpipe on a correctly-configured system until the user restarted their terminal — inverting the false-positive v8.1.19 was meant to eliminate. Parse gpu.conf manually (KEY=VALUE line-by-line, skip comments, expand `${HOME}`/`$HOME`) rather than `set -a; source` to avoid executing arbitrary heredoc content. `env "${_gl_env_args[@]}" glxinfo` / `env "${_gl_env_args[@]}" vulkaninfo` pass the parsed vars to the probe children. Empty-array expansion under `set -u` is safe in bash ≥ 5.0 (script requires bash ≥ 5.0). Verify now validates the configuration ry-crostini wrote, not the ambient shell state.
- Comment block above `MESA_LOADER_DRIVER_OVERRIDE` in `_gpu_conf_content()` rewritten to explain the Gallium-driver-name vs loader-name distinction that caused v4.7.8's mistake, so a future edit doesn't regress to `=virgl`.
- Step 11 Zink warning message updated: "virgl override not active" → "virtio_gpu override not active" to match the corrected env var value.

2026-04-09  v8.1.19
- Step 11 GPU verification: software rendering no longer passes silently. The render-node existence check (`[[ -e /dev/dri/renderD128 ]]`) was treated as proof of GPU acceleration, but a node can be present while the virtio-gpu host bridge is inactive (chrome://flags/#crostini-gpu-support disabled, missing full reboot after enable, host driver fault) — Mesa then falls back to llvmpipe (CPU). The Mesa-driver branch only flagged virgl/Zink and let llvmpipe/softpipe/swrast fall through with no warning. Confirmed in 142713.log: `Render node: ✓`, `GL renderer: llvmpipe`, `Vulkan GPU: llvmpipe`, two false passes, zero warnings. Replaced the if/elif with an explicit case covering virgl (✓), Zink (⚠), llvmpipe/softpipe/swrast/Software (✗ + remediation hint), empty (⚠), unknown (?).
- Step 11 Vulkan verification: lavapipe (Mesa software Vulkan) reports `deviceName=llvmpipe` and was being counted as success identical to a real GPU. Now demoted to a warning with explicit "(software — lavapipe)" annotation. SwiftShader also matched.
- Step 11 PipeWire-pulse check: was probing `pipewire-pulse.socket` only, which can be active (listening) while the daemon behind it is failed. Now requires both `.service` and `.socket` to be active for ✓; ⚠ if socket-only; ⚠ if neither. Catches the case where the pulse shim crashes but socket activation keeps the unit listed as healthy.
- Step 11 earlyoom check: removed the in-verify auto-restart side effect. Verification steps must observe state, not mutate it — silently `systemctl start`-ing earlyoom hid the underlying reason it died (OOM cascade, dpkg-managed restart, manual stop) and converted a real failure into a pass on the next probe. Inactive earlyoom is now ✗ (fail) with a `systemctl status earlyoom` hint, and the auto-start path is gone. Step 3's install-time enable+start remains the canonical activation point.
- Step 11 WirePlumber version regex: anchored on `libwireplumber|^wireplumber` before the `[0-9]+\.[0-9]+\.[0-9]+` extraction. Previously grabbed the first version-shaped triple anywhere in `wireplumber --version` output, which would silently misreport on a future banner change that printed libspa/glib/glibc versions ahead of the wireplumber version. Existing "unparseable" warning branch handles graceful degradation if upstream renames the keyword.
- Step 11 apt-daily.timer check: replaced `systemctl is-enabled apt-daily.timer &>/dev/null` (which returns 0 for enabled, static, alias, indirect, and enabled-runtime) with an exact `== "enabled"` string match. Mirrors the apt-daily-upgrade.timer == "masked" predicate two lines above and only credits a true persistent enable across reboots.

2026-04-09  v8.1.18
- Sommelier detection fixed on aarch64 Crostini. Steps 1, 11, and 13 all used `pgrep -x sommelier`, which does exact comm matching. On ARM Chromebooks sommelier is exec'd via `/opt/google/cros-containers/bin/../lib/ld-linux-aarch64.so.1 --argv0 /usr/bin/sommelier ...`, so the kernel `comm` field (capped at TASK_COMM_LEN=16, 15 chars + NUL) is `ld-linux-aarch6` — `pgrep -x sommelier` never matches and returns false on a perfectly healthy system. Observed in the wild: step 11 printed `Sommelier: ⚠ not running` at 14:27:24 while `systemctl --user status sommelier@0` reported `Active: active (running) since 14:27:25` one second later, and step 13 followed with a bogus `Sommelier restart failed — shut down Linux` banner. v8.1.16's poll-loop extension addressed the symptom (timing) but not the cause (wrong predicate). All three sites now use `systemctl --user list-units --state=active 'sommelier@*.service'` (steps 1, 11) and `systemctl --user is-active "${_somm_units[@]}"` (step 13 poll) — architecture-agnostic and authoritative. x86_64 behaviour unchanged since systemctl is-active is correct on both architectures.

2026-04-08  v8.1.17
- `_write_file_impl` and `write_file_sudo`: dead `[[ -L "$tmp" ]]` symlink check (always false on a freshly mktemp'd file — `mktemp` uses O_EXCL|O_CREAT and returns a regular file, never a symlink) replaced with a meaningful pre-mktemp `[[ -L "$dest" ]]` test that refuses to clobber an existing destination symlink. The check is hoisted above mktemp so signals between the two operations cannot leak a tmpfile. Comment "TOCTOU defence" was honest about intent but tested the wrong file.
- Step 2a: `bookworm-backports.list` source registration switched from `http://deb.debian.org` to `https://deb.debian.org`. APT signature verification is unaffected, but plaintext was inconsistent with the existing https preflight at line 1025 and discloses package fetch metadata to on-path observers.
- Step 10 `run-game` big-core part-ID detection broadened from `0x804|d0b` (Kryo Gold + Cortex-A76) to also recognize A77 0xd0d, A78 0xd41, X1 0xd44, A710 0xd47, X2 0xd48, A715 0xd4d, X3 0xd4e, A720 0xd80, X4 0xd81. SC7180P unaffected; non-SC7180P aarch64 hosts now actually receive the dynamic affinity the README documents.
- README Gaming Reference: `sed 's/ main$/ main non-free/'` non-free enable command rewritten as deb822-aware idempotent form with explicit `(^| )non-free( |$)` boundaries that correctly distinguish `non-free` from `non-free-firmware` (trixie default Components line). Legacy `.list` form documented separately for pre-modernize-sources bookworm.

2026-04-08  v8.1.16
- Step 10 wrapper marker idempotency fixed. Previous v8.1.15 sed substituted `v${SCRIPT_VERSION}` for the single `@@VERSION@@` token, so the marker line became `# ry-crostini:v8.1.15` while the grep guard searched for `ry-crostini:8.1.15` (no `v`) — match always failed and the wrappers were rewritten on every invocation. Split into two tokens: `@@VERSION@@` (marker, no prefix) and `@@VTAG@@` (printed --version output, with `v` prefix). Wrappers are now genuinely grep-gated.
- Step 2 cros.list backup `[[ -e $bak ]] || run sudo cp ... || true` no longer swallows cp failure. Replaced with explicit if/elif/warn so a failed backup is logged before sed proceeds (cros.list is regenerated by ChromeOS so warn, not die).
- Step 2 backup `cp` calls (sources.list, *.sources, cros.list, locale.gen) gained `--no-dereference --preserve=all` for parity with the symlink-refusal hardening in `_write_file_impl`.
- Step 3 `7zip` removed from CORE_PKGS and codename-gated: bookworm gets p7zip-full (provides /usr/bin/7z); trixie gets 7zip 24.x (ships /usr/bin/{7z,7za,7zr} natively). Eliminates the noisy WARN from the no-candidate `7zip` install attempt on bookworm.
- Step 9 locale generation now post-verifies `locale -a | grep -q '^en_US\.utf8$'` and warns on mismatch. Previously trusted only the locale-gen exit code; the sed at 1898 silently no-ops if the en_US.UTF-8 line in /etc/locale.gen doesn't begin with `# `.
- Step 13 sommelier restart replaced fixed `sleep 1` with a 0.2 s × 25 poll loop (5 s ceiling). Slow containers (eMMC contention, OOM recovery) sometimes need >1 s to re-establish the display socket and were emitting false-negative restart warnings.
- Script header and step-13 live-reload comment re-wrapped from 1248-char and ~1350-char single-line collapses (regression from the v8.1.15 comment-trim pass) into multi-line blocks. Diff/blame readability restored.
- Header sudo-call count corrected from "~70" to "~68" (actual: 68 occurrences).
- Run-game nice/ionice probe comment now documents that both syscalls share CAP_SYS_NICE in-kernel, so the single `nice -n -5 true` probe is sufficient.

2026-04-08  v8.1.15
- Step 2e: replaced broken `apt modernize-sources --help &>/dev/null` capability probe with `dpkg --compare-versions ge 2.9~`. The old probe always returned 0 because apt parses `--help` as a global option, causing a misleading WARN every step-2 run on bookworm.
- `run-x86`, `gog-extract`, `run-game` wrappers now carry `# ry-crostini:VERSION` markers and grep-gated re-write. SCRIPT_VERSION bumps now refresh wrappers; previously they permanently reported whichever version first installed them. (NOTE: this v8.1.15 change shipped broken — see v8.1.16 for the fix.)
- `--reset` lock-dir cleanup deferred until after y/N confirmation; "About to delete:" listing now includes the lock dir.
- Step 2 trixie codename rewrites gained first-backup-wins guards (`[[ -e $bak ]] || cp ...`) on `sources.list`, `cros.list`, and the `*.sources`/`*.list` loop.
- `_strip_log_ansi` sed pipeline gained DCS handler ahead of catch-all.
- Comment trim pass: all multi-line prose comment blocks collapsed to single lines incl. script header. Shellcheck directives and `ry-crostini:VERSION` markers preserved as standalone lines. Net 105 lines removed (3025 → 2920).

2026-04-08  v8.1.14
- Step 11/12 `set_checkpoint` calls gated on `_verify_fail==0`. Previously a re-run after step-11 verification failures would skip step 11, run only step 12's 4 file checks, and report a false COMPLETE banner.
- `_progress_resize` and `_progress_cleanup` carry `# shellcheck disable=SC2317,SC2329`.
- Step-13 environment.d parser consolidated from two passes into one.

2026-04-08  v8.1.13
- README condensed from 689 to 561 lines across five low-risk cuts (Troubleshooting collapsed, Quick Start tightened, Trixie Upgrade table trimmed, Usage section pared, Gaming Reference subsections folded into prose).

2026-04-08  v8.1.12
- README "What's new in 8.1.x" callout removed (redundant with this changelog). Restored inline `[changelog](CHANGELOG.md)` link in lead paragraph.

2026-04-08  v8.1.11
- README "First Run vs. Re-run" section removed (redundant with Design → Safety and Reliability table).
- Confirmed Uninstall / Rollback section in condensed 7-row footprint form.

2026-04-08  v8.1.10
- README rewritten. Added Troubleshooting section with 8 named failure modes, Uninstall / Rollback footprint table, Logs subsection, First Run vs. Re-run table, "What's new" callout, arch and platform badges, motivation paragraph, expanded Quick Start with `git clone`, sudo cache, and post-install Terminal restart. Documented `--force` flag, `run-game` env exports (MESA_NO_ERROR, mesa_glthread), and corrected mode 600 attribution to log file.

2026-04-08  v8.1.9
- Sudo keepalive `fuser /var/lib/dpkg/lock-frontend` guard replaced with `pgrep -x apt-get || pgrep -x apt || pgrep -x dpkg`. The fuser probe silently false-negatived on containers without psmisc (not installed until step 3), so on a fresh `--upgrade-trixie` first-run the keepalive aborted after ~15 min of transient `sudo -n -v` failures.
- Log file creation switched from `touch + chmod 600` to `( umask 077; : > "$LOG_FILE" )`.
- `PIPE` dropped from signal trap set; restores default bash SIGPIPE handling.
- Unconditional cros-* stale-hold sweep added before step 1.
- Step 2 "all holds released" log path fixed to branch on `$IS_BOOKWORM`.
- Step 3 earlyoom post-write validation: dropped unnecessary `sudo` from `grep -Eq`.
- Step 10/11 inline version probes raised from 3s to 5s.
- Step 8 gnome-disk-utility install switched to `install_pkgs_best_effort`.
- Step 11 earlyoom auto-restart routed through `run()`.
- Step 8/9 `run mkdir -p` calls replaced with plain `mkdir -p ... 2>>"$LOG_FILE"`.
- Step 2 trixie codename rewrites gained `\<...\>` word-boundary anchors.
- Step 13 `systemctl --user import-environment` errors routed to log + warn.

2026-04-08  v8.1.8
- Step 2 `VERSION_CODENAME` empty-check hoisted above `--upgrade-trixie` branch. `--from-step=2` skipped step 1 entirely; the prior empty-guard at step 2 only fired on non-empty invalid values.
- Step 2 trixie suite-rewrite loop now skips `*backports*` source files.
- Step 3 adds `psmisc` to CORE_PKGS.
- Steps 1/6/11 mic capture detection replaced with `_has_capture_dev` helper using `find /dev/snd -name 'pcmC*D*c'`.
- Step 13 environment.d parser fixes: blank-line check matches `^[[:space:]]*$`; surrounding single-quote stripping added.
- Step 10 `run-game` CPU-part grep anchored to `^CPU part[[:space:]]*:`.
- `check_tool` version-probe timeout raised from 3s to 5s.

2026-04-07  v8.1.7
- Step 10 `run-x86` arch fallback hardened: exits 2 with clear message instead of silently exec'ing box64 on non-x86_64 input.
- Step 10 `gog-extract` makeself marker check broadened to accept makeself ≥2.5 patterns (`offset=$(head`, `_offset_=`).
- Step 13 `import-environment` scoped to explicit keys parsed from `~/.config/environment.d/*.conf`; previously leaked all script-internal vars into the user session.
- Step 13 sommelier restart enumerates active instances via `systemctl --user list-units` instead of hardcoded `@0`.
- Step 9 `apt-daily-upgrade.timer` masked instead of disabled.
- Step 5 + step 11 glxinfo parse collapsed to a single awk pass.
- Step 7 `xrdb -merge` gated on `[[ -n "$DISPLAY" ]]`.
- Step 9 locale.gen sed pattern broadened to `^#[[:space:]]*`.
- Step 9 timer existence probe replaced with `systemctl cat &>/dev/null`.
- Step 10 `box64` install gated on `apt-cache policy` candidate probe.
- Step 10 `.box64rc` `BOX64_DYNACACHE` default flipped from 2 to 1 for fresh-install correctness.
- Step 11 dropped unnecessary `sudo` on `grep` of `/etc/default/earlyoom`.
- Step 11 silenced last SC2031 false positive.
- Step 2 `apt modernize-sources` probe replaced fragile `apt --help | grep` with `apt modernize-sources --help &>/dev/null` (later corrected in v8.1.15).
- Cached `command -v fdfind/batcat` results before symlinking; renamed `_had_nullglob` → `_nullglob_was_set` in deb822 loop.

2026-04-07  v8.1.6
- Step 11 Vulkan parse fixed: grep `deviceName` instead of `GPU name`. Previous code unconditionally reported Vulkan as not available even on systems where it worked.
- Step 11 RetroArch threaded check now warns on missing-line case.
- Step 11 WirePlumber version probe added; warns on < 0.5 (JSON config silently ignored).
- Step 11 `apt-daily.timer` complementary check added.
- Step 11 earlyoom `--prefer` regex re-validated at verify time.

2026-04-07  v8.1.5
- Removed `--dry-run` mode entirely. Flag, `DRY_RUN` global, arg parser case, usage row, README/Design table rows, and every `if $DRY_RUN` branch collapsed to live mode. Architecture mismatch in step 1a is now an unconditional `die`. Net 121 lines removed (2983 → 2862). Breaking change.

2026-04-07  v8.1.4
- Comment cleanup pass. Multi-line comment blocks joined into single lines (labeled-field blocks like the script header preserved); trailing inline comments hoisted above their code. Net 47 lines removed.
- Removed dead `--skip-trixie` no-op handler.
- Cleared stale historical references in `_tee_log` filter comment, step 2 hard-stop warn, and README `--upgrade-trixie` row.
- README System table corrected from 6 → 7 files (bookworm-backports.list write was never reflected).

2026-04-07  v8.1.3
- cleanup() no longer calls `wait` on the disowned sudo keepalive PID — pure dead code after `disown`.
- Old-log rotation now also sweeps orphaned `_strip_log_ansi` tmpfiles via second find on `*.log.strip_*`.
- retroarch.cfg, scummvm.ini, dosbox-x.conf, .box64rc now write at mode 644 via `write_file` instead of mode 600. Removed unused `write_file_private` helper.

2026-04-07  v8.1.2
- Step 13 live-reload of `~/.config/environment.d/*.conf` no longer corrupts values containing shell metacharacters. Previous `set -a; . "$f"; set +a` block ran each file through the bash parser, splitting `QT_QPA_PLATFORM=wayland;xcb` at the `;`. Replaced with explicit per-line KEY=VALUE parser.
- Removed unused `SKIP_TRIXIE` global.

2026-04-07  v8.1.1
- Step 3 earlyoom config write no longer corrupts `--prefer` regex. Previous `sed -e "s|@@PREFER@@|${_EOOM_PREFER}|"` template used `|` as delimiter while `_EOOM_PREFER` itself contained `|`. Fix: drop sed, build with `printf` + direct interpolation, validate with `grep -Eq` and `die` on malformed output.
- Step 2a bookworm-backports `.list` switched to `write_file_sudo`.
- Step 11 silent earlyoom auto-restart now routes stderr to log + emits `warn` on failure.
- `run-game` core-affinity parser validates `_big_cores` against `^[0-9]+(,[0-9]+)*$` before passing to `taskset -c`.
- Old log file rotation gated on `! $DRY_RUN`.
- README System and User generated-files tables document bookworm deltas.

2026-04-07  v8.1.0
- Bookworm becomes the primary target. Script stays on current codename by default and enables `bookworm-backports` for pipewire 1.4 / wireplumber 0.5; `bookworm`→`trixie` codename rewrite is opt-in via `--upgrade-trixie`. Bookworm gating added in steps 2/3/6/8/10/11/13 (skip /tmp tmpfs cap, vanilla dosbox in earlyoom prefer regex, p7zip-full for `7z`, pipewire+wireplumber refresh from backports, adwaita-icon-theme-full, vanilla dosbox in place of dosbox-x, skip box64/.box64rc/dosbox-x.conf, parallel verify dosbox check, gaming quick-test).
- `_did_trixie_rewrite` gate. Step 2 hard-stop only fires when sources were genuinely rewritten.

Older history archived. Idempotent atomic writes, checkpoint resume, parallel verification, `~/ry-crostini-YYYYMMDD-HHMMSS.log` (mode 600, rotated after 7 days).
