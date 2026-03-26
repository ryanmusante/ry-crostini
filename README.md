# crostini-setup-duet5

![version](https://img.shields.io/badge/version-5.3.3-blue?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![bash](https://img.shields.io/badge/bash-5.0%2B-orange?style=flat-square)

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US). Takes a fresh Debian Bookworm or Trixie container from zero to a fully
configured desktop environment in one unattended run.

## Hardware

| | |
|-|-|
| SoC | Snapdragon 7c Gen 2 (SC7180P), aarch64 |
| GPU | Adreno 618 → virgl (paravirtualized) |
| RAM / Storage | 4 GB LPDDR4x / 128 GB eMMC |
| Display | 13.3" 1920×1080 OLED |
| Container | Debian Bookworm/Trixie arm64, bash |

## Usage

```bash
bash crostini-setup-duet5.sh                              # unattended (default, stays on Bookworm)
bash crostini-setup-duet5.sh --interactive                # prompt for toggles
bash crostini-setup-duet5.sh --trixie                     # upgrade Bookworm to Trixie (Debian 13)
bash crostini-setup-duet5.sh --dry-run                    # preview, zero side effects
bash crostini-setup-duet5.sh --minimal                    # skip heavy optional packages
bash crostini-setup-duet5.sh --from-step=6                # resume from a specific step
bash crostini-setup-duet5.sh --verify                     # run only summary/verification
bash crostini-setup-duet5.sh --reset                      # clear checkpoint, start over
bash crostini-setup-duet5.sh --help                       # show usage and step list
bash crostini-setup-duet5.sh --version                    # show version
bash crostini-setup-duet5.sh --                           # stop processing options
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
| 1 | Preflight checks (arch, bash ≥5.0, Crostini, Debian version, disk, GPU, network, root, sommelier) |
| 2 | ChromeOS integration (GPU, mic, USB, folders, ports, disk; `--interactive`) |
| 3 | System update (apt tuning; `--trixie` upgrades Bookworm to Trixie with cros pkg hold, deb822 migration, /tmp tmpfs cap) |
| 4 | Core CLI utilities (curl, jq, tmux, htop, wl-clipboard, ripgrep, fd, fzf, bat, ...) |
| 5 | Build essentials and development headers |
| 6 | GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan) |
| 7 | Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol, PipeWire gaming tuning) |
| 8 | Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt platform themes, Xft DPI 120, fontconfig, cursor) |
| 9 | GUI applications (Thunar, Evince, Eye of GNOME, file-roller, xterm, fonts, MIME defaults) |
| 10 | Rust stable aarch64 via rustup |
| 11 | Container resource tuning (sysctl, sysctl persistence service, locale, env, XDG, paths, memory) |
| 12 | Flatpak + Flathub (ARM64 app source, Freedesktop Platform 24.08 pinned) |
| 13 | Gaming packages (DOSBox, ScummVM, RetroArch, FluidSynth soundfont, box64 [Trixie only], qemu-user-static) |
| 14 | Container backup (`--interactive`) |
| 15 | Summary and verification |

## Config files written

Apt download tuning, GPU env (EGL, Mesa virgl override, shader cache, GTK dark
theme), PipeWire gaming quantum + pulse overrides (user-level KVM VM override),
sommelier scaling + Super key passthrough, Qt 5/6 theming,
GTK 2/3/4 dark theme (Noto Sans 11pt, grayscale AA for OLED), Xresources DPI 120,
fontconfig, Adwaita cursor, inotify watchers + vm.overcommit\_memory +
vm.max\_map\_count, sysctl persistence service, shell env + PATH +
CARGO\_BUILD\_JOBS, /tmp tmpfs 512M cap (Trixie), RetroArch config (glcore + pulse audio), ScummVM config (OpenGL +
pixel-perfect + FluidSynth), box64 SC7180P config (`~/.box64rc` — DynaRec + Wine tuning),
run-x86 wrapper (`~/.local/bin/run-x86` — auto-selects box64 or qemu for
x86/x86\_64 binaries). Memory tuning attempted if /proc/sys/vm/ is writable.

## Compatibility

Step 3 runs `apt update && apt upgrade` on the current release (Bookworm
by default). With `--trixie`, step 3 upgrades to Debian 13 (Trixie) by
rewriting `/etc/apt/sources.list` and running `apt full-upgrade`. Backups
are saved with a `.pre-trixie` suffix under `/etc/apt/`.
`VERSION_CODENAME` is validated before any rewrite. Already-Trixie
containers get a normal update/upgrade. Package arrays use canonical
names that resolve on both releases (t64 transition is transparent on
arm64).

The Crostini-managed `cros.list` is also updated (with `--trixie`) but
may reset on container restart (expected ChromeOS behavior). After
`apt modernize-sources`, any duplicate `cros.list` is removed if a
`.sources` equivalent was created. Trixie mounts `/tmp` as tmpfs;
step 3 caps it at 512 MB to prevent OOM.

## Features

- **Unattended by default** — all 7 prompts auto-answered; `--interactive` restores them
- **Checkpoint resume** — re-run to continue from last completed step; verification failures keep checkpoint at step 14 so re-run repeats only verification
- **Exit codes** — `0` on success, `1` on verification failure or fatal error
- **`--dry-run`** — zero side effects, zero network, zero interaction
- **`--minimal`** — skip heavy optional packages for RAM-constrained devices
- **Idempotent** — config files skip if already present
- **Concurrent-safe** — PID-based mkdir lock
- **Atomic writes** — tmpfile + mv for all config files
- **No eval, no bash -c** — `run()` passes `"$@"` directly
- **Colored output** — respects `NO_COLOR`
- **Progress bar** — bottom-pinned step counter with percentage; resize-aware
- **Full logging** — `~/crostini-setup-YYYYMMDD-HHMMSS.log` (mode 600; rotated after 7 days)

## Limitations

**Steam is x86-only.** Community translation layers
([box64](https://github.com/ptitSeb/box64) /
[box86](https://github.com/ptitSeb/box86)) exist but are unusable on
4 GB RAM + virgl. Use [GeForce NOW](https://play.geforcenow.com) or
[Xbox Cloud Gaming](https://xbox.com/play) in the ChromeOS browser.

Flatpak apps with Freedesktop Platform ≥25.08 may crash (Mesa Zink +
virgl incompatibility; see zen-browser/desktop#12276). Step 12 pins
24.08; for stubborn apps: `flatpak override --user
--env=MESA_LOADER_DRIVER_OVERRIDE=virgl <app-id>`. Flatpak uses `--user`
mode (system-mode blocked by polkit). The `#crostini-multi-container`
flag expires at milestone 140 (Baguette replaces it).

