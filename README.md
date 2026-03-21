# crostini-setup-duet5

![version](https://img.shields.io/badge/version-4.8.0-blue?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![bash](https://img.shields.io/badge/bash-5.0%2B-orange?style=flat-square)

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US). Takes a fresh Debian Bookworm or Trixie container from zero to a fully
configured desktop environment in one unattended run.

## Hardware

| | |
|-|-|
| SoC | Snapdragon 7c Gen 2 (SC7180), aarch64 |
| GPU | Adreno 618 → virgl (paravirtualized) |
| RAM / Storage | 4 GB LPDDR4x / 128 GB eMMC |
| Display | 13.3" 1920×1080 OLED |
| Container | Debian Bookworm/Trixie arm64, bash |

## Usage

```bash
bash crostini-setup-duet5.sh                              # unattended (default)
bash crostini-setup-duet5.sh --interactive                # prompt for toggles
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
4. **Recommended before running** (the script is fully unattended by
   default and will not prompt for these; use `--interactive` to be
   guided through each toggle instead):
   - **GPU acceleration**: navigate to `chrome://flags/#crostini-gpu-support`,
     set to **Enabled**, then **reboot the Chromebook** (not just the
     container). The script installs GPU packages regardless, but
     `/dev/dri/renderD128` will not appear until after reboot.
   - **Microphone**: Settings → Developers → Linux → Allow Linux to
     access your microphone → **On**
   - **Disk size**: Settings → Developers → Linux → Disk size →
     increase to **20-30 GB** (the script aborts below 2 GB free and
     warns below 10 GB)
   - **Shared folders** *(optional)*: in the Files app, right-click any
     folder → Share with Linux. Shared folders appear at
     `/mnt/chromeos/`.
   - **USB devices** *(optional)*: Settings → Developers → Linux →
     Manage USB devices → toggle on any devices you need.
   - **Port forwarding** *(optional)*: Settings → Developers → Linux →
     Port forwarding → add dev server ports (3000, 5000, 8080, etc.).
     Crostini also auto-detects listening ports in most cases.

## Steps

| # | Step |
|---|------|
| 1 | Preflight checks (arch, Crostini, disk, network, root, sommelier) |
| 2 | ChromeOS integration (GPU, mic, USB, folders, ports, disk; `--interactive`) |
| 3 | Upgrade to Trixie and full system update |
| 4 | Core CLI utilities (ripgrep, fd, fzf, bat, tmux, jq, curl, htop, wl-clipboard, ...) |
| 5 | Build essentials and development headers |
| 6 | GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan, glmark2) |
| 7 | Audio stack (PipeWire, ALSA, GStreamer codecs, pavucontrol) |
| 8 | Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt, Xft DPI 120, fontconfig, cursor) |
| 9 | GUI applications (Firefox ESR, Chromium, Thunar, Evince, xterm, fonts, screenshots, MIME defaults) |
| 10 | Rust stable aarch64 via rustup |
| 11 | Container resource tuning (sysctl, locale, env, XDG, paths, memory) |
| 12 | Flatpak + Flathub (ARM64 app source) |
| 13 | Gaming packages (DOSBox, DOSBox-X, ScummVM, RetroArch) |
| 14 | Container backup (`--interactive`) |
| 15 | Summary and verification |

## Config files written

Apt download tuning, GPU env (EGL, GTK dark theme), audio env, PipeWire quantum
override, sommelier scaling + Super key passthrough, Qt 5/6 theming, GTK 2/3/4
dark theme (Noto Sans 11pt, grayscale AA for OLED), Xresources DPI 120,
fontconfig, Adwaita cursor, inotify watchers + vm.overcommit\_memory, sysctl
persistence service, shell env + PATH + CARGO\_BUILD\_JOBS, /tmp tmpfs 512M cap
(Trixie). Memory tuning attempted if /proc/sys/vm/ is writable.

## Compatibility

