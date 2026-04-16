ry-crostini changelog

Note: line-number references in entries reflect the state at that version's commit. Subsequent edits shift the numbers; use `git show vX.Y.Z:ry-crostini.sh | sed -n 'LINE,+5p'` or search by function/step name if an audit trail is needed.

2026-04-15  v8.1.37
- Audit fixes. Exhaustive pass on v8.1.36 surfaced 0 HIGH, 0 MED, 3 LOW across the script; 0 across the docs. After re-verification, 8 initial findings were retracted (nice/ionice gate always passes; SECONDS/_START_EPOCH equivalent; trixie rollback idempotent; earlyoom write-vs-verify asymmetry intentional per v8.1.35; _pw_ready unset correct; XDG 0755 moot in single-user Crostini; mkdir applications already gated; README && chain correct per v8.1.36). Remaining real findings addressed below.
- LOW — L198 `_progress_resize` missing rows≥5 floor: `_progress_init` guards against terminals <5 rows but `_progress_resize` (SIGWINCH handler) did not — a resize to <5 rows emitted `\e[1;Nr` with N≤3 (DECSTBM bottom < safe minimum). On rows=1, the value collapsed to `\e[1;0r` (bottom < top), invalid per ECMA-48; xterm ignores it but other terminals may corrupt the scroll region. Fix: added `if [[ "$rows" -lt 5 ]]` guard that disables progress and resets the scroll region to the full window, mirroring `_progress_init`'s L158 guard.
- LOW — L93-99 cleanup `_SUDO_TMPFILE` path-prefix check: `sudo rm -f -- "$_SUDO_TMPFILE"` ran with no sanity check on the path. The variable is only set by `write_file_sudo` from `sudo mktemp "$(dirname "$dest")/.tmp_XXXXXXXX"`, so the present code was safe — but the variable is global and a future code path that mis-sets it would have full sudo file deletion. Fix: added `[[ "$_SUDO_TMPFILE" == */.tmp_* ]]` path-prefix gate before the `sudo rm`; refusal path warns via `_cleanup_warn`. Defense-in-depth only.
- LOW — L1917-1919 step 7 fontconfig fc-cache redundancy: fontconfig at L1949 aliases monospace → Fira Code, then fc-cache runs at L1957 — but `fonts-firacode` was first installed in step 8 (L2001). First-run fc-cache rebuilt without Fira Code; step 8's dpkg postinst then triggered a second ~5 s rebuild with the font present. Fix: pre-install `fonts-noto fonts-firacode` via `install_pkgs_best_effort` in step 7 before the fontconfig write. Step 8's identical install becomes a no-op (apt sees packages as already-installed). Idempotent.
- Condensing: removed double blank line between verify counter init and step 11 (L2609); merged consecutive `unset` statements (L3100-3101) into single line. Net -2 lines.
- README docs — Exit codes table: added signal exit rows (129/130/131/143 for SIGHUP/SIGINT/SIGQUIT/SIGTERM) and tightened exit 0 wording to match `--help` output ("Success — all steps completed, verification passed"). Prior README table only documented 0/1/2; readers integrating with CI or wrapper scripts missed the 128+N signal codes.
- README docs — Gaming Reference sections: annotated DOSBox-X references with bookworm fallback to vanilla `dosbox` in four places (§ intro, Compatibility Tiers table, Native ARM64 Emulators table, Game Launcher examples). Previously the bookworm/trixie binary split was only mentioned in the Installation Steps table (L174) and the v8.1.34 changelog; new readers scanning the Gaming Reference saw unqualified "DOSBox-X" references. Symmetric annotation for box64 added to the `run-game run-x86` example.
- Validation: `bash -n` clean; `shellcheck -x -s bash` unchanged (4 documented SC2030 notes). Line count: 3173 → 3184 (+13 fixes, -2 condensing = +11 net).

