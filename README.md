# ry-crostini

[![version](https://img.shields.io/badge/version-8.1.21-blue)](CHANGELOG.md)
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

- [Quick Start](#quick-start)
- [Hardware](#hardware)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Installation Steps](#installation-steps)
- [Generated Files](#generated-files)
- [Trixie Upgrade (optional)](#trixie-upgrade-optional)
- [Design](#design)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Uninstall / Rollback](#uninstall--rollback)
- [Gaming Reference](#gaming-reference)
  - [Compatibility Tiers](#compatibility-tiers)
  - [Native ARM64 Emulators](#native-arm64-emulators)
  - [RetroArch Cores](#retroarch-cores)
  - [RetroArch CRT Shaders](#retroarch-crt-shaders)
  - [RetroArch Run-Ahead](#retroarch-run-ahead)
  - [RetroArch Preemptive Frames](#retroarch-preemptive-frames)
  - [x86 Translation](#x86-translation)
  - [Game Launcher](#game-launcher)
  - [GOG Games](#gog-games)
  - [Cloud Gaming](#cloud-gaming)
- [License](#license)

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
| 6 | Audio | PipeWire, ALSA, GStreamer codecs, pavucontrol, PipeWire gaming tuning, WirePlumber ALSA tuning. On bookworm, `pipewire-audio` + `wireplumber` are refreshed from `bookworm-backports` (currently 1.4.2 / 0.5.8; unpinned — whatever backports ships at install time) so the JSON `.conf` is honored. |
| 7 | Display | Sommelier scaling, Super key passthrough, GTK 2/3/4, Qt platform themes, Xft DPI 96, fontconfig, cursor |
| 8 | GUI | xterm, session support, fonts, icons, `adwaita-icon-theme-full` on bookworm |
| 9 | Environment | Locale, journald volatile, timer cleanup, environment variables, XDG directories, PATH |
| 10 | Gaming | DOSBox-X (trixie) or vanilla `dosbox` (bookworm), ScummVM, RetroArch, FluidSynth soundfont, innoextract/GOG, unrar/unar, `box64` + qemu-user (trixie) or qemu-user only (bookworm), gaming configs, `run-game` launcher |
| 11 | Verify | Tools and configuration files |
| 12 | Verify | Scripts and assets |
| 13 | Summary | Verification summary and elapsed time |

## Generated Files

All configuration files are written atomically (tmpfile + mv). Existing files
are skipped to ensure idempotency. Executable wrappers in `~/.local/bin/` are
installed with mode 700.

**System (7 files, requires sudo).** The `tmp.mount.d/override.conf` row is
trixie-only (bookworm `/tmp` is disk-backed, not tmpfs). The
`bookworm-backports.list` row is bookworm-only (it pulls modern
PipeWire/WirePlumber). Both default code paths therefore write 6 system
files, and the union is 7.

| Path | Step | Purpose |
|------|------|---------|
| `/etc/apt/apt.conf.d/90parallel` | 2 | APT parallel download tuning |
| `/etc/apt/sources.list.d/bookworm-backports.list` | 2 | bookworm-backports repo registration (bookworm-only) |
| `/etc/systemd/system/tmp.mount.d/override.conf` | 2 | Cap `/tmp` tmpfs at 512 MB (trixie-only) |
| `/etc/systemd/system/ry-crostini-cros-pin.service` | 2 | Remove stale `cros.list` on container start |
| `/etc/default/earlyoom` | 3 | earlyoom OOM killer tuning |
| `/etc/profile.d/ry-crostini-env.sh` | 9 | Locale, editor, pager, PATH (`~/.local/bin`) |
| `/etc/systemd/journald.conf.d/volatile.conf` | 9 | Journald volatile (RAM-only) |

**User (19 files).** On **bookworm** only 17 of these are written —
`~/.config/dosbox-x/dosbox-x.conf` and `~/.box64rc` are trixie-only
(bookworm uses vanilla `dosbox` and falls back to `qemu-user`; `dosbox-x`
and `box64` are not in any bookworm repo).

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
| `~/.config/retroarch/retroarch.cfg` | 10 | glcore renderer, ALSA audio, frame delay, late input polling |
| `~/.config/scummvm/scummvm.ini` | 10 | OpenGL, pixel-perfect scaling, FluidSynth, chorus off |
| `~/.config/dosbox-x/dosbox-x.conf` | 10 | ARM64 dynarec, GPU rendering, cycle tuning |
| `~/.box64rc` | 10 | SC7180P DynaRec + Wine tuning, FORWARD/PAUSE opts |
| `~/.local/bin/run-x86` | 10 | x86/x86\_64 binary dispatcher (box64 / qemu) |
| `~/.local/bin/gog-extract` | 10 | GOG installer extraction without Wine |
| `~/.local/bin/run-game` | 10 | CPU affinity + priority game launcher; sets `MALLOC_ARENA_MAX=2`, `MESA_NO_ERROR=1`, `mesa_glthread=true` per-game (unsafe globally on virgl) |

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
|----------|---------------|
| Idempotent | Configuration files skip if already present; the 9 files with `# ry-crostini:VERSION` markers (6 configs + 3 wrappers in `~/.local/bin/`) self-heal when SCRIPT_VERSION advances |
| Atomic writes | tmpfile + mv for all configuration files via unified `_write_file_impl` (modes 644 for configs, 700 for executables in `~/.local/bin/`; the log file is 600 via `umask 077`) |
| Concurrent-safe | PID-based `mkdir` lock with stale detection |
| Checkpoint resume | Progress saved after each step to `~/.ry-crostini-checkpoint`; re-run continues from last completed step |
| No eval | `run()` passes `"$@"` directly; generated systemd unit uses `bash -c` for inline conditional only |
| Signal handling | Traps INT, TERM, HUP, QUIT; re-raises for correct 128+N exit code; sudo tmpfiles tracked for cleanup |
| Sudo keepalive | Background `sudo -v` loop every 60 s prevents credential timeout; killed in cleanup |

### User Experience

| Property | Implementation |
|----------|---------------|
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
| Vulkan unavailable | The virgl paravirtualized GPU exposes OpenGL 4.3+ (up to 4.6 depending on the ChromeOS host Mesa version). `vulkaninfo` installs and reports its version in verification, but no Vulkan device is enumerated. Vulkan-only applications will not run. |

**Constraints.**

| Limitation | Detail |
|------------|--------|
| sysctl read-only | All kernel tuning parameters (`fs.inotify.max_user_watches`, `vm.max_map_count`, etc.) are blocked by the ChromeOS Termina VM namespace. Writing to `/etc/sysctl.d/` has no effect from inside the container. |
| WirePlumber 0.5 format | Trixie ships WirePlumber 0.5.8 natively; bookworm gets the same version via `bookworm-backports` (enabled automatically by step 2). Both use JSON `.conf` files, not Lua scripts. User-created Lua configurations in `~/.config/wireplumber/` are silently ignored. If the backports refresh fails on bookworm, the stock 0.4.13 daemon will silently ignore the gaming-tuning JSON config and step 6 logs a WARN. |
| Steam is x86-only | Translation layers (box64/box86) exist but are not viable on 4 GB RAM + virgl. Use cloud gaming via the ChromeOS browser. |
| Flatpak not recommended for gaming | Triple sandbox overhead (ChromeOS → Termina VM → LXC → bubblewrap), Flatpak runtime Mesa compositor crashes (Zink regression), doubled RAM during install/update, and all gaming targets are available as native arm64 `.deb` packages. |
| `BOX64_DYNAREC_ALIGNED_ATOMICS` | Enabled globally (`=1`) — Cortex-A76 LSE atomics produce faster, smaller code. Programs with unaligned LOCK ops may SIGBUS; disable per-game via `~/.box64rc` `[gamename]` section: `BOX64_DYNAREC_ALIGNED_ATOMICS=0`. |
| RetroArch PipeWire audio | Trixie ships RetroArch 1.20.0 whose PipeWire driver silently ignores `audio_latency` ([#17685](https://github.com/libretro/RetroArch/issues/17685)). Fixed in 1.21.0+. Default is `audio_driver = "alsa"` (routes through PipeWire ALSA compat layer with working latency control). Switch to `"pipewire"` after installing ≥ 1.21.0 from trixie-backports. |

**Informational.**

| Item | Detail |
|------|--------|
| Sommelier not running during install | Sommelier (Wayland/X11 bridge) is started by the container login process, not inside a running shell. Step 1 logs this as informational; step 11 reports it as a warning only if still absent at completion. Close and reopen the Terminal to resolve. |
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
innoextract (GOG/Inno Setup extractor), unar (RAR4/RAR5 and multi-part
archive extraction), box64 (x86\_64 DynaRec JIT), and qemu-user (TCG
x86/x86\_64 + i386 emulation). `unrar` (RARLAB, non-free) is attempted
separately; if unavailable, `unar` is used as a fallback. Default
configuration files are written for RetroArch, ScummVM, box64, run-x86, and
gog-extract on first install.

### Compatibility Tiers

| Tier | Category | RAM | Examples |
|------|----------|-----|---------|
| Excellent | ScummVM, DOSBox-X | < 200 MB | Monkey Island, DOOM, Ultima |
| Good | RetroArch 8/16-bit cores | < 300 MB | NES, SNES, Genesis, GBA |
| Fair | RetroArch PSX/PSP | 300–500 MB | PS1 catalog, lighter PSP titles |
| Marginal | RetroArch N64, box64+Wine 2D | 500 MB–2 GB | May exhibit lag or trigger OOM |
| Not viable | Vulkan / D3D10+ / Steam | N/A | Use cloud gaming |

### Native ARM64 Emulators

| Emulator | Description | Configuration |
|----------|-------------|---------------|
| DOSBox-X | DOS emulator with save-states, PC-98, MT-32, and CJK support | `~/.config/dosbox-x/dosbox-x.conf` (ARM64 dynarec, OpenGL, cycle tuning) |
| ScummVM | 325+ supported games via native engine reimplementations | `~/.config/scummvm/scummvm.ini` (OpenGL, pixel-perfect scaling, FluidSynth) |
| RetroArch | Multi-system frontend (native arm64 Debian package) | `~/.config/retroarch/retroarch.cfg` |

### RetroArch Cores

> The script installs `retroarch` and `retroarch-assets` only — **no libretro
> cores are pre-installed.** Install the cores below via RetroArch's Online
> Updater (Main Menu → Online Updater → Core Downloader).

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

Virgl's GLES profile limits shader complexity. Tested slang shaders:

| Shader | Description | Overhead |
|--------|-------------|----------|
| CRT-Pi | Designed for Raspberry Pi; recommended starting point | Minimal |
| CRT-Potato | Tiled mask texture; extremely lightweight | Minimal |
| CRT-Easymode | Flat-display CRT simulation | Low |
| FakeLottes | CRT-Lottes tuned for low-power GPUs | Low |

CRT-Royale and Mega Bezel presets require desktop GPU resources and should not
be used on this hardware.

### RetroArch Run-Ahead

Enable per-core overrides for 8-bit and 16-bit systems only. Create a core
override (Quick Menu → Overrides → Save Core Override) with:

```
run_ahead_enabled = "true"
run_ahead_frames = "1"
run_ahead_secondary_instance = "false"
```

Two-instance run-ahead doubles RAM usage per core and must not be enabled on
this hardware. Do not enable run-ahead for PSX, N64, PSP, DS, or Dreamcast
cores.

### RetroArch Preemptive Frames

Preemptive Frames (RetroArch 1.15+) is a lower-overhead alternative to
Run-Ahead. It only re-runs core logic when input state changes. Enable
per-core for 8-bit and 16-bit systems only. Create a core override with:

```
preempt_enable = "true"
run_ahead_frames = "1"
```

Preemptive Frames requires deterministic frame state support — not all
cores qualify. Do not enable for PSX, N64, PSP, DS, or Dreamcast cores.

### x86 Translation

> **Warning:** x86 translation overhead consumes 500 MB–1 GB before the
> application loads. Not recommended for RAM-intensive titles.

| Tool | Installation | Performance | Notes |
|------|-------------|-------------|-------|
| box64 | Step 10 (official Debian package) | Fast — ARM64 DynaRec | x86\_64 only; tuned `~/.box64rc` written by step 10 |
| qemu-user | Step 10 | Slow — TCG JIT (~5–10× slower than box64) | Provides i386; binfmt transparent execution blocked in unprivileged Crostini |

The `run-x86` wrapper (`~/.local/bin/run-x86`) auto-detects ELF architecture
and dispatches: x86_64 → box64 (preferred) → `qemu-x86_64` (fallback when
box64 is unavailable, e.g. on bookworm); i386 → `qemu-i386`. Run
`run-x86 --help` to list available backends.

**32-bit x86:** not installed by default. Options: `box86` + armhf libs
(`dpkg --add-architecture armhf`), or set `BOX64_BOX32=1` in `~/.box64rc`
`[default]` for box64's experimental Box32 mode (v0.3.2+, no armhf
required). FEX-Emu requires a RootFS image and is not warranted on 4 GB.

**Transparent `./x86_program` execution:** binfmt_misc registration is
blocked in unprivileged Crostini. To enable it, create a privileged
container via `vmc container termina x86 --privileged true` from
`crosh` (`Ctrl+Alt+T` → `shell`), then `sudo apt install qemu-user
qemu-user-binfmt` inside it. Privileged containers have reduced security
isolation; the default `penguin` container remains unaffected.

### Game Launcher

The `run-game` wrapper (`~/.local/bin/run-game`) pins processes to the
Cortex-A76 big cores (6–7) with elevated scheduling priority and caps
glibc malloc arenas (`MALLOC_ARENA_MAX=2`) to reduce memory waste:

```bash
run-game retroarch                     # RetroArch on big cores
run-game dosbox-x                      # DOSBox-X on big cores
run-game scummvm                       # ScummVM on big cores
run-game run-x86 ./some_x86_program    # Chain with x86 emulation
```

On non-SC7180P hardware, the wrapper detects big cores dynamically via
`/proc/cpuinfo` CPU part IDs (Qualcomm Kryo Gold `0x804` or generic ARM
Cortex-A76 `0xd0b`). If neither is found, affinity is skipped and only
priority elevation applies.

In addition to affinity, the wrapper exports `MESA_NO_ERROR=1` (skips GL
error checking, ~5–10% CPU savings) and `mesa_glthread=true` (offloads GL
command batching to a worker thread). Both are unsafe globally on virgl
and intentionally omitted from `~/.config/environment.d/gpu.conf` — they
only apply per-game via this wrapper.

### GOG Games

Step 10 installs `innoextract` and writes the `gog-extract` wrapper
(`~/.local/bin/gog-extract`) for extracting GOG game installers on Linux
without Wine.

**Windows installers** (`.exe`) use Inno Setup. `innoextract` unpacks them
natively on ARM64, including GOG Galaxy multi-part `.bin` archives (handled
internally by `innoextract --gog` since v1.9):

```bash
gog-extract setup_monkey_island_1.0.exe              # extracts to ./setup_monkey_island_1.0/
gog-extract setup_monkey_island_1.0.exe ~/Games/MI    # extracts to ~/Games/MI/
# Game files land in the app/ subdirectory
```

**Linux installers** (`.sh`) are makeself archives:

```bash
gog-extract gog_baldurs_gate_enhanced_edition.sh       # extracts to ./gog_baldurs_gate_enhanced_edition/
# Game files land in data/noarch/game/
```

For standalone RAR extraction, `unar` (installed by step 10) handles
RAR4/RAR5 including multi-part archives. `unrar` (RARLAB, non-free) is
attempted separately; to enable it, add non-free to APT sources.

**deb822 format** (trixie default, and bookworm after `apt modernize-sources`).
Idempotent — appends `non-free` only if not already a standalone token, and
correctly distinguishes it from `non-free-firmware`:

```bash
sudo sed -i -E '/^Components:/ { /(^| )non-free( |$)/!s/$/ non-free/ }' \
    /etc/apt/sources.list.d/debian.sources
sudo apt update && sudo apt install unrar
```

**Legacy `.list` format** (bookworm pre-modernize-sources). The trailing-`main`
match only fits the stock single-component form; for any custom
`main contrib` etc., edit the file by hand:

```bash
sudo sed -i '/^deb / s/ main$/ main non-free/' /etc/apt/sources.list
sudo apt update && sudo apt install unrar
```

[Heroic](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases)
provides Linux `.deb` releases (amd64 only — no native arm64 build; could run
under box64 on Trixie but is untested on 4 GB RAM). Alternative: download GOG
`.sh` installers from [gog.com](https://www.gog.com) directly.

### Cloud Gaming

| Priority | Client | Notes |
|----------|--------|-------|
| 1 | ChromeOS browser (GeForce NOW, Xbox Cloud Gaming, Luna) | Direct V4L2 hardware decode, no VM overhead |
| 2 | Android Moonlight app (Play Store) | Hardware decode; optimal for Sunshine/GameStream hosts |
| 3 | Chiaki-ng (PS Remote Play) | ARM64 Linux AppImage; native Crostini streaming client |

**Not recommended inside Crostini:**

| Client | Issue |
|--------|-------|
| Moonlight Qt | arm64 `.deb` available (v5.0.0+) but software decode only in Crostini (no V4L2 hw accel) |
| Parsec | No ARM64 Linux support |
| Steam Link | No ARM64 Linux support |

## License

[MIT](LICENSE) — Copyright (c) 2024–2026 Ryan Musante

Issues and pull requests: <https://github.com/ryanmusante/ry-crostini>
