# ry-crostini

![version](https://img.shields.io/badge/version-7.3.0-blue?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![bash](https://img.shields.io/badge/bash-5.0%2B-orange?style=flat-square)

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US). Takes a fresh Debian container from zero to a fully
configured Trixie (Debian 13) desktop environment in one unattended run.
Bookworm containers are upgraded to Trixie automatically in step 2.

## Hardware

| | |
|-|-|
| SoC | Snapdragon 7c Gen 2 (SC7180P), aarch64 |
| GPU | Adreno 618 → virgl (paravirtualized) |
| RAM / Storage | 4 GB LPDDR4x / 128 GB eMMC |
| Display | 13.3" 1920×1080 OLED |
| Container | Debian Trixie arm64, bash |

## Usage

```bash
bash ry-crostini.sh                              # unattended (default, upgrades to Trixie)
bash ry-crostini.sh --interactive                # prompt for toggles
bash ry-crostini.sh --dry-run                    # preview, zero side effects
bash ry-crostini.sh --minimal                    # skip heavy optional packages
bash ry-crostini.sh --from-step=6                # resume from a specific step
bash ry-crostini.sh --verify                     # run only summary/verification
bash ry-crostini.sh --reset                      # clear checkpoint, start over
bash ry-crostini.sh --help                       # show usage and step list
bash ry-crostini.sh --version                    # show version
bash ry-crostini.sh --                           # stop processing options
```

## Prerequisites

1. ChromeOS updated to latest stable
2. Linux (Beta) enabled: Settings → Developers → Turn On
3. Terminal app open
4. **Recommended before running** (use `--interactive` to be guided through
   each toggle, or configure manually):
   - **GPU**: `chrome://flags/#crostini-gpu-support` → Enabled → reboot
     Chromebook. GPU packages install regardless; `/dev/dri/renderD128`
     requires the flag + reboot.
   - **Microphone**: Settings → Developers → Linux → Microphone → On
   - **Disk size**: Settings → Developers → Linux → Disk size → 20-30 GB
     (aborts below 2 GB, warns below 10 GB)
   - **Shared folders** *(optional)*: Files app → right-click folder →
     Share with Linux (appears at `/mnt/chromeos/`)
   - **USB** *(optional)*: Settings → Developers → Linux → Manage USB devices
   - **Ports** *(optional)*: Settings → Developers → Linux → Port forwarding

## Steps

| # | Step |
|---|------|
| 1 | Preflight + ChromeOS integration (arch, bash ≥5.0, Crostini, Debian version, disk, GPU, network, root, sommelier, mic, USB, folders, ports, disk-resize; `--interactive`) |
| 2 | System update (apt tuning, Trixie upgrade, cros pkg hold, deb822 migration, /tmp tmpfs cap) |
| 3 | Core CLI utilities (curl, jq, tmux, htop, wl-clipboard, ripgrep, fd, fzf, bat, ...) |
| 4 | Build essentials and development headers |
| 5 | GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan) |
| 6 | Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol, PipeWire gaming tuning) |
| 7 | Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt platform themes, Xft DPI 120, fontconfig, cursor) |
| 8 | GUI essentials (xterm, session support, fonts, icons) |
| 9 | Container resource tuning (sysctl, sysctl persistence service, locale, env, XDG, paths, memory) |
| 10 | Gaming packages (DOSBox-X, ScummVM, RetroArch, FluidSynth soundfont, innoextract/GOG, unrar/unar, box64, qemu-user) |
| 11 | Summary and verification |

## Config files written