`fs.inotify.max_user_watches`, `vm.overcommit_memory`, and
`vm.max_map_count` are applied by `crostini-sysctl.service` on start,
but the Termina VM may block writes.
Verify: `sysctl fs.inotify.max_user_watches vm.overcommit_memory vm.max_map_count`.

## Gaming

Step 13 installs DOSBox, ScummVM, RetroArch (Flatpak), FluidSynth GM
soundfont, box64 (Trixie only — x86\_64 DynaRec JIT), and qemu-user-static
(Bookworm) or qemu-user (Trixie) for TCG x86/x86\_64 + i386 emulation
(skipped with `--minimal`). Default config files are written for RetroArch,
ScummVM, box64, and run-x86 on first install.

### Compatibility tiers

| Tier | What runs | RAM | Examples |
|------|-----------|-----|---------|
| Excellent | ScummVM, DOSBox | < 200 MB | Monkey Island, DOOM, Ultima |
| Good | RetroArch 8/16-bit cores | < 300 MB | NES, SNES, Genesis, GBA |
| Fair | RetroArch PSX/PSP | 300-500 MB | PS1 catalog, lighter PSP titles |
| Marginal | RetroArch N64, box64+Wine 2D | 500 MB-2 GB | May lag or OOM |
| No-go | Vulkan / D3D10+ / Steam | N/A | Use cloud gaming |

### Native ARM64 (installed by step 13)