Step 3 automatically upgrades Bookworm (Debian 12) containers to Trixie
(Debian 13) by rewriting `/etc/apt/sources.list` and running
`apt full-upgrade`. Backups of all modified source files are saved with a
`.pre-trixie` suffix under `/etc/apt/` (not inside `sources.list.d/`, which
would cause APT "Ignoring file" warnings). The `VERSION_CODENAME`
is validated as lowercase alphanumeric (with hyphens) before any rewrite. If the container is already
on Trixie, step 3 performs a normal update/upgrade only. Package arrays
use canonical (non-transitional) names that resolve on both releases; the
Trixie t64 transition is transparent on arm64.

The Crostini-managed `cros.list` in `/etc/apt/sources.list.d/` is also
updated but may reset on container restart — this is expected ChromeOS
behavior. After `apt modernize-sources`, any duplicate `cros.list` is removed
if a `.sources` equivalent was created.

Trixie mounts `/tmp` as RAM-backed tmpfs. Step 3 caps it at 512 MB via
systemd drop-in to prevent OOM on 4 GB devices.

## Features

- **Unattended by default** — all 7 prompts auto-answered; `--interactive` restores them
- **Checkpoint resume** — re-run to continue from last completed step
- **`--dry-run`** — zero side effects, zero network, zero interaction
- **`--minimal`** — skip heavy optional packages (e.g. gnome-disk-utility) for RAM-constrained devices
- **Idempotent** — config files skip if already present
- **Concurrent-safe** — PID-based mkdir lock
- **Atomic writes** — tmpfile + mv for all config files
- **No eval, no bash -c** — `run()` passes `"$@"` directly; no shell string interpolation anywhere
- **Colored output** — respects `NO_COLOR`
- **Full logging** — `~/crostini-setup-YYYYMMDD-HHMMSS.log` (mode 600)

## Limitations