2026-04-14  v8.1.36
- Audit fixes. Exhaustive pass on v8.1.35 surfaced 3 HIGH, 6 MED, 14 LOW across the script; 0 HIGH, 2 MED, 10 LOW across the docs. After re-verification, 6 findings were retracted as non-issues (get_checkpoint empty-file path, install_pkgs_best_effort batch semantics, _CHECKPOINT_OVERRIDE sticky-by-design, SOH sentinel collision, cleanup re-raise via `kill $$`, logprintf variable-format contract). Remaining real findings addressed below.
- HIGH — L547-L600 `_parallel_check_tools` teardown race: on SIGINT during `wait`, cleanup() rm -rf'd `$_PARALLEL_TMPDIR` out from under still-running children, leading to ENOENT spam on every printf from backgrounded check_tool subshells that outlived the parent. Fix: added global `_PARALLEL_PIDS` array populated post-dispatch and cleared after `wait`; cleanup() now kills + waits on those pids before unlinking the tmpdir. Closes the race window.
- HIGH — L548-L557 `_PARALLEL_TMPDIR` exposure not atomic with mktemp -d: a signal between the successful mktemp and the assignment would leak the dir (cleanup saw empty variable). Fix: moved the assignment immediately after the mktemp success branch with no intervening statements, and updated the surrounding comment to note the invariant.
- HIGH — L674-L688 pre-scan argv loop did not honor the `--` end-of-options sentinel and did not detect `--reset`. Two defects: (1) `bash ry-crostini.sh -- --help` ran `usage` even though the main parser at the (unchanged) `--) break ;;` arm correctly stops option processing on `--`; (2) `--reset` passed through pre-scan and unconditionally created the log file at L685, which `--reset` then immediately rm'd one branch later — and on a read-only $HOME the L687 `exit 1` fired before `--reset` could run, making recovery impossible. Fix: added `--) break ;;` to the pre-scan case; added `--reset) _pre_reset=true ;;` alongside the help/version arms; guarded log-file creation on `! $_pre_reset`. The main parser's `--reset` handler is unchanged and its `rm -f -- "$LOG_FILE"` is now a no-op on a file that was never created.
- MED — L1013 step 1f warn message: `chrome://flags#crostini-gpu-support` missing the `/` between `flags` and `#`. Every other site in the script (L1047, L1051, L1056) and every site in README.md uses the canonical `chrome://flags/#crostini-gpu-support`. Cosmetic only — Chrome's omnibox accepts both forms and `open_chromeos_url` is never called with the broken form — but the warn string is copy-pasted by users into the address bar, and the inconsistency was noise. Fixed.
- MED — L1048-L1054 step 1i sommelier active-unit check: `list-units 'sommelier@*.service'` only matched the Wayland instance, not the `sommelier-x@` X11 bridge. A system running only the X11 bridge (rare but observed on `--from-step=2` recovery runs where sommelier.service didn't come up but sommelier-x.service did) logged "not yet active" incorrectly. Fix: added `'sommelier-x@*.service'` to the same list-units call, symmetric with the step 11 verification check at L2711 which already matched both.
- LOW — L2155 and L2313 `apt-cache policy` Candidate: parsing is locale-sensitive. On a container where the user's terminal set `LANG=de_DE.UTF-8` (or similar) before the script exports LANG via `/etc/profile.d/ry-crostini-env.sh` (which is only sourced at login, not by the current non-login bash process), `Candidate:` would be rendered as `Kandidat:` or localized variant, causing awk to return empty and the per-package unrar/box64 probes to silently skip the install. Fix: prefixed both calls with `LC_ALL=C apt-cache policy ...`. Probe is now locale-invariant.
- LOW — L2635 step 11 env.d parser did not trim leading whitespace before the blank/comment-line test, so an indented `    # comment` line passed the `\#*` glob test and leaked into the `env KEY=VAL glxinfo` argv (rejected downstream by the key-charset validator, but the inconsistency with the step 13 re-import parser at L3098-L3102 was real). Fix: added a leading-whitespace strip before the blank/comment test, mirroring the step 13 parser's whitespace handling.
- LOW — L2872-L2891 Qt theme package checks used `dpkg -s` which returns 0 for install/half-installed/half-configured/config-files states, potentially marking a broken install as ✓. Fix: replaced all four with `[[ "$(dpkg-query -W -f='${Status}' <pkg> 2>/dev/null)" == "install ok installed" ]]` exact-equality match. Symmetric with the step 6 pulseaudio dpkg-query check at L1671.
- LOW — L2787 shared-directory replay loop used unprefixed `d` as its loop variable, inconsistent with the project-wide `_name` convention for throwaway loop vars; `unset d` at L2793 cleaned it up but a future same-name variable in the enclosing scope would have silently shadowed. Fix: renamed `d` → `_d` throughout the loop and in the cleanup `unset`.
- README docs — Quick Start `sudo true; git clone ...; cd ry-crostini && bash ry-crostini.sh` changed to `sudo true && git clone ... && cd ry-crostini && bash ry-crostini.sh`. A failing `sudo true` (three wrong passwords) no longer leaves the user in `ry-crostini/` with no cached creds and a fresh internal-sudo prompt at the first apt call.
- README docs — Generated Files table: `.box64rc` and `dosbox-x/dosbox-x.conf` rows annotated `(trixie-only)` for readers scanning the table without the preamble.
- README docs — Cloud Gaming table: Amazon Luna split out to its own ⚠ Prime-only row noting the 2026-04-10 storefront/BYOL/third-party-subscription shutdown and the 2026-06-10 a-la-carte streaming sunset. Luna remains viable for Prime-tier and Luna Premium subscribers on the ~155-title catalogue.
- CHANGELOG — added a preamble note at the top of the file explaining that line-number references in historical entries reflect the state at each version's commit and drift with subsequent edits.
- Deliberately NOT applied from the audit:
  - MED — CHANGELOG historical line-number drift: re-verifying and rewriting every line number across 36 version blocks would be a multi-hour pass with no material benefit, since historical entries are snapshots and a reader inspecting them will be at the corresponding git revision anyway. Addressed via the preamble note instead.
  - LOW — step 13 env.d re-import runs unconditionally on `--verify`: gating on a "some env file changed this run" flag requires threading state through steps 5/6/7. Not worth the plumbing.
  - LOW — sudo keepalive `sleep 60` not interruptible: documented tradeoff; up-to-60s teardown latency after signal, otherwise would need a named pipe or signalfd.
  - LOW — `_handle_signal` `*) exit 1 ;;` default arm: dead under current trap set but defensive against future additions. No action.
  - LOW — `_audio_config_changed` and other step-local globals: would benefit from wrapping each step body in a function with `local` decls, but the checkpoint/step macro pattern is load-bearing and the refactor surface is large. Deferred indefinitely.
  - SC2030 ×4 notes at L565-566 — already documented inline as intentional (sentinel-line replay pattern); no action.
- Validation: `bash -n` clean; `shellcheck -x -s bash` unchanged (still 4 documented SC2030 notes, now at L565-566 after the inserted `_PARALLEL_PIDS` tracking code). Line count: 3157 → 3173 (+16 net: +12 for the cleanup-trap pid-kill block, +3 for the pre-scan sentinel/reset arms, +1 for the env.d whitespace-trim line).

2026-04-14  v8.1.35
- Audit fixes. Fresh exhaustive pass on v8.1.34 surfaced 7 LOW / 8 INFO findings; no HIGH or MEDIUM. All LOW findings addressed; selected INFO findings applied.
- LOW — L1211 bookworm-backports existence probe: regex `^[[:space:]]*(deb|URIs:)[^#]*bookworm-backports` correctly caught the one-line and deb822-URIs forms, but missed the deb822 case where `bookworm-backports` lives on the `Suites:` line (the normal layout — `URIs:` carries the mirror hostname only). Effect: a user who had already migrated backports to deb822 would trip a false-negative and the script would write a duplicate `bookworm-backports.list`. Fix: added `Suites:` branch → `^[[:space:]]*(deb|URIs:|Suites:)[^#]*bookworm-backports`. Empirically reproduced with a minimal deb822 fixture.
- LOW — L1219 `--upgrade-trixie` codename guard: the elif accepted any non-trixie non-empty codename (sid, unstable, bullseye, experimental), even though the rewrite path assumes the source is bookworm. Effect: rewriting sid→trixie would be a silent downgrade; bullseye→trixie would skip a release and leave broken package dependencies. Fix: explicit `elif [[ "$_cur_codename" == "bookworm" ]]` — any other non-trixie codename now falls through to the final `die` branch.
- LOW — L2091 `/etc/profile.d/ry-crostini-env.sh` `MAKEFLAGS`: set `-j${n}` with no load-average cap. On a 4 GB SC7180P, parallel C++ builds (e.g. rebuilding mesa, libvirglrenderer, or a box64 fork from source) could schedule more work than RAM allows and trigger the OOM killer before earlyoom's `--prefer` list reaps. Fix: `MAKEFLAGS="-j${_ry_nproc:-2} -l${_ry_nproc:-2}.0"`. The load-average cap tells make to stop spawning new jobs when the 1-minute load average exceeds the job count, which throttles before RAM exhaustion.
- LOW — L2929 earlyoom `--prefer` regex sanity re-check: step 11 verify accepted any `(\w|\w)` alternation, so a parenthesized-but-garbage value (e.g. `(foo|bar)`) would pass even though earlyoom would reap nothing useful. Fix: require at least one known gaming process name in the alternation → `\([^)]*(retroarch|wine|dosbox|dosbox-x|scummvm|box64)[^)]*\)`. Note step 3's write-time validation is left looser (it only needs to catch `--prefer` regex truncation from a bad sed substitution) because by construction the content it just wrote always contains a known name; the stricter check belongs in verify where the source of corruption is arbitrary.
- LOW — L3110 environment.d quote-strip: handled matched `"..."` / `'...'` pairs, but a lone opening quote (`"foo`, `bar'`) passed through with the quote intact and was exported as a literal. Low risk since files are script-written, but the parser is also designed to tolerate user-edited config. Fix: added a final `elif` that detects any remaining opening-or-closing quote and `continue`s the line, skipping malformed entries silently (matches the existing "skip pathological lines" convention).
- LOW — L1755, L3133 readiness-poll loops: `for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25` replaced with `for _i in {1..25}`. Style only; semantics identical. Used twice — PipeWire/WirePlumber restart poll in step 6 and sommelier restart poll in step 13.
- INFO — multi-line `#` comment blocks: v8.1.32 collapsed most wrapped-prose multi-line comments into single lines, but six two-line blocks survived. Collapsed into single lines this cycle: L281 `_strip_log_ansi` (mktemp + GNU-sed notes), L815 sudo keepalive rationale (now one 600-char line), L930 GTK 3/4 heredoc banner, L1831 GTK 2 heredoc banner, L2673 vulkaninfo parser note, L2717 configured-vs-live GTK read note. The top-of-file banner (L2-L12) is intentionally left structured — it is a visually-separated header, not wrapped prose, and collapsing it would push a single comment line past 1 kB. Total file comment-block regression surface is now zero consecutive `#` lines outside the banner and the `# shellcheck` directives.
- Deliberately NOT applied from the audit:
  - F7 — env.d parser de-duplication (L3091-3132 vs L2621-2635 gpu.conf-only parser): refactor touches two verification paths and warrants its own regression run. Deferred again, matching v8.1.34's deferral note.
  - INFO F4 — `_parallel_check_tools` bookworm/trixie tuple duplication (L2828-2839): the fork is a single 7-element vs 8-element literal array and any consolidation adds branch logic that outweighs the duplication cost. No action.
  - INFO F6 — `ry-crostini-cros-pin.service` ExecStart `mv` timestamp suffix (L1414): regeneration overwrite is the intended behavior on container restart, since ChromeOS rewrites `cros.list` with the current codename on every boot; preserving historical copies serves no debugging purpose. Documented here for reference; no code change.
  - SC2030 ×4 notes at L558-559 — already documented inline as intentional (sentinel-line replay pattern); no action.
- Validation: `bash -n` clean; `shellcheck -f gcc -s bash` unchanged (still 4 documented SC2030 notes at L558-559); `--version` and `--help` smoke-tested. F1 deb822 and F4 earlyoom stricter regex both verified empirically with positive and negative fixtures. Line count: 3162 → 3157 (−5 net: −6 from six comment-block collapses, +1 from F5 lone-quote elif).

2026-04-14  v8.1.34
- Audit fixes. Exhaustive double-checked audit of v8.1.33 surfaced 4 HIGH, 6 MEDIUM, 10 LOW/INFO findings. All HIGH and MEDIUM findings addressed; selected LOW findings applied.
- HIGH — wrapper shebangs (run-x86 L2368, gog-extract L2441, run-game L2525): first line was `# !/usr/bin/env bash ...` (comment with space between `#` and `!`), not a valid shebang. Kernel execve returned ENOEXEC; bash parents caught it and re-exec'd via bash (interactive use worked), but dash/sh parents ran the file in-place and died on `set -o pipefail` line 3. Broken contexts: systemd ExecStart (no shell fallback — "Exec format error"), cron, xdg-open, `system(3)`, Makefile recipes. Fix: line 1 is now exactly `#!/usr/bin/env bash`; the descriptive comment moved to line 2. Reproduced pre-fix with `dash -c './run-x86 ...'` → "Illegal option -o pipefail"; verified post-fix works under both dash and bash.
- HIGH — step 12 verify could not detect the shebang defect above. Added a `head -c2` check for `#!` on all three wrappers; failures increment `_verify_fail` and block checkpoint advance, matching the earlyoom regex sanity-check pattern.
- MEDIUM — RetroArch/ScummVM/DOSBox-X/.box64rc configs (L2159, L2210, L2238, L2323) used plain `[[ ! -f ... ]]` guards with no `ry-crostini:${SCRIPT_VERSION}` marker. Version bumps to these files (v8.1.29 aspect/rate, v8.1.31 fastforward/video_smooth, v8.1.31 box64 NATIVEFLAGS removal, etc.) silently did not apply to existing installs, contradicting the README "21 files self-heal" claim. Fix: added `ry-crostini:@@VERSION@@` markers to all four heredocs and switched guards to the standard self-heal pattern (`! -f || ! grep -Fq marker`). First-line comments now state "Re-written on version bump; manual edits below this line will be overwritten on script upgrade" — explicit contract change from v8.1.33's "edit freely afterward". Marker file count: 21 → 25 (22 configs + 3 wrappers).
- MEDIUM — L1210 `grep -rq "bookworm-backports" /etc/apt/sources.list /etc/apt/sources.list.d/` substring-matched any file content including `#` comments. A stray comment containing the literal string would silently suppress the backports enable, leaving pipewire/wireplumber on stock 0.4.x and voiding the WirePlumber JSON config at L1721 (JSON format requires WP ≥0.5). Fix: anchored to active lines via `grep -rEq '^[[:space:]]*(deb|URIs:)[^#]*bookworm-backports'`. Covers both one-line and deb822 formats; excludes trailing comments.
- MEDIUM — step 11 verify had no `check_file` for `/etc/apt/sources.list.d/bookworm-backports.list`. README §Generated Files listed it as a system artifact on the bookworm path. Fix: added `$IS_BOOKWORM && check_file ...` near L2846.
- LOW — L1041 step 1i sommelier detection: `systemctl --user is-active --quiet 'sommelier@*.service'` was dead code (is-active treats its argument as a literal unit name, no glob expansion). Dropped the dead branch; the `list-units` pattern path is kept as the sole check. Saves one fork per run.
- LOW — L1365 (tmp.mount.d override.conf) and L1403 (ry-crostini-cros-pin.service): marker-check grep used `sudo grep -Fq`, but both files are written mode 644 by `write_file_sudo`. Dropped the unnecessary `sudo`; now symmetric with L1168 (APT_PARALLEL).
- LOW — L1278 `_sfile_bak="/etc/apt/$(basename "$_sfile").pre-trixie"`: added `--` argument separator to `basename` for portability consistency with L1274.
- LOW — L282 `_strip_log_ansi` sed uses `\x1b` / `\x07` hex escapes (GNU sed extension). Added inline comment documenting the GNU sed dependency.
- Deliberately NOT applied from the audit:
  - L2617 / L3060 env.d parser duplication — deferred; refactor touches two verification paths and needs its own regression run.
  - L1273 Trixie `<codename>-updates` rewrite behavior — documented here for reference; no code change (the word-boundary regex correctly rewrites `bookworm-updates` → `trixie-updates`, which is the desired behavior).
  - SC2030 ×4 notes at L558-559 — already documented inline as intentional (sentinel-line replay pattern); no action.
- Retracted from v8.1.33 audit first pass (incorrect on re-read): `run()` re-entrancy concern (local scoping handles it correctly), L1518 earlyoom missing `2>/dev/null` (short-circuited by the preceding `! -f` test — grep never runs on missing file).
- Validation: `bash -n` clean; `shellcheck -S style` unchanged (still 4 documented SC2030 notes at L558-559). Line count: 3140 → 3162 (+22 net — 12 for shebang split, 17 for verify shebang-check loop, 4 for marker guards, −11 for other).

2026-04-14  v8.1.33
- Audit fixes. All findings from exhaustive v8.1.32 audit addressed; no correctness/security/crash-path issues found, but several latent pipefail/SIGPIPE weaknesses and missing self-heal markers fixed.
- `get_checkpoint()` (L305): `val="$(cat "$STEP_FILE" 2>/dev/null)"` → `{ read -r val < "$STEP_FILE"; } 2>/dev/null || { warn ...; }`. Eliminates cat fork on cold-start checkpoint read. NOTE: `$(<file)` cannot be used here — `inherit_errexit` (set at L17) propagates the command substitution's redirection failure past the `||` guard, aborting the script on unreadable file. The `read` builtin avoids this because the redirection happens in the outer shell context, not in a subshell.
- Step 1p (L1144): `id -nG | tr | grep -qx` → `[[ " $(id -nG "$_ry_user") " != *" input "* ]]`. Eliminates pipefail/SIGPIPE fragility where `grep -q` closes stdin on first match and propagates 141 upstream, causing the non-matching branch to fire even when the user IS in the `input` group. Latent only because `id -nG` output fits the pipe buffer; fallback usermod -aG was idempotent.
- Step 6 (L1664): `dpkg -l pulseaudio | grep -q '^ii'` → `[[ "$(dpkg-query -W -f='${Status}' pulseaudio 2>/dev/null)" == "install ok installed" ]]`. Same pipefail/SIGPIPE pattern eliminated; also replaces loose `^ii` anchor with exact Status match.
- Step 11 verification readback (L2706, L2728): `grep … | head -1 | cut -d= -f2 || echo default` → `awk -F= '/^gtk-theme-name/{print $2; exit}' … || echo default`. Single awk pass — no pipeline. Previous pattern could produce `<real-value>\ndefault` as the captured string under SIGPIPE (reproduced empirically at 100k-match scale); harmless in practice because real config files contain exactly one matching line per grep.
- Step 11 Xft.dpi readback (L2708): `grep | head -1 | awk` → single `awk '/^Xft\.dpi:/ {print $2; exit}'`. Same fragility pattern.
- Step 11 Vulkan parse (L2663-2664): `printf | grep | head -1 | cut | xargs -r` → single awk here-string with gsub trim. Same fragility pattern.
- Step 11 WirePlumber version probe (L2874): `timeout | grep | grep -oE | head -1` → `timeout | awk` single pass with `match()`.
- Step 11 pactl Server Name readback (L2751): `timeout | grep | cut | xargs -r` → `timeout | awk` single pass with sub() trim.
- Step 2f ry-crostini-cros-pin.service: dropped `DefaultDependencies=no`. The directive is intended for early-boot units (before sysinit.target), but the unit is `WantedBy=multi-user.target` which runs well after root-fs availability in Crostini. Nonstandard but harmless under the old directive — removed for correctness.
- Step 1 interactive prompts (6×): `read -r -t 300 _ </dev/tty` → `read -r -t 300 _unused </dev/tty`. Avoids writing to bash's reserved `$_` (last-arg placeholder); style only.
- Self-heal markers added to 9 files that previously checked only file existence: `sommelier.conf`, `gtk-3.0/settings.ini`, `gtk-4.0/settings.ini`, `.gtkrc-2.0`, `qt.conf`, `.Xresources`, `.icons/default/index.theme`, `tmp.mount.d/override.conf`, `ry-crostini-cros-pin.service`. Total self-heal count: 12 → 21 (18 configs + 3 wrappers). `.Xresources` uses `!` marker comment (X resource database convention); all others use `#`. Verified that the GTK `[Settings]`-header parser, the env.d KEY=VALUE parser at L3065-3099, and the gpu.conf env parser at L2612 all correctly skip the new comment lines.
- Empirical verification of all fixes under `set -euo pipefail` + `inherit_errexit`. SIGPIPE repro tests confirm fixed patterns no longer trigger pipefail propagation. bash -n and shellcheck -S style unchanged (4 documented SC2030 subshell notes).
- Line count: 3130 → 3140 (self-heal guards add ~10 lines net).

2026-04-14  v8.1.32
- Comments: collapsed wrapped multi-line `#` comment blocks to single lines throughout the script. `# shellcheck` directive lines kept standalone (required for recognition). 3181 → 3130 lines.
- Logging: `log`/`warn`/`err` now use `printf '%(%T)T' -1` bash 4.2+ builtin instead of forking `date +%T` per call. Eliminates O(N) forks across a full run (~100+ calls).
- `check_tool`: documented the `$flag` unquoted-expansion invariant (SC2086 suppression is safe because `$flag` is sourced exclusively from the `_TOOL_VER_FLAG` associative array or the hardcoded `--version` default).
- `_TOOL_VER_FLAG`: removed redundant `-g` from `declare -gA` (already at global scope).
- Sudo keepalive: `disown "$_SUDO_KEEPALIVE_PID"` → `disown` (no args = most-recent job, canonical per bash(1) JOB CONTROL).
- Step 1g: guard `curl` network probe with `command -v curl` check; curl is preinstalled on Crostini but the contract was unstated, and `--from-step=1` on a minimal container would have dereferenced a missing binary.
- Step 1h/1p: 6× `$(whoami)` forks replaced with `${USER:-$(id -un)}` (cached in `_ry_user` in step 1p). Handles edge case of unset `$USER` (sudo -i, cron) while eliminating redundant forks on the common path.
- Step 3: `bind9-host` split by codename — bookworm keeps `bind9-host`, trixie installs `bind9-dnsutils` (which provides `host(1)` after the bind9 package reshuffle).
- profile.d MAKEFLAGS: dropped inert `2>/dev/null` from `[ "${_ry_nproc:-2}" -gt 4 ]` (test builtin errors don't reach stderr for well-formed comparisons).
- Step 11 gpu.conf env parser: validate key charset (`^[A-Za-z_][A-Za-z0-9_]*$`) before passing to `env KEY=VAL glxinfo`. Defends against malformed config lines where the LHS contains whitespace or shell metachars.
- `usage()`: added EXIT CODES section documenting 0/1/2/129/130/131/143 — previously only discoverable by reading the source.
- Header Date: 2026-04-13 → 2026-04-14 (aligned with v8.1.31 CHANGELOG entry).

2026-04-14  v8.1.31
- Earlyoom: removed dead `-p` flag from EARLYOOM_ARGS. Debian earlyoom(1) manpage states `-p` is silently ignored when run through the default systemd service (which is how the script enables it). To actually protect earlyoom from the OOM killer, edit the systemd unit (`systemctl edit earlyoom`) and set `OOMScoreAdjust=-100`.
- Journald volatile.conf: added `MaxLevelStore=warning` (default `debug` floods 50 MB volatile cap with info/debug noise on a 4 GB system), `Compress=no` (volume already minimal under warning floor + 50 MB cap; saves CPU on Cortex-A55 efficiency cores), and `Audit=no` (audit subsystem unreachable in unprivileged Crostini LXC).
- RetroArch retroarch.cfg: added `config_save_on_exit = "false"` (upstream default true; prevents accidental overwrite of tuned settings via menu interaction), `fastforward_ratio = "3.0"` (upstream default 0.0=unlimited; uncapped fast-forward thermal-throttles SC7180P), `video_smooth = "false"` (upstream default true; nearest-neighbor for pixel-perfect retro on OLED), `video_scale_integer = "true"` (upstream default false; clean integer scaling).
- Box64 [default]: removed redundant `BOX64_DYNAREC_NATIVEFLAGS=1`. Verified against Debian Trixie 0.3.4 manpage — the default is already 1 ("Use native flags when possible. [Default]"). Explicit setting was a no-op.

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