**DOSBox** — classic DOS emulation (interpreter-only on ARM64).

**ScummVM** — 200+ native engine reimplementations. Config at
`~/.config/scummvm/scummvm.ini` with OpenGL, pixel-perfect scaling, and
FluidSynth.

**RetroArch** — multi-system emulator via Flatpak
(`org.libretro.RetroArch`). Flatpak sandbox receives Mesa virgl overrides
automatically. Config at
`~/.var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg`.

### RetroArch recommended cores

| System | Recommended | Type | Notes |
|--------|-------------|------|-------|
| NES | FCEUmm | Core | Lightweight, accurate for 99% of titles |
| SNES | snes9x | Core | Best performance-to-accuracy ratio on ARM64 |
| Genesis / Mega CD / SMS / GG | Genesis Plus GX | Core | Single core covers four systems |
| GBA | mGBA | Core | ARM64-optimized |
| PSX | pcsx_rearmed | Core | ARM NEON dynarec, software renderer (avoids virgl overhead) |
| N64 | mupen64plus-next | Core | GLideN64 with GLES renderer; may struggle at 4 GB |
| PSP | PPSSPP | Core | Install via RetroArch Online Updater; or `flatpak install --user flathub org.ppsspp.PPSSPP` for standalone |
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

### x86 translation (step 13)

> **Warning:** x86 translation overhead consumes 500 MB–1 GB before the game loads. Not recommended for RAM-intensive titles.

**box64** is installed automatically on Trixie (official Debian package). A tuned `~/.box64rc` is written by step 13 on all releases.

**qemu-user-static** (Bookworm) / **qemu-user** (Trixie) is installed
automatically (skipped with `--minimal`). Slower than box64 but provides
i386 support and works on Bookworm where box64 is not packaged.

| Tool | Install | Performance | Notes |
|------|---------|-------------|-------|
| box64 | Step 13 (Trixie only) | Fast — ARM64 DynaRec | x86\_64 only; not in Bookworm repos |
| qemu-user(-static) | Step 13 (Bookworm: qemu-user-static; Trixie: qemu-user) | Slow — TCG JIT via IR (~5-10x slower than box64) | Use `run-x86 ./program`; Bookworm: `qemu-x86_64-static`, Trixie: `qemu-x86_64`; also provides i386; binfmt transparent exec blocked in unprivileged Crostini |
| box64 (source build) | see [github.com/ptitSeb/box64](https://github.com/ptitSeb/box64) | Fast — ARM64 DynaRec | Requires build-essential + cmake; step 5 installs both |

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
   # Bookworm
   sudo apt install qemu-user-static binfmt-support
   sudo systemctl restart binfmt-support

   # Trixie
   sudo apt install qemu-user qemu-user-binfmt
   sudo systemctl restart systemd-binfmt
   ```
4. Verify: `ls /proc/sys/fs/binfmt_misc/qemu-*`

> **Warning:** Privileged containers have reduced security isolation.
> The default `penguin` container remains unprivileged and unaffected.

### GOG games

[Heroic](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases)
has arm64 `.deb` releases (Flatpak is x86\_64-only; heavy at ~200-400 MB).
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
| Moonlight Qt | No arm64 .deb/Flatpak; software decode only |
| Parsec | No ARM64 Linux support |
| Steam Link | No ARM64 Linux support |

## Verify

```bash
glxgears                        # GPU
vulkaninfo --summary            # Vulkan
pactl info                      # audio
pavucontrol                     # audio mixer (GUI)
xdpyinfo | grep resolution      # display
fc-match sans-serif             # fonts
fc-match monospace              # fonts

# Gaming (4.9.0+)
glxinfo | grep -i renderer       # should say "virgl", not "zink"
printenv MESA_NO_ERROR           # should be 1
pw-top                           # QUANT column should show 256
flatpak override --user --show org.libretro.RetroArch | grep MESA_LOADER

# x86 emulation (5.2.0+)
run-x86 --help                   # wrapper available
qemu-x86_64-static --version     # Bookworm (or qemu-x86_64 on Trixie)
```

## License

[MIT](LICENSE)
