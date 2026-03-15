# crostini-setup-duet5

Crostini post-install bootstrap for the **Lenovo IdeaPad Duet 5 Chromebook**
(82QS0001US / 13Q7C6).

## Hardware

| Spec | Value |
|------|-------|
| Model | Lenovo IdeaPad Duet 5 Chromebook 13Q7C6 |
| Part | 82QS0001US |
| Board | homestar (Trogdor family) |
| SoC | Qualcomm Snapdragon 7c Gen 2 (SC7180) |
| Arch | aarch64 / arm64 |
| GPU | Qualcomm Adreno 618 (virgl paravirtualized in Crostini) |
| RAM | 4 GB LPDDR4x |
| Storage | 128 GB eMMC |
| Display | 13.3" 1920×1080 OLED |
| Shell | bash (Crostini default) |
| Container | Debian Bookworm (arm64) |

## What it does

A single bash script that takes a fresh Crostini Linux container from zero to
a fully configured development environment in one run. Everything is automated
— ChromeOS settings pages that require manual toggles are auto-opened via
`garcon-url-handler` from inside the container.

### 19 steps

| Step | Description |
|------|-------------|
| 1 | Preflight checks (arch, Crostini, disk, network, root, sommelier) |
| 2 | ChromeOS integration — auto-opens GPU flag, mic, USB, folders, ports, disk |
| 3 | System update and upgrade |
| 4 | Core CLI utilities (ripgrep, fd, fzf, bat, tmux, jq, curl, htop, …) |
| 5 | Build essentials and development headers |
| 6 | GPU + graphics stack (Mesa, Virgl, Wayland, X11, Vulkan, glmark2) |
| 7 | Audio stack (ALSA, PulseAudio, GStreamer codecs, pavucontrol) |
| 8 | Display scaling (sommelier, GTK 2/3/4, Qt, Xft DPI 120, fontconfig, cursor) |
| 9 | GUI apps (Firefox ESR, Thunar, Evince, screenshots, fonts, MIME defaults) |
| 10 | Python 3 + pip + venv |
| 11 | Node.js LTS arm64 (NodeSource) + npm global prefix |
| 12 | Rust stable aarch64 (rustup) |
| 13 | Git + git-lfs + sensible defaults |
| 14 | VS Code arm64 + Wayland/Ozone flags |
| 15 | Container tuning (inotify, locale, env, XDG, memory if writable) |
| 16 | Flatpak + Flathub |
| 17 | SSH Ed25519 key generation |
| 18 | Container backup (auto-opens ChromeOS backup page) |
| 19 | Summary and verification (GPU, Vulkan, Wayland, audio, config files, tools) |

### Config files written

GPU env, audio env, sommelier scaling, Qt scaling/theming, GTK 2/3/4 dark
theme with Noto Sans 11pt and grayscale font antialiasing (OLED-correct),
Xresources DPI 120
for the 13.3" OLED, fontconfig defaults, Adwaita cursor theme, PulseAudio
client, VS Code Wayland flags, inotify watchers, and shell env with PATH.
Memory tuning (vm.swappiness, dirty ratio) is attempted but may be skipped
if the container lacks write access to /proc/sys/vm/ (typical in Crostini).

## Usage

```bash
# First run — full setup
bash crostini-setup-duet5.sh

# Preview without making changes
bash crostini-setup-duet5.sh --dry-run

# Resume after interruption (checkpoint auto-saved)
bash crostini-setup-duet5.sh

# Start over
bash crostini-setup-duet5.sh --reset

# Show help
bash crostini-setup-duet5.sh --help
```

## Prerequisites

1. ChromeOS updated to latest stable
2. Linux (Beta) enabled: Settings → Advanced → Developers → Turn On
3. Terminal app open

Everything else is handled by the script.

## Features

- **Checkpoint resume** — progress saved after each step; re-run to continue
- **`--dry-run`** — all `apt`, `sudo`, `mkdir`, `chmod`, config writes, interactive prompts, ChromeOS URL opens, and the preflight network check are skipped with logged output; zero outbound requests, zero user interaction
- **Colored output** — respects `NO_COLOR` env variable
- **Full logging** — every command logged to `~/crostini-setup-YYYYMMDD-HHMMSS.log`
- **Trap handler** — cleanup on EXIT/INT/TERM
- **Pipefail-safe** — no `| tee` pipes; log writes are separate from stdout
- **No eval** — `run()` passes `"$@"` directly; `run_shell()` restricted to pipe commands with no user input
- **Idempotent** — every config file checks existence before writing; re-runs never overwrite user customizations
- **Dynamic UID** — PulseAudio socket path uses `$(id -u)`, not hardcoded 1000
- **Concurrent-safe** — mkdir-based lock file prevents parallel runs from corrupting checkpoint
- **4 GB aware** — memory tuning attempted if container permits (vm.swappiness is read-only in most Crostini setups)

## Important limitations

**Steam will not run on this device.** Steam's Linux client is x86-only. The
Snapdragon 7c Gen 2 is ARM64. No amount of Crostini configuration changes
this. Use cloud gaming instead:

- [GeForce NOW](https://play.geforcenow.com) — runs in the ChromeOS browser
- [Xbox Cloud Gaming](https://xbox.com/play) — runs in the ChromeOS browser

When downloading `.deb` files manually, always select the **arm64** variant.

## Verification after install

```bash
# GPU
glxgears
glmark2-es2-wayland
vulkaninfo --summary

# Audio
pactl info
speaker-test -t wav -c 2
pavucontrol

# Display
xdpyinfo | grep resolution
xrandr

# Fonts
fc-match sans-serif
fc-match monospace
```

## Files

```
crostini-setup-duet5.sh    Main script (1453 lines, bash)
README.md                  This file
LICENSE                    MIT
CHANGELOG.txt              Version history (kernel.org style)
```

## License

[MIT](LICENSE)