**Steam is x86-only and will not run natively on this ARM64 device.**
Community x86 translation layers ([box64](https://github.com/ptitSeb/box64) /
[box86](https://github.com/ptitSeb/box86)) exist but are unsupported in
Crostini and unusable for gaming on this device's 4 GB RAM and virgl
paravirtualized GPU. Use
[GeForce NOW](https://play.geforcenow.com) or
[Xbox Cloud Gaming](https://xbox.com/play) in the ChromeOS browser.

Flatpak apps bundled with Freedesktop Platform ≥25.08 may crash on Crostini
due to Mesa 25.x Zink driver incompatibility with virgl GPU passthrough.
Step 12 automatically pins Freedesktop Platform 24.08; for apps that still
crash, apply a per-app virgl override:
`flatpak override --user --env=MESA_LOADER_DRIVER_OVERRIDE=virgl <app-id>`.
See zen-browser/desktop#12276.
This workaround is temporary — track Mesa/virgl upstream for a permanent fix.

The `#crostini-multi-container` Chrome flag expires at milestone 140 and will
not be re-enabled (Baguette containerless VM replaces multi-container support).

Flatpak uses `--user` mode; system-mode installs are blocked by polkit in
Crostini containers.

`fs.inotify.max_user_watches` and `vm.overcommit_memory` are written to
`/etc/sysctl.d/` and applied by `crostini-sysctl.service` on container start,
but the Termina VM may block writes at runtime. The default inotify 8192 is
sufficient for most use cases; larger projects with file watchers (ripgrep,
inotifywait) may hit the limit. Verify after restart:
`sysctl fs.inotify.max_user_watches vm.overcommit_memory`.

## Browsers

[Brave](https://brave.com/linux/) offers native arm64 Linux packages (DEB/RPM).
Use DEB822 format with Signed-By for the apt repo.

Google Chrome for ARM64 Linux expected Q2 2026
(https://blog.chromium.org/2026/03/bringing-chrome-to-arm64-linux-devices.html).

## Known Issues

- **Firefox ESR Wayland glitches** (Bug 1957911, Crostini-specific): notification
  and popup windows may render at zero size. Separately, some UI actions (e.g.
  hamburger menu) can trigger broken-pipe crashes on Nightly builds. ESR channel
  is more stable than mainline Firefox in Crostini.

## Gaming

Step 13 installs DOSBox, DOSBox-X, ScummVM, and RetroArch (Flatpak). This section
covers what works, what doesn't, and advanced options.

### Compatibility tiers

| Tier | What runs | RAM | Examples |
|------|-----------|-----|---------|
| Excellent | ScummVM, DOSBox, DOSBox-X | < 200 MB | Monkey Island, DOOM, Ultima |
| Good | RetroArch 8/16-bit cores | < 300 MB | NES, SNES, Genesis, GBA |
| Fair | RetroArch PSX | 300-500 MB | PS1 catalog |
| Marginal | RetroArch N64 | ~500 MB | May lag at 4 GB |
| Marginal | box86+Wine 2D/D3D8 | 1-2 GB | Older GOG Windows titles |
| Poor | box86+Wine D3D9 3D | 2-3 GB | Expect < 15 FPS |
| No-go | Vulkan / D3D10+ / x86 Flatpaks | N/A | Steam, modern AAA |

### Native ARM64 (installed by step 13)

**DOSBox** — classic DOS emulation (~30-50 MB).

**DOSBox-X** — enhanced DOSBox fork with PC-98, NEC, and Tandy support,
printer emulation, and better Windows 3.x/9x guest compatibility. Available
as `dosbox-x` in Trixie arm64.

**ScummVM** — 200+ native engine reimplementations (~50-100 MB). No x86
translation needed.

**RetroArch** — multi-system emulator via Flatpak (`org.libretro.RetroArch`).
Flathub aarch64 confirmed. Cores available via Online Updater. 8/16-bit
runs great; PSX playable; N64 may struggle at 4 GB.

### x86 translation (advanced, optional)

> **Warning:** Complex setup. box86+Wine overhead consumes 500 MB-1 GB
> before the game loads. Only pursue for specific Windows-only titles.

**box86** (32-bit x86 translator) and **box64** (64-bit x86\_64 translator)
are available from [ryanfortner.github.io](https://ryanfortner.github.io/box86-debs/)
community repos or compiled from source. TOFU trust model — HTTPS-only,
no detached GPG signature; inspect keys before adding to `trusted.gpg.d`.

**Wine** — must use x86 Wine via box86 (not `apt install wine`, which
installs wine-arm). See the
[box86 x86 Wine docs](https://github.com/ptitSeb/box86/blob/master/docs/X86WINE.md).
WineD3D only (no DXVK); practical ceiling is D3D8/D3D9. For winetricks,
install `cabextract` and `unzip`, download from the
[Winetricks repo](https://github.com/Winetricks/winetricks), and suppress
banner: `BOX86_NOBANNER=1 winetricks -q corefonts vcrun2010`.

### GOG games

[Heroic Games Launcher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases)
has arm64 `.deb` releases (the Flathub Flatpak is x86\_64-only). Heavy for
4 GB (Electron, ~200-400 MB). Alternative: download GOG Linux `.sh`
installers directly from [gog.com](https://www.gog.com) —
`chmod +x installer.sh && ./installer.sh`, no launcher needed.

### Cloud gaming (recommended for AAA)

These run in the ChromeOS browser (not Crostini) and bypass all ARM64/RAM/GPU
limitations: [GeForce NOW](https://play.geforcenow.com),
[Xbox Cloud Gaming](https://xbox.com/play),
[Amazon Luna](https://luna.amazon.com).

## Verify

```bash
glxgears                        # GPU
glmark2-es2-wayland             # GPU benchmark
vulkaninfo --summary            # Vulkan
pactl info                      # audio
speaker-test -t wav -c 2        # audio playback
pavucontrol                     # audio mixer (GUI)
xdpyinfo | grep resolution      # display
xrandr                          # display outputs
fc-match sans-serif             # fonts
fc-match monospace              # fonts
```

## License

[MIT](LICENSE)
