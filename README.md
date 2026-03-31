# ry-crostini

![version](https://img.shields.io/badge/version-7.8.3-blue?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![bash](https://img.shields.io/badge/bash-5.0%2B-orange?style=flat-square)

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US). Provisions a fresh Debian container into a fully configured
Trixie (Debian 13) desktop environment in a single unattended run. Bookworm
containers are upgraded to Trixie automatically during installation.

## Table of Contents

- [Quick Start](#quick-start)
- [Hardware](#hardware)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Installation Steps](#installation-steps)
- [Generated Files](#generated-files)
- [Trixie Upgrade](#trixie-upgrade)
- [Design](#design)
- [Known Limitations](#known-limitations)
- [Gaming Reference](#gaming-reference)
  - [Compatibility Tiers](#compatibility-tiers)
  - [Native ARM64 Emulators](#native-arm64-emulators)
  - [RetroArch Cores](#retroarch-cores)
  - [RetroArch CRT Shaders](#retroarch-crt-shaders)
  - [RetroArch Run-Ahead](#retroarch-run-ahead)
  - [x86 Translation](#x86-translation)
  - [GOG Games](#gog-games)
  - [Cloud Gaming](#cloud-gaming)
- [License](#license)

## Quick Start

```bash
# 1. Enable Linux (Beta): Settings → Developers → Turn On
# 2. Enable flags → Reboot:
#      chrome://flags/#crostini-gpu-support → Enabled
#      chrome://flags/#exo-pointer-lock     → Enabled
# 3. Run:
bash ry-crostini.sh
```

## Hardware

| Component | Detail |
|-----------|--------|
| SoC | Snapdragon 7c Gen 2 (SC7180P), aarch64 |
| GPU | Adreno 618 → virgl (paravirtualized) |
| RAM | 4 GB LPDDR4x |
| Storage | 128 GB eMMC |
| Display | 13.3″ 1920×1080 OLED |
| Container | Debian Trixie arm64, bash |

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
| *(none)* | Unattended full install (default) |
| `--interactive` | Prompt for ChromeOS toggles |
| `--dry-run` | Print commands without executing |
| `--from-step=N` | Resume from step N (1–13; N=11 equivalent to `--verify`) |
| `--verify` | Run only steps 11–13 (verification and summary) |
| `--reset` | Clear checkpoint and lock file, restart from step 1 |
| `--help` | Display usage and step list |
| `--version` | Display version |
| `--` | Terminate option processing |

| Exit Code | Meaning |
|-----------|---------|
| `0` | All verification checks passed |
| `1` | Verification failure or fatal error |

The exit message distinguishes verification failures from mid-step fatal
errors. Verification failures preserve the checkpoint at step 12 so a re-run
repeats only the summary (step 13).

> **Note:** The script invokes `sudo` internally. A background keepalive
> renews credentials every 60 s. Run `sudo true` before execution to cache
> the initial credential.

## Installation Steps

| Step | Category | Description |
|------|----------|-------------|
| 1 | Preflight | Architecture, bash ≥5.0, Crostini, Debian version, disk, GPU, network, root, sommelier, mic, USB, folders, ports, disk-resize; `--interactive` |
| 2 | System | APT tuning, Trixie upgrade, cros package hold, deb822 migration, `/tmp` tmpfs cap, cros-pin service |
| 3 | CLI tools | curl, jq, tmux, htop, wl-clipboard, ripgrep, fd, fzf, bat, and others |
| 4 | Build tools | Build essentials and development headers |
| 5 | Graphics | Mesa, Virgl, Wayland, X11, Vulkan |
| 6 | Audio | PipeWire, ALSA, GStreamer codecs, pavucontrol, PipeWire gaming tuning, WirePlumber ALSA tuning |
| 7 | Display | Sommelier scaling, Super key passthrough, GTK 2/3/4, Qt platform themes, Xft DPI 120, fontconfig, cursor |
| 8 | GUI | xterm, session support, fonts, icons |
| 9 | Environment | Locale, journald volatile, environment variables, XDG directories, PATH |
| 10 | Gaming | DOSBox-X, ScummVM, RetroArch, FluidSynth soundfont, innoextract/GOG, unrar/unar, box64, qemu-user |
| 11 | Verify | Tools and configuration files |
| 12 | Verify | Scripts and assets |
| 13 | Summary | Verification summary and elapsed time |

## Generated Files

All configuration files are written atomically (tmpfile + mv). Existing files
are skipped to ensure idempotency. Executable wrappers in `~/.local/bin/` are
installed with mode 700.

### System (5 files, requires sudo)

| Path | Step | Purpose |
|------|------|---------|
| `/etc/apt/apt.conf.d/90parallel` | 2 | APT parallel download tuning |
| `/etc/systemd/system/tmp.mount.d/override.conf` | 2 | Cap `/tmp` tmpfs at 512 MB |
| `/etc/systemd/system/ry-crostini-cros-pin.service` | 2 | Remove stale `cros.list` on container start |
| `/etc/profile.d/ry-crostini-env.sh` | 9 | Locale, XDG, PATH |
| `/etc/systemd/journald.conf.d/volatile.conf` | 9 | Journald volatile (RAM-only) |

### User (17 files)

| Path | Step | Purpose |
|------|------|---------|
| `~/.config/environment.d/gpu.conf` | 5 | EGL, Mesa virgl override, shader cache, GTK dark theme |
| `~/.config/environment.d/sommelier.conf` | 7 | Sommelier scaling, Super key passthrough |
| `~/.config/environment.d/qt.conf` | 7 | Qt 5/6 platform theme |
| `~/.config/pipewire/pipewire.conf.d/10-ry-crostini-gaming.conf` | 6 | PipeWire gaming quantum |
| `~/.config/pipewire/pipewire-pulse.conf.d/10-ry-crostini-gaming.conf` | 6 | PipeWire pulse VM override |
| `~/.config/wireplumber/wireplumber.conf.d/51-crostini-alsa.conf` | 6 | WirePlumber ALSA tuning |
| `~/.config/gtk-3.0/settings.ini` | 7 | Dark theme, Noto Sans 11pt, grayscale AA |
| `~/.config/gtk-4.0/settings.ini` | 7 | Dark theme, Noto Sans 11pt, grayscale AA |
| `~/.gtkrc-2.0` | 7 | GTK 2 dark theme |
| `~/.Xresources` | 7 | Xft DPI 120 |
| `~/.config/fontconfig/fonts.conf` | 7 | Font rendering (grayscale AA for OLED) |
| `~/.icons/default/index.theme` | 7 | Adwaita cursor theme |
| `~/.config/retroarch/retroarch.cfg` | 10 | glcore renderer, PipeWire audio, frame delay |
| `~/.config/scummvm/scummvm.ini` | 10 | OpenGL, pixel-perfect scaling, FluidSynth, chorus off |
| `~/.box64rc` | 10 | SC7180P DynaRec + Wine tuning |
| `~/.local/bin/run-x86` | 10 | x86/x86\_64 binary dispatcher (box64 / qemu) |
| `~/.local/bin/gog-extract` | 10 | GOG installer extraction without Wine |

## Trixie Upgrade

Step 2 upgrades Bookworm containers to Debian 13 (Trixie) by rewriting
codename references in APT sources and running `apt full-upgrade`.

| Behavior | Detail |
|----------|--------|
| Codename replacement | Line-scoped: `deb`/`deb-src` lines in `.list` files, `Suites:` lines in deb822 `.sources` files. Comments and non-repo content are preserved. |
| Package holds | Crostini lifecycle packages (`cros-sommelier`, etc.) are held during upgrade and unheld afterward. `cros-guest-tools` remains held permanently (`cros-im` unavailable on Trixie). |
| Backups | Saved with `.pre-trixie` suffix under `/etc/apt/`. |
| Validation | `VERSION_CODENAME` checked before any rewrite; containers already on Trixie receive a normal `update`/`upgrade`. |
| cros-pin service | `ry-crostini-cros-pin.service` removes stale regenerated `cros.list` on each container start, preventing duplicate APT sources. |
| deb822 migration | After `apt modernize-sources`, any duplicate `cros.list` is removed if a `.sources` equivalent was created. |
| `/tmp` tmpfs | Trixie mounts `/tmp` as tmpfs; step 2 caps it at 512 MB to prevent OOM on 4 GB RAM. |

## Design

### Safety and Reliability

| Property | Implementation |
|----------|---------------|
| Idempotent | Configuration files skip if already present |
| Atomic writes | tmpfile + mv for all configuration files; `write_file_exec` for mode-700 wrappers |
| Concurrent-safe | PID-based `mkdir` lock with stale detection |
| Checkpoint resume | Progress saved after each step to `~/.ry-crostini-checkpoint`; re-run continues from last completed step |
| No eval | `run()` passes `"$@"` directly; generated systemd unit uses `bash -c` for inline conditional only |
| Signal handling | Traps INT, TERM, HUP, PIPE, QUIT; re-raises for correct 128+N exit code |
| Sudo keepalive | Background `sudo -v` loop every 60 s prevents credential timeout; killed in cleanup |

### User Experience

| Property | Implementation |
|----------|---------------|
| Unattended by default | All prompts auto-answered; `--interactive` restores them |
| Dry run | Zero side effects, zero network, zero interaction |
| Colored output | Respects `NO_COLOR` |
| Progress bar | Bottom-pinned step counter with percentage; resize-aware (WINCH) |
| Logging | `~/ry-crostini-YYYYMMDD-HHMMSS.log` (mode 600; rotated after 7 days) |
| Elapsed time | Reported at completion |

## Known Limitations

### Blockers

| Limitation | Detail |
|------------|--------|
| Vulkan unavailable | The virgl paravirtualized GPU exposes OpenGL 4.3 only. `vulkaninfo` installs and reports its version in verification, but no Vulkan device is enumerated. Vulkan-only applications will not run. |

### Constraints

| Limitation | Detail |
|------------|--------|
| sysctl read-only | All kernel tuning parameters (`fs.inotify.max_user_watches`, `vm.max_map_count`, etc.) are blocked by the ChromeOS Termina VM namespace. Writing to `/etc/sysctl.d/` has no effect from inside the container. |
| WirePlumber 0.5 format | Trixie ships WirePlumber 0.5.8 which uses JSON `.conf` files, not Lua scripts. User-created Lua configurations in `~/.config/wireplumber/` are silently ignored. |
| Steam is x86-only | Translation layers (box64/box86) exist but are not viable on 4 GB RAM + virgl. Use cloud gaming via the ChromeOS browser. |
| Flatpak not recommended for gaming | Triple sandbox overhead (ChromeOS → Termina VM → LXC → bubblewrap), Flatpak runtime Mesa compositor crashes (Zink regression), doubled RAM during install/update, and all gaming targets are available as native arm64 `.deb` packages. |

### Informational

| Item | Detail |
|------|--------|
| Sommelier not running during install | Sommelier (Wayland/X11 bridge) is started by the container login process, not inside a running shell. Step 1 logs this as informational; step 11 reports it as a warning only if still absent at completion. Close and reopen the Terminal to resolve. |
| ChromeOS flag status (confirmed M145) | `#crostini-gpu-support`: Required. `#exo-pointer-lock`: Required. |

---

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
| DOSBox-X | DOS emulator with save-states, PC-98, MT-32, and CJK support | — |
| ScummVM | 200+ native engine reimplementations | `~/.config/scummvm/scummvm.ini` (OpenGL, pixel-perfect scaling, FluidSynth) |
| RetroArch | Multi-system frontend (native arm64 Debian package) | `~/.config/retroarch/retroarch.cfg` |

### RetroArch Cores

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

### x86 Translation

> **Warning:** x86 translation overhead consumes 500 MB–1 GB before the
> application loads. Not recommended for RAM-intensive titles.

| Tool | Installation | Performance | Notes |
|------|-------------|-------------|-------|
| box64 | Step 10 (official Debian package) | Fast — ARM64 DynaRec | x86\_64 only; tuned `~/.box64rc` written by step 10 |
| qemu-user | Step 10 | Slow — TCG JIT (~5–10× slower than box64) | Provides i386; binfmt transparent execution blocked in unprivileged Crostini |

The `run-x86` wrapper (`~/.local/bin/run-x86`) auto-detects ELF architecture
and dispatches to box64 (preferred) or qemu-user as appropriate. Run
`run-x86 --help` to list available backends.

#### 32-bit x86 Alternatives

Not installed by default due to the 4 GB RAM constraint:

| Option | Description |
|--------|-------------|
| box86 + armhf libs | ARM32 DynaRec for i386 binaries (`dpkg --add-architecture armhf`). Faster than qemu-user TCG but requires armhf multilib overhead. |
| box64 Box32 mode | Experimental (v0.3.2+), pure 64-bit, no armhf required. Set `BOX64_BOX32=1` in `~/.box64rc` `[default]` section. |

FEX-Emu requires a mandatory x86-64 RootFS image and is not in Debian
repositories. The setup complexity is not warranted for 4 GB Crostini.

#### Transparent Execution (Privileged Container)

Standard Crostini containers are unprivileged and cannot register
binfmt\_misc interpreters. Transparent `./x86_program` execution requires a
privileged container:

1. Open crosh: `Ctrl+Alt+T` → type `shell`
2. Create privileged container:
   ```
   vmc container termina x86 --privileged true
   ```
3. Inside the new container, install binfmt support:
   ```bash
   sudo apt install qemu-user qemu-user-binfmt
   sudo systemctl restart systemd-binfmt
   ```
4. Verify: `ls /proc/sys/fs/binfmt_misc/qemu-*`

> **Warning:** Privileged containers have reduced security isolation. The
> default `penguin` container remains unprivileged and unaffected.

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
attempted separately; to enable it, add non-free to APT sources:

```bash
sudo sed -i 's/ main$/ main non-free/' /etc/apt/sources.list.d/debian.sources
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
| 3 | Chiaki-ng (PS Remote Play) | ARM64 Linux AppImage; only native Crostini streaming client |

**Not recommended inside Crostini:**

| Client | Issue |
|--------|-------|
| Moonlight Qt | No arm64 `.deb`; software decode only |
| Parsec | No ARM64 Linux support |
| Steam Link | No ARM64 Linux support |

## License

[MIT](LICENSE)