Apt download tuning, GPU env (EGL, Mesa virgl override, shader cache, GTK dark
theme), PipeWire gaming quantum + pulse overrides (user-level KVM VM override),
sommelier scaling + Super key passthrough, Qt 5/6 theming,
GTK 2/3/4 dark theme (Noto Sans 11pt, grayscale AA for OLED), Xresources DPI 120,
fontconfig, Adwaita cursor, inotify watchers + vm.overcommit\_memory +
vm.max\_map\_count, sysctl persistence service, shell env + PATH,
/tmp tmpfs 512M cap (Trixie), RetroArch config (glcore + pulse audio), ScummVM config (OpenGL +
pixel-perfect + FluidSynth), box64 SC7180P config (`~/.box64rc` — DynaRec + Wine tuning),
run-x86 wrapper (`~/.local/bin/run-x86` — auto-selects box64 or qemu for
x86/x86\_64 binaries), gog-extract wrapper (`~/.local/bin/gog-extract` — extracts
GOG Windows .exe and Linux .sh installers without Wine). Memory tuning attempted if /proc/sys/vm/ is writable.

## Compatibility

Step 2 upgrades the container to Debian 13 (Trixie) by rewriting
`/etc/apt/sources.list` and running `apt full-upgrade`. Crostini
lifecycle packages (`cros-guest-tools`, `cros-sommelier`, etc.) are held
during the upgrade and unheld afterward. Backups are saved with a
`.pre-trixie` suffix under `/etc/apt/`. `VERSION_CODENAME` is validated
before any rewrite. Already-Trixie containers get a normal
update/upgrade.

The Crostini-managed `cros.list` is also updated but may reset on
container restart (expected ChromeOS behavior). After
`apt modernize-sources`, any duplicate `cros.list` is removed if a
`.sources` equivalent was created. Trixie mounts `/tmp` as tmpfs;
step 2 caps it at 512 MB to prevent OOM.

## Features

- **Unattended by default** — all 6 prompts auto-answered; `--interactive` restores them
- **Checkpoint resume** — re-run to continue from last completed step; verification failures keep checkpoint at step 10 so re-run repeats only verification
- **Exit codes** — `0` on success, `1` on verification failure or fatal error
- **`--dry-run`** — zero side effects, zero network, zero interaction
- **`--minimal`** — skip heavy optional packages for RAM-constrained devices
- **Idempotent** — config files skip if already present
- **Concurrent-safe** — PID-based mkdir lock
- **Atomic writes** — tmpfile + mv for all config files
- **No eval, no bash -c** — `run()` passes `"$@"` directly
- **Colored output** — respects `NO_COLOR`
- **Progress bar** — bottom-pinned step counter with percentage; resize-aware
- **Full logging** — `~/ry-crostini-YYYYMMDD-HHMMSS.log` (mode 600; rotated after 7 days)

## Known limitations

**Vulkan is unavailable.** The virgl paravirtualized GPU exposes OpenGL 4.3
only. `vulkaninfo` installs and its version is reported in verification, but
no Vulkan device is enumerated. Vulkan-only games and apps will not run.

**Sommelier is not running during install.** Sommelier (the Wayland/X11
bridge) is started by the container login process, not inside a running
shell. Step 11 verification reports this as a warning and prompts a terminal
restart. Closing and reopening the Terminal app is all that is required.

**sysctl keys are partially read-only in Crostini.** `fs.inotify.max_user_watches`
is writable and applied on first run. `vm.overcommit_memory`, `vm.max_map_count`,
and `fs.protected_*` are blocked by the ChromeOS Termina VM namespace.
`ry-crostini-sysctl.service` retries on each container start.
Verify: `sysctl fs.inotify.max_user_watches vm.overcommit_memory vm.max_map_count`.

