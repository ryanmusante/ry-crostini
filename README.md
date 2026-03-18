# crostini-setup-duet5

![version](https://img.shields.io/badge/version-3.11.1-blue?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![bash](https://img.shields.io/badge/bash-5.0%2B-orange?style=flat-square)

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US). Takes a fresh Debian Bookworm container from zero to a fully
configured dev environment in one unattended run.

## Hardware

| | |
|-|-|
| SoC | Snapdragon 7c Gen 2 (SC7180), aarch64 |
| GPU | Adreno 618 → virgl (paravirtualized) |
| RAM / Storage | 4 GB LPDDR4x / 128 GB eMMC |
| Display | 13.3" 1920×1080 OLED |
| Container | Debian Bookworm arm64, bash |

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
     increase to **20–30 GB** (the script aborts below 2 GB free and
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
| 3 | System update, upgrade, and full-upgrade |
| 4 | Core CLI utilities (ripgrep, fd, fzf, bat, tmux, jq, curl, htop, wl-clipboard, …) |
| 5 | Build essentials and development headers |
| 6 | GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan, glmark2) |
| 7 | Audio stack (ALSA, PulseAudio client, GStreamer codecs, pavucontrol) |
| 8 | Display scaling and HiDPI (sommelier, Super key passthrough, GTK 2/3/4, Qt, Xft DPI 120, fontconfig, cursor) |
| 9 | GUI applications (Firefox ESR, Thunar, Evince, xterm, fonts, screenshots, MIME defaults) |
| 10 | Python ecosystem (python3, pip, venv) |
| 11 | Node.js LTS arm64 via NodeSource |
| 12 | Rust stable aarch64 via rustup |
| 13 | VS Code arm64 .deb + Wayland flags |
| 14 | Container resource tuning (sysctl, locale, env, XDG, paths, memory) |
| 15 | Flatpak + Flathub (ARM64 app source) |
| 16 | Gaming packages (DOSBox, ScummVM, RetroArch) |
| 17 | Container backup (`--interactive`) |
| 18 | Summary and verification |

## Config files written

Apt download tuning, GPU env, audio env, sommelier scaling + Super key
passthrough, Qt theming, GTK 2/3/4 dark theme (Noto Sans 11pt, grayscale AA
for OLED), Xresources DPI 120, fontconfig, Adwaita cursor, PulseAudio client,
VS Code Wayland flags, inotify watchers, shell env + PATH. Memory tuning
attempted if /proc/sys/vm/ is writable.

## Trixie migration

Bookworm is now oldstable. When Crostini containers upgrade to Trixie
(Debian 13), package arrays need auditing for the t64 transition
(`libasound2` → `libasound2t64`, `libncurses6` → `libncurses6t64`, etc.).
See the [64-bit time wiki page](https://wiki.debian.org/NewIn64bitTime) for
the full list. The script header comments flag this explicitly.

## Features

  * **Unattended by default** — all 7 prompts auto-answered; `--interactive` restores them
  * **Checkpoint resume** — re-run to continue from last completed step
  * **`--dry-run`** — zero side effects, zero network, zero interaction
  * **`--minimal`** — skip heavy optional packages (e.g. gnome-disk-utility) for RAM-constrained devices
  * **Idempotent** — config files skip if already present
  * **Concurrent-safe** — PID-based mkdir lock
  * **Atomic writes** — tmpfile + mv for all config files
  * **No eval, no bash -c** — `run()` passes `"$@"` directly; no shell string interpolation anywhere
  * **Colored output** — respects `NO_COLOR`
  * **Full logging** — `~/crostini-setup-YYYYMMDD-HHMMSS.log` (mode 600)

## Limitations

**Steam is x86-only and will not run natively on this ARM64 device.**
Community x86 translation layers ([box64](https://github.com/ptitSeb/box64) /
[box86](https://github.com/ptitSeb/box86)) exist but are unsupported in
Crostini and unusable for gaming on this device's 4 GB RAM and virgl
paravirtualized GPU. Use
[GeForce NOW](https://play.geforcenow.com) or
[Xbox Cloud Gaming](https://xbox.com/play) in the ChromeOS browser.
Always download the **arm64** `.deb` variant.

## Verify

```bash
glxgears                        # GPU
glmark2-es2-wayland             # GPU benchmark
vulkaninfo --summary            # Vulkan
pactl info                      # audio
speaker-test -t wav -c 2        # audio playback
xdpyinfo | grep resolution      # display
fc-match sans-serif             # fonts
fc-match monospace              # fonts
```

## Files

```
crostini-setup-duet5.sh    main script (bash)
README.md                  this file
CHANGELOG.txt              version history
LICENSE                    MIT license
```

See [CHANGELOG.txt](CHANGELOG.txt) for the full version history.

## License

[MIT](LICENSE)
