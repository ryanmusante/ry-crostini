# ry-crostini

[![version](https://img.shields.io/badge/version-8.1.30-blue)](CHANGELOG.md)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![bash](https://img.shields.io/badge/bash-5.0%2B-orange)](https://www.gnu.org/software/bash/)
[![arch](https://img.shields.io/badge/arch-aarch64-lightgrey)](#hardware)
[![platform](https://img.shields.io/badge/platform-Crostini-yellow)](#hardware)

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US). Provisions a fresh Debian container into a fully configured
desktop environment in a single unattended run. **Bookworm (Debian 12) is the
primary target**; the script automatically enables `bookworm-backports` for
modern PipeWire/WirePlumber and falls back to vanilla `dosbox` + `qemu-user`
where `dosbox-x` / `box64` are unavailable. Trixie (Debian 13) is supported
as a secondary target — already-trixie containers run the trixie path
unmodified, and bookworm containers can opt into the legacy
`bookworm`→`trixie` codename upgrade via `--upgrade-trixie`.

Built to replace 60+ ad-hoc `apt install` commands and a wiki page of
post-install tweaks with a single idempotent script that survives partial
runs, codename upgrades, and re-execution. Every configuration file is
checkpointed, every package install is best-effort, every destructive action
is reversible.

[changelog](CHANGELOG.md)

## Table of Contents

1. [Quick Start](#quick-start)
2. [Hardware](#hardware)
3. [Prerequisites](#prerequisites)
4. [Usage](#usage)
5. [Installation Steps](#installation-steps)
6. [Generated Files](#generated-files)
7. [Trixie Upgrade (optional)](#trixie-upgrade-optional)
8. [Design](#design)
9. [Known Limitations](#known-limitations)
10. [Troubleshooting](#troubleshooting)
11. [Uninstall / Rollback](#uninstall--rollback)
12. [Gaming Reference](#gaming-reference)
    - [Compatibility Tiers](#compatibility-tiers)
    - [Native ARM64 Emulators](#native-arm64-emulators)
    - [RetroArch Cores](#retroarch-cores)
    - [RetroArch CRT Shaders](#retroarch-crt-shaders)
    - [RetroArch Run-Ahead and Preemptive Frames](#retroarch-latency-reduction)
    - [x86 Translation](#x86-translation)
    - [Game Launcher](#game-launcher)
    - [GOG Games](#gog-games)
    - [Cloud Gaming](#cloud-gaming)
13. [License](#license)

## Quick Start

```bash
# 1. Enable Linux (Beta): Settings → Developers → Turn On
# 2. Enable flags → Reboot:
#      chrome://flags/#crostini-gpu-support → Enabled
#      chrome://flags/#exo-pointer-lock     → Enabled
# 3. Cache sudo, clone, run:
sudo true
git clone https://github.com/ryanmusante/ry-crostini.git
cd ry-crostini && bash ry-crostini.sh
# 4. Close and reopen the Terminal app when finished.
```

**Expect:** a bottom-pinned progress bar (steps 1–13), `sudo` credential
keepalive every 60 s, output mirrored to `~/ry-crostini-*.log` (mode 600,
7-day rotation), and on `--upgrade-trixie` first runs, a deliberate
**hard-stop with exit 0** after step 2 — re-run after `Shut down Linux`
from the ChromeOS shelf and the checkpoint resumes at step 3.

## Hardware

| Component | Detail |
|-----------|--------|
| SoC | Snapdragon 7c Gen 2 (SC7180P), aarch64 |
| GPU | Adreno 618 → virgl (paravirtualized) |
| RAM | 4 GB LPDDR4x |
| Storage | 128 GB eMMC |
| Display | 13.3″ 1920×1080 OLED |
| Container | Debian Bookworm arm64 (primary) or Trixie arm64, bash |

The script is tuned for the SC7180P specifically: `run-game` pins to the
Cortex-A76 big cores (6–7), `~/.box64rc` is sized for the L1/L2 cache, and
fontconfig assumes the OLED has no LCD subpixel stripe. On non-SC7180P
aarch64 hardware the wrapper falls back gracefully (dynamic core detection
via `/proc/cpuinfo`), but no other targets are tested.

## Prerequisites

1. ChromeOS updated to latest stable channel
2. Linux (Beta) enabled via Settings → Developers
3. Terminal application open

| Setting | Location | Required |
|---------|----------|----------|
| GPU support | `chrome://flags/#crostini-gpu-support` → Enabled → Reboot | Yes — provides `/dev/dri/renderD128`; GPU packages install regardless |
| Pointer lock | `chrome://flags/#exo-pointer-lock` → Enabled | Yes — enables mouse capture in games |
| Microphone | Settings → Developers → Linux → Microphone → On | Optional |
| Disk size | Settings → Developers → Linux → Disk size → 20–30 GB | Recommended — aborts below 2 GB, warns below 10 GB |
| Shared folders | Files app → right-click folder → Share with Linux | Optional — mounts at `/mnt/chromeos/` |
| USB devices | Settings → Developers → Linux → Manage USB devices | Optional |
| Port forwarding | Settings → Developers → Linux → Port forwarding | Optional |

The `--interactive` flag guides through each setting interactively.

## Usage

```
bash ry-crostini.sh [OPTIONS]
```

| Flag | Description |
|------|-------------|
| *(none)* | Unattended full install on the current codename (default = bookworm-primary) |
| `--upgrade-trixie` | Opt INTO `bookworm`→`trixie` codename rewrite in step 2. Triggers a mandatory container restart mid-script. No-op if already on trixie. |
| `--interactive` | Prompt for ChromeOS toggles |
| `--from-step=N` | Resume from step N (1–13; N=11 equivalent to `--verify`) |
| `--verify` | Run only steps 11–13 (verification and summary) |
| `--reset` | Clear checkpoint and lock file, restart from step 1 (prompts for confirmation) |
| `--force` | With `--reset`: skip confirmation prompt (required when stdin is not a tty) |
| `--help` | Display usage and step list |
| `--version` | Display version |
| `--` | Terminate option processing |

| Exit Code | Meaning |
|-----------|---------|
| `0` | All verification checks passed |
| `1` | Verification failure or fatal error |
| `2` | No verification checks executed (e.g. `--from-step=13` alone) |

The exit message distinguishes verification failures from mid-step fatal
errors. Verification failures preserve the checkpoint so that
`--verify` re-runs all checks (steps 11–13).

### Logs

| Property | Value |
|----------|-------|
| Path | `~/ry-crostini-YYYYMMDD-HHMMSS.log` (one file per invocation) |
| Mode | `0600` (born via `umask 077`) |
| Rotation | Files older than 7 days deleted automatically on next run |

Tail the active log: `tail -f ~/ry-crostini-*.log`

## Installation Steps

| Step | Category | Description |
|------|----------|-------------|
| 1 | Preflight | Architecture, bash ≥5.0, Crostini, Debian version, disk, GPU, network, root, sommelier, mic, USB, folders, ports, disk-resize; `--interactive` |
| 2 | System | APT tuning, man-db trigger disable, `bookworm-backports` enable (bookworm only), optional `bookworm`→`trixie` upgrade with `--upgrade-trixie`, cros package hold, deb822 migration, `/tmp` tmpfs cap (trixie only), cros-pin service |
| 3 | CLI tools | curl, jq, tmux, htop, wl-clipboard, ripgrep, fd, fzf, bat, earlyoom, `p7zip-full` on bookworm |
| 4 | Build tools | Build essentials and development headers |
| 5 | Graphics | Mesa, Virgl, Wayland, X11, Vulkan |
| 6 | Audio | PipeWire, ALSA, GStreamer codecs, pavucontrol, PipeWire gaming tuning, WirePlumber ALSA tuning. On bookworm, `pipewire-audio` + `wireplumber` are refreshed from `bookworm-backports` (unpinned — whatever backports ships at install time) so the JSON `.conf` is honored. |
| 7 | Display | Sommelier scaling, Super key passthrough, GTK 2/3/4, Qt platform themes, Xft DPI 96, fontconfig, cursor |
| 8 | GUI | xterm, session support, fonts, icons, `adwaita-icon-theme-full` on bookworm |
| 9 | Environment | Locale, journald volatile, timer cleanup, environment variables, XDG directories, PATH |
| 10 | Gaming | DOSBox-X (trixie) or vanilla `dosbox` (bookworm), ScummVM, RetroArch, FluidSynth soundfont, innoextract/GOG, unrar/unar, `box64` + qemu-user (trixie) or qemu-user only (bookworm), gaming configs, `run-game` launcher |
| 11 | Verify | Tools and configuration files |
| 12 | Verify | Scripts and assets |
| 13 | Summary | Verification summary and elapsed time |

## Generated Files

**System (7 files, requires sudo).** Default paths write 6: `tmp.mount.d/override.conf` is trixie-only, `bookworm-backports.list` is bookworm-only; union is 7.

| Path | Step | Purpose |
|------|------|---------|
| `/etc/apt/apt.conf.d/90parallel` | 2 | APT parallel download tuning, dpkg unsafe-io |
| `/etc/apt/sources.list.d/bookworm-backports.list` | 2 | bookworm-backports repo registration (bookworm-only) |
| `/etc/systemd/system/tmp.mount.d/override.conf` | 2 | Cap `/tmp` tmpfs at 512 MB (trixie-only) |
| `/etc/systemd/system/ry-crostini-cros-pin.service` | 2 | Remove stale `cros.list` on container start |
| `/etc/default/earlyoom` | 3 | earlyoom OOM killer tuning |
| `/etc/profile.d/ry-crostini-env.sh` | 9 | Locale, editor, pager, PATH (`~/.local/bin`) |
| `/etc/systemd/journald.conf.d/volatile.conf` | 9 | Journald volatile (RAM-only) |

**User (19 files).** On **bookworm**, only 17 are written — `dosbox-x.conf` and `.box64rc` are trixie-only (`dosbox-x` / `box64` not in bookworm repos).

| Path | Step | Purpose |
|------|------|---------|
| `~/.config/environment.d/gpu.conf` | 5 | EGL, Mesa virgl override, shader cache, GTK dark theme, GSK_RENDERER |
| `~/.config/environment.d/sommelier.conf` | 7 | Sommelier scaling, Super key passthrough |
| `~/.config/environment.d/qt.conf` | 7 | Qt 5/6 platform theme |
| `~/.config/pipewire/pipewire.conf.d/10-ry-crostini-gaming.conf` | 6 | PipeWire gaming quantum |
| `~/.config/pipewire/pipewire-pulse.conf.d/10-ry-crostini-gaming.conf` | 6 | PipeWire pulse VM override |
| `~/.config/wireplumber/wireplumber.conf.d/51-crostini-alsa.conf` | 6 | WirePlumber ALSA tuning |
| `~/.config/gtk-3.0/settings.ini` | 7 | Dark theme, Noto Sans 11pt, grayscale AA |
| `~/.config/gtk-4.0/settings.ini` | 7 | Dark theme, Noto Sans 11pt, grayscale AA |
| `~/.gtkrc-2.0` | 7 | GTK 2 dark theme |
| `~/.Xresources` | 7 | Xft DPI 96 |
| `~/.config/fontconfig/fonts.conf` | 7 | Font rendering (grayscale AA for OLED) |
| `~/.icons/default/index.theme` | 7 | Adwaita cursor theme |
| `~/.config/retroarch/retroarch.cfg` | 10 | glcore renderer, ALSA audio, 32 ms latency, refresh rate, frame delay, late input polling |
| `~/.config/scummvm/scummvm.ini` | 10 | OpenGL, pixel-perfect scaling, FluidSynth, chorus off |
| `~/.config/dosbox-x/dosbox-x.conf` | 10 | ARM64 dynarec, GPU rendering, 4:3 aspect, 48 kHz mixer, cycle tuning |
| `~/.box64rc` | 10 | SC7180P DynaRec + Wine tuning, FORWARD/PAUSE opts |
| `~/.local/bin/run-x86` | 10 | x86/x86\_64 binary dispatcher (box64 / qemu) |
| `~/.local/bin/gog-extract` | 10 | GOG installer extraction without Wine |
| `~/.local/bin/run-game` | 10 | CPU affinity + priority launcher; per-game `MALLOC_ARENA_MAX=2`, `MESA_NO_ERROR=1`, `mesa_glthread=true` (unsafe globally on virgl) |

## Trixie Upgrade (optional)

The default flow stays on the current codename. Pass `--upgrade-trixie` to
opt INTO the legacy `bookworm`→`trixie` codename rewrite. Already-trixie
containers are unaffected; the flag is a no-op there.

| Behavior | Detail |
|----------|--------|
| Default (no flag) | Stays on current codename. On bookworm, `bookworm-backports` is enabled and step 6 refreshes pipewire/wireplumber from it. No restart required. |
| `--upgrade-trixie` on bookworm | Step 2 rewrites APT sources, runs `apt full-upgrade`, then **hard-stops with exit 0**. Continuing in-session risks SIGTERM when dpkg replaces libc6/dbus/systemd. Re-run after `Shut down Linux`; resumes at step 3. |
| Codename replacement | Line-scoped: `deb`/`deb-src` in `.list` files, `Suites:` in deb822 `.sources` files. Comments preserved. |
| Package holds | Crostini lifecycle packages held during upgrade, unheld after. `cros-guest-tools` stays held on trixie (`cros-im` unavailable). |
| Backups | `.pre-trixie` suffix under `/etc/apt/` (flattened). |
| cros-pin service | Removes stale regenerated `cros.list` on container start. |
| deb822 migration | After `apt modernize-sources`, duplicate `cros.list` removed if `.sources` equivalent exists. |
| `/tmp` tmpfs cap | Trixie only — capped at 512 MB to prevent OOM on 4 GB RAM. Skipped on bookworm (disk-backed). |

## Design

### Safety and Reliability

| Property | Implementation |
|----------|----------------|
| Idempotent | Configuration files skip if already present; the 12 files with `ry-crostini:VERSION` markers (9 configs + 3 wrappers in `~/.local/bin/`) self-heal when SCRIPT_VERSION advances; marker comment syntax is file-format-appropriate (`//` for APT conf, `<!-- -->` for XML, `#` for all others) |
| Atomic writes | tmpfile + mv via `_write_file_impl`; modes 644 (config), 700 (executables in `~/.local/bin/`), 600 (log via `umask 077`) |
| Concurrent-safe | PID-based `mkdir` lock with stale detection |
| Checkpoint resume | Progress saved after each step to `~/.ry-crostini-checkpoint`; re-run continues from last completed step |
| No eval | `run()` passes `"$@"` directly; generated systemd unit uses `bash -c` for inline conditional only |
| Signal handling | Traps INT, TERM, HUP, QUIT; re-raises for correct 128+N exit code; sudo tmpfiles tracked for cleanup |
| Sudo keepalive | Background `sudo -v` loop every 60 s prevents credential timeout; killed in cleanup |

### User Experience

| Property | Implementation |
|----------|----------------|
| Unattended by default | All prompts auto-answered; `--interactive` restores them |
| Parallel verification | Step 11 tool checks run concurrently with ordered output replay |
| Colored output | Respects `NO_COLOR` |
| Progress bar | Bottom-pinned step counter with percentage; resize-aware (WINCH) |
| Logging | `~/ry-crostini-YYYYMMDD-HHMMSS.log` (mode 600; rotated after 7 days) |
| Elapsed time | Reported at completion |

## Known Limitations

**Blockers.**

| Limitation | Detail |
|------------|--------|
| Vulkan unavailable | virgl exposes OpenGL 4.3–4.6. `vulkaninfo` installs but no Vulkan device is enumerated; Vulkan-only apps will not run. |

**Constraints.**

| Limitation | Detail |
|------------|--------|
| sysctl read-only | All kernel tuning parameters (`fs.inotify.max_user_watches`, `vm.max_map_count`, etc.) are blocked by the ChromeOS Termina VM namespace. Writing to `/etc/sysctl.d/` has no effect from inside the container. |
| WirePlumber 0.5 format | WirePlumber 0.5+ uses JSON `.conf` files; Lua scripts in `~/.config/wireplumber/` are silently ignored. Trixie ships 0.5.8 natively; bookworm gets it via `bookworm-backports` (step 2). If backports refresh fails, stock 0.4.13 ignores the gaming JSON config and step 6 logs a WARN. |
| Steam is x86-only | Translation layers (box64/box86) exist but are not viable on 4 GB RAM + virgl. Use cloud gaming via the ChromeOS browser. |
| Flatpak not recommended for gaming | Triple sandbox overhead (ChromeOS → Termina VM → LXC → bubblewrap), Flatpak Mesa/Zink crashes, doubled RAM during install/update; all gaming targets available as native arm64 `.deb`. |
| `BOX64_DYNAREC_ALIGNED_ATOMICS` | Disabled globally (`=0`) — value `1` causes SIGBUS for any LOCK-prefixed opcode on unaligned data, which x86 programs routinely emit. Enable per-game after testing via `~/.box64rc` `[gamename]` section: `BOX64_DYNAREC_ALIGNED_ATOMICS=1`. |
| RetroArch PipeWire audio | Trixie ships RetroArch 1.20.0 whose PipeWire driver silently ignores `audio_latency` ([#17685](https://github.com/libretro/RetroArch/issues/17685)). Fixed in 1.21.0+. Default is `audio_driver = "alsa"` (routes through PipeWire ALSA compat layer with working latency control). Switch to `"pipewire"` after installing ≥ 1.21.0 from trixie-backports. |

**Informational.**

| Item | Detail |
|------|--------|
| Sommelier not running during install | Started by container login, not by shells. Step 1 logs informational; step 11 warns if still absent at completion. Close and reopen Terminal to resolve. |
| Controller access requires Terminal restart | Step 1p adds `$USER` to the `input` group (`/dev/input/js*`, `event*`, mode `660 root:input`). Group membership latches at session start — reopen Terminal (or run `newgrp input`) after first install. Re-runs are no-ops. |
| ChromeOS flag status | `#crostini-gpu-support`: Required (disabled by default since M131). `#exo-pointer-lock`: Required. |

## Troubleshooting

### GPU not active after install

Step 11 reports `Render node: ✗ NOT ACTIVE` or `glxinfo` shows `llvmpipe`.
Enable `chrome://flags/#crostini-gpu-support` and perform a **full
Chromebook reboot** (not just container restart) — the device node only
appears after a host reboot. Re-run `--verify` after reboot; no full
re-install needed.

### Trixie upgrade hard-stop

After `--upgrade-trixie` first run the script exits 0 with a "Shut down
Linux" message. This is mandatory: dpkg has just replaced
libc6/dbus/systemd under the running container. Right-click the Terminal
icon → **Shut down Linux**, wait 10 seconds, reopen Terminal, then
`bash ry-crostini.sh` — the checkpoint resumes at step 3.

### Lock held / "another instance is running"

Check `cat ~/.ry-crostini.lock/pid` and `ps -p $(cat ~/.ry-crostini.lock/pid)`.
If the PID is dead, `bash ry-crostini.sh --reset` clears the stale lock
and checkpoint (add `--force` for non-interactive). If genuinely held,
wait for the other instance.

### Audio: no devices

Step 11 reports `ALSA devices: ✗` or `PulseAudio: ⚠ not responding`.
First-run audio usually requires a container restart to expose `/dev/snd/`
— shut down Linux from the shelf and reopen.

### WirePlumber JSON config silently ignored on bookworm

Step 11 reports `WirePlumber version 0.4.13 — JSON config ignored — needs ≥ 0.5`.
The bookworm-backports refresh in step 6 failed. Fix:

```bash
sudo apt update
sudo apt -t bookworm-backports install pipewire-audio wireplumber
systemctl --user restart wireplumber
```

If `bookworm-backports` is missing entirely, re-run from step 2:
`bash ry-crostini.sh --from-step=2`.

### Sommelier not running

Step 11 warns `Sommelier: ⚠ not running`. Sommelier is started by container
login, not by shells — close and reopen the Terminal app. If still missing,
check `systemctl --user status sommelier@0`.

### earlyoom killing the wrong process

A game or terminal disappears with `Killed` in dmesg. Default `--prefer`
list is `retroarch|box64|wine|dosbox-x|scummvm` (vanilla `dosbox` on
bookworm). To exclude additional processes, edit `--avoid` in
`/etc/default/earlyoom` and `sudo systemctl restart earlyoom`. Re-validate
with `bash ry-crostini.sh --verify`.

## Uninstall / Rollback

There is no automated uninstaller. The supported reset is **`Settings →
Developers → Linux → Remove Linux development environment`**, which deletes
the entire container in seconds. The script is designed to be re-runnable
on a fresh container at any time, and this is the only way to undo a
Trixie codename upgrade (no in-place trixie→bookworm downgrade exists).

For reference, the script's footprint inside the container is:

| What | Where |
|------|-------|
| User configs (16) | `~/.config/{environment.d,pipewire,wireplumber,gtk-3.0,gtk-4.0,fontconfig,retroarch,scummvm,dosbox-x}/`, `~/.gtkrc-2.0`, `~/.Xresources`, `~/.box64rc`, `~/.icons/default/index.theme` |
| User wrappers (3) | `~/.local/bin/{run-x86,gog-extract,run-game}` |
| System configs (7) | `/etc/apt/apt.conf.d/90parallel`, `/etc/apt/sources.list.d/bookworm-backports.list`, `/etc/systemd/system/{tmp.mount.d/override.conf,ry-crostini-cros-pin.service}`, `/etc/default/earlyoom`, `/etc/profile.d/ry-crostini-env.sh`, `/etc/systemd/journald.conf.d/volatile.conf` |
| Trixie backups | `/etc/apt/*.pre-trixie` (flattened from original locations) |
| Masked timers | `apt-daily-upgrade`, `fstrim`, `e2scrub_all`, `man-db` |
| APT holds | `cros-guest-tools` (trixie only) |
| Runtime state | `~/.ry-crostini-checkpoint`, `~/.ry-crostini.lock/`, `~/ry-crostini-*.log` |

See [Generated Files](#generated-files) for the full per-file inventory
with step numbers and purposes.

## Gaming Reference

Step 10 installs DOSBox-X, ScummVM, RetroArch, FluidSynth GM soundfont,
innoextract, unar, box64 (x86\_64 DynaRec JIT), and qemu-user (i386/x86\_64
TCG). `unrar` (RARLAB, non-free) is attempted separately; `unar` is the
fallback. Default configs are written for RetroArch, ScummVM, box64, run-x86, and
gog-extract on first install.

### Compatibility Tiers

| Tier | Category | RAM | Examples |
|------|----------|-----|----------|
| Excellent | ScummVM, DOSBox-X | < 200 MB | Monkey Island, DOOM, Ultima |
| Good | RetroArch 8/16-bit cores | < 300 MB | NES, SNES, Genesis, GBA |
| Fair | RetroArch PSX/PSP | 300–500 MB | PS1 catalog, lighter PSP titles |
| Marginal | RetroArch N64, box64+Wine 2D | 500 MB–2 GB | May exhibit lag or trigger OOM |
| Not viable | Vulkan / D3D10+ / Steam | N/A | Use cloud gaming |

### Native ARM64 Emulators

| Emulator | Description | Configuration |
|----------|-------------|---------------|
| DOSBox-X | DOS emulator with save-states, PC-98, MT-32, and CJK support | `~/.config/dosbox-x/dosbox-x.conf` (ARM64 dynarec, OpenGL, 4:3 aspect, 48 kHz mixer, cycle tuning) |
| ScummVM | 325+ supported games via native engine reimplementations | `~/.config/scummvm/scummvm.ini` (OpenGL, pixel-perfect scaling, FluidSynth) |
| RetroArch | Multi-system frontend (native arm64 Debian package) | `~/.config/retroarch/retroarch.cfg` |

### RetroArch Cores

> The script installs `retroarch` and `retroarch-assets` only — **no libretro
> cores are pre-installed.** Install via Main Menu → Online Updater → Core Downloader.

| System | Core | Notes |
|--------|------|-------|
| NES | FCEUmm | Lightweight, accurate for 99% of titles |
| SNES | snes9x | Best performance-to-accuracy ratio on ARM64 |
| Genesis / Mega CD / SMS / GG | Genesis Plus GX | Single core covers four systems |
| GBA | mGBA | ARM64-optimized |
| PSX | pcsx\_rearmed | ARM NEON dynarec, software renderer (avoids virgl overhead) |
| N64 | mupen64plus-next | GLideN64 with GLES renderer; may struggle at 4 GB |
| PSP | PPSSPP | Install via RetroArch Online Updater |
| DS | melonDS DS | ARM64 builds confirmed (v1.1.8+) |
| Dreamcast | Flycast | ARM64 JIT; lighter titles at full speed |

### RetroArch CRT Shaders

Virgl's GLES profile limits shader complexity. Tested slang shaders (CRT-Royale and Mega Bezel require desktop GPU resources — do not use):

| Shader | Description | Overhead |
|--------|-------------|----------|
| CRT-Pi | Designed for Raspberry Pi; recommended starting point | Minimal |
| CRT-Potato | Tiled mask texture; extremely lightweight | Minimal |
| CRT-Easymode | Flat-display CRT simulation | Low |
| FakeLottes | CRT-Lottes tuned for low-power GPUs | Low |

### RetroArch Latency Reduction

Two techniques for 8-bit and 16-bit cores only (Quick Menu → Overrides → Save Core Override). **Do not enable for PSX, N64, PSP, DS, or Dreamcast.**

| Technique | Setting | Value | Note |
|-----------|---------|-------|------|
| Run-Ahead | `run_ahead_enabled` | `"true"` | Reruns core every frame |
| Run-Ahead | `run_ahead_frames` | `"1"` | |
| Run-Ahead | `run_ahead_secondary_instance` | `"false"` | Two-instance mode doubles RAM — never enable |
| Preemptive Frames (1.15+) | `preempt_enable` | `"true"` | Lower overhead; reruns only on input change |
| Preemptive Frames (1.15+) | `run_ahead_frames` | `"1"` | Requires deterministic frame state |

### x86 Translation

> **Warning:** x86 translation overhead consumes 500 MB–1 GB before the
> application loads. Not recommended for RAM-intensive titles.

| Tool | Installation | Performance | Notes |
|------|--------------|-------------|-------|
| box64 | Step 10 (official Debian package) | Fast — ARM64 DynaRec | x86\_64 only; tuned `~/.box64rc` written by step 10 |
| qemu-user | Step 10 | Slow — TCG JIT (~5–10× slower than box64) | Provides i386; binfmt transparent execution blocked in unprivileged Crostini |

The `run-x86` wrapper auto-detects ELF architecture and dispatches:
x86\_64 → box64 (preferred) → `qemu-x86_64`; i386 → `qemu-i386`; unrecognized
ELF → descriptive error + exit 2. Run `run-x86 --help` to list available backends.

**32-bit x86:** not installed by default. Use `box86` + armhf libs, or set
`BOX64_BOX32=1` in `~/.box64rc` `[default]` for box64's experimental Box32
mode (v0.3.2+, no armhf required). FEX-Emu is not warranted on 4 GB.

**Transparent `./x86_program` execution:** binfmt_misc is blocked in
unprivileged Crostini; requires a privileged container (`vmc container termina
x86 --privileged true` from crosh). Privileged containers have reduced security
isolation; the default `penguin` container is unaffected.

### Game Launcher

The `run-game` wrapper (`~/.local/bin/run-game`) pins to Cortex-A76 big cores
with elevated scheduling priority (`nice -n -5 ionice -c2 -n0 -t`), caps malloc arenas (`MALLOC_ARENA_MAX=2`),
and exports `MESA_NO_ERROR=1` + `mesa_glthread=true` per-game (unsafe globally
on virgl; omitted from `gpu.conf`):

```bash
run-game retroarch                     # RetroArch on big cores
run-game dosbox-x                      # DOSBox-X on big cores
run-game scummvm                       # ScummVM on big cores
run-game run-x86 ./some_x86_program    # Chain with x86 emulation
```

On non-SC7180P hardware, big cores are detected dynamically via
`/proc/cpuinfo` CPU part IDs. If none match, affinity is skipped and only
priority elevation applies.

### GOG Games

Step 10 installs `innoextract` and writes `~/.local/bin/gog-extract` for
extracting GOG installers without Wine.

**Windows installers** (`.exe`) — Inno Setup, unpacked natively including
multi-part `.bin` archives (`innoextract --gog` since v1.9):

```bash
gog-extract setup_monkey_island_1.0.exe              # extracts to ./setup_monkey_island_1.0/
gog-extract setup_monkey_island_1.0.exe ~/Games/MI    # extracts to ~/Games/MI/
# Game files land in the app/ subdirectory
```

**Linux installers** (`.sh`) — makeself archives:

```bash
gog-extract gog_baldurs_gate_enhanced_edition.sh       # extracts to ./gog_baldurs_gate_enhanced_edition/
# Game files land in data/noarch/game/
```

`unar` (step 10) handles standalone RAR4/RAR5 and multi-part archives.
`unrar` (RARLAB, non-free) requires adding `non-free` to APT sources first:

**deb822 format** (trixie default; bookworm after `apt modernize-sources`):

```bash
sudo sed -i -E '/^Components:/ { /(^| )non-free( |$)/!s/$/ non-free/ }' \
    /etc/apt/sources.list.d/debian.sources
sudo apt update && sudo apt install unrar
```

**Legacy `.list` format** (bookworm pre-modernize-sources; stock single-component only — edit by hand for `main contrib` etc.):

```bash
sudo sed -i '/^deb / s/ main$/ main non-free/' /etc/apt/sources.list
sudo apt update && sudo apt install unrar
```

[Heroic](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases)
is amd64-only (no native arm64). Alternative: download GOG `.sh` installers
from [gog.com](https://www.gog.com) directly.

### Cloud Gaming

| Priority | Client | Recommended | Notes |
|----------|--------|-------------|-------|
| 1 | ChromeOS browser (GeForce NOW, Xbox Cloud Gaming, Luna) | ✅ | Direct V4L2 hardware decode, no VM overhead |
| 2 | Android Moonlight app (Play Store) | ✅ | Hardware decode; optimal for Sunshine/GameStream hosts |
| 3 | Chiaki-ng (PS Remote Play) | ✅ | ARM64 Linux AppImage; native Crostini streaming client |
| — | Moonlight Qt | ⚠ No | arm64 `.deb` available but software decode only (no V4L2 hw accel) |
| — | Parsec | ✗ No | No ARM64 Linux support |
| — | Steam Link | ✗ No | No ARM64 Linux support |

## License

[MIT](LICENSE) — Copyright (c) 2026 Ryan Musante

Issues and pull requests: <https://github.com/ryanmusante/ry-crostini>