**Steam is x86-only.** Community translation layers
([box64](https://github.com/ptitSeb/box64) /
[box86](https://github.com/ptitSeb/box86)) exist but are unusable on
4 GB RAM + virgl. Use [GeForce NOW](https://play.geforcenow.com) or
[Xbox Cloud Gaming](https://xbox.com/play) in the ChromeOS browser.

The `#crostini-multi-container` flag expires at milestone 140 (Baguette
replaces it).

## Gaming

Step 10 installs DOSBox-X, ScummVM, RetroArch, FluidSynth GM
soundfont, innoextract (GOG/Inno Setup extractor), unrar/unar (GOG
multi-part RAR archives), box64 (x86\_64 DynaRec JIT),
and qemu-user for TCG x86/x86\_64 + i386 emulation
(skipped with `--minimal`). Default config files are written for
RetroArch, ScummVM, box64, run-x86, and gog-extract on first install.

### Compatibility tiers

| Tier | What runs | RAM | Examples |
|------|-----------|-----|---------|
| Excellent | ScummVM, DOSBox-X | < 200 MB | Monkey Island, DOOM, Ultima |
| Good | RetroArch 8/16-bit cores | < 300 MB | NES, SNES, Genesis, GBA |
| Fair | RetroArch PSX/PSP | 300-500 MB | PS1 catalog, lighter PSP titles |
| Marginal | RetroArch N64, box64+Wine 2D | 500 MB-2 GB | May lag or OOM |
| No-go | Vulkan / D3D10+ / Steam | N/A | Use cloud gaming |

### Native ARM64 (installed by step 10)

**DOSBox-X** — comprehensive DOS emulator with save-states, PC-98, MT-32,
and CJK support.

**ScummVM** — 200+ native engine reimplementations. Config at
`~/.config/scummvm/scummvm.ini` with OpenGL, pixel-perfect scaling, and
FluidSynth.

**RetroArch** — multi-system emulator (native arm64 Debian package).
Config at `~/.config/retroarch/retroarch.cfg`.

### RetroArch recommended cores

| System | Recommended | Type | Notes |
|--------|-------------|------|-------|
| NES | FCEUmm | Core | Lightweight, accurate for 99% of titles |
| SNES | snes9x | Core | Best performance-to-accuracy ratio on ARM64 |
| Genesis / Mega CD / SMS / GG | Genesis Plus GX | Core | Single core covers four systems |
| GBA | mGBA | Core | ARM64-optimized |
| PSX | pcsx_rearmed | Core | ARM NEON dynarec, software renderer (avoids virgl overhead) |
| N64 | mupen64plus-next | Core | GLideN64 with GLES renderer; may struggle at 4 GB |
| PSP | PPSSPP | Core | Install via RetroArch Online Updater |
| DS | melonDS DS | Core | ARM64 builds confirmed (v1.1.8+) |
| Dreamcast | Flycast | Core | ARM64 JIT; lighter titles at full speed |

### RetroArch CRT shaders

Virgl's GLES profile limits shader complexity. Tested slang shaders:

| Shader | Description | Performance |
|--------|-------------|-------------|
| CRT-Pi | Designed for Raspberry Pi; excellent starting point | Minimal |
| CRT-Potato | Tiled mask texture; extremely lightweight | Minimal |
| CRT-Easymode | Good flat-display CRT simulation | Low |
| FakeLottes | CRT-Lottes tuned for weak GPUs | Low |

Avoid CRT-Royale and Mega Bezel presets entirely — they require desktop GPU power.

### RetroArch run-ahead

Enable per-core overrides for 8-bit and 16-bit systems only. Create a core
override (Quick Menu → Overrides → Save Core Override) with:

```
run_ahead_enabled = "true"
run_ahead_frames = "1"
run_ahead_secondary_instance = "false"
```

Never enable two-instance run-ahead on this hardware (doubles RAM usage per
core). Do not enable run-ahead for PSX, N64, PSP, DS, or Dreamcast cores.

### x86 translation (step 10)

> **Warning:** x86 translation overhead consumes 500 MB–1 GB before the game loads. Not recommended for RAM-intensive titles.

**box64** is installed automatically (official Debian package). A tuned `~/.box64rc` is written by step 10.

**qemu-user** is installed automatically (skipped with `--minimal`).
Slower than box64 but provides i386 support.

| Tool | Install | Performance | Notes |
|------|---------|-------------|-------|
| box64 | Step 10 | Fast — ARM64 DynaRec | x86\_64 only |
| qemu-user | Step 10 | Slow — TCG JIT via IR (~5-10x slower than box64) | Use `run-x86 ./program`; `qemu-x86_64`; also provides i386; binfmt transparent exec blocked in unprivileged Crostini |

`run-x86` wrapper (`~/.local/bin/run-x86`) auto-detects ELF architecture
and dispatches to box64 (preferred) or qemu as appropriate.

**FEX-Emu:** requires a mandatory x86-64 RootFS image and is not in Debian repos — setup complexity not warranted for 4 GB Crostini.

### Transparent execution (privileged container)

Standard Crostini containers are unprivileged and cannot register
binfmt\_misc interpreters. To get transparent `./x86_program` execution,
create a privileged container:

1. Open crosh: `ctrl+alt+t` → type `shell`
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

> **Warning:** Privileged containers have reduced security isolation.
> The default `penguin` container remains unprivileged and unaffected.

### GOG games

Step 10 installs `innoextract` and writes the `gog-extract` wrapper
(`~/.local/bin/gog-extract`) for extracting GOG game installers on Linux
without Wine.

**Windows GOG installers** (`.exe`) use Inno Setup. `innoextract` unpacks
them natively on ARM64, including GOG Galaxy multi-part `.bin` archives:

```bash
gog-extract setup_monkey_island_1.0.exe              # extracts to ./setup_monkey_island_1.0/
gog-extract setup_monkey_island_1.0.exe ~/Games/MI    # extracts to ~/Games/MI/
# Game files land in the app/ subdirectory
```

**Linux GOG installers** (`.sh`) are makeself archives:

```bash
gog-extract gog_baldurs_gate_enhanced_edition.sh       # extracts to ./gog_baldurs_gate_enhanced_edition/
# Game files land in data/noarch/game/
```

Multi-part GOG Windows installers with `.bin` RAR archives require
`unrar` or `unar` (both installed by step 10).

[Heroic](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases)
provides Linux `.deb` releases (amd64 only — no native arm64 build; could
run under box64 on Trixie but is untested on 4 GB RAM).
Alternative: download GOG `.sh` installers from [gog.com](https://www.gog.com)
directly.

### Cloud gaming (recommended for AAA)

| Priority | Client | Notes |
|----------|--------|-------|
| 1 | ChromeOS browser (GeForce NOW, Xbox Cloud Gaming, Luna) | Direct V4L2 hardware decode, no VM overhead |
| 2 | Android Moonlight app (Play Store) | Hardware decode; best for Sunshine/GameStream hosts |
| 3 | Chiaki-ng (PS Remote Play) | ARM64 Linux AppImage; only native Crostini streaming client |

**Not recommended inside Crostini:**

| Client | Issue |
|--------|-------|
| Moonlight Qt | No arm64 .deb; software decode only |
| Parsec | No ARM64 Linux support |
| Steam Link | No ARM64 Linux support |

## Verify

```bash
glxgears                        # GPU
vulkaninfo --summary            # Vulkan (reports version; no device on virgl)
pactl info                      # audio
pavucontrol                     # audio mixer (GUI)
xdpyinfo | grep resolution      # display
fc-match sans-serif             # fonts
fc-match monospace              # fonts

# Gaming (4.9.0+)
glxinfo | grep -i renderer       # should say "virgl", not "zink"
printenv MESA_NO_ERROR           # should be 1
pw-top                           # QUANT column should show 256

# x86 emulation (5.2.0+)
run-x86 --help                   # wrapper available
qemu-x86_64 --version            # QEMU TCG emulator

# GOG extraction (5.4.0+)
innoextract --version            # Inno Setup extractor
gog-extract --help               # GOG installer wrapper
```

## License

[MIT](LICENSE)
