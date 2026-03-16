# crostini-setup-duet5

![version](https://img.shields.io/badge/version-3.3.5-blue?style=flat-square)
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
bash crostini-setup-duet5.sh --git-name="…" --git-email="…"  # with git identity
bash crostini-setup-duet5.sh --ssh-comment="…"            # SSH key comment
bash crostini-setup-duet5.sh --ssh-passphrase="…"         # SSH key passphrase
bash crostini-setup-duet5.sh --interactive                # prompt for toggles
bash crostini-setup-duet5.sh --dry-run                    # preview, zero side effects
bash crostini-setup-duet5.sh --minimal                    # skip heavy optional packages
bash crostini-setup-duet5.sh --from-step=6                # resume from a specific step
bash crostini-setup-duet5.sh --verify                     # run only summary/verification
bash crostini-setup-duet5.sh --reset                      # clear checkpoint, start over
```

## Prerequisites

1. ChromeOS updated to latest stable
2. Linux (Beta) enabled: Settings → Developers → Turn On
3. Terminal app open

## Steps

| # | Step |
|---|------|
| 1 | Preflight (arch, Crostini, disk, network, root, sommelier) |
| 2 | ChromeOS integration: GPU, mic, USB, folders, ports, disk (--interactive) |
| 3 | System update + full-upgrade |
| 4 | CLI tools (ripgrep, fd, fzf, bat, tmux, jq, curl, htop, …) |
| 5 | Build essentials + dev headers |
| 6 | GPU + graphics (Mesa, Virgl, Wayland, X11, Vulkan, glmark2) |
| 7 | Audio (ALSA, PulseAudio client, GStreamer, pavucontrol) |
| 8 | HiDPI (sommelier, GTK 2/3/4, Qt, Xft DPI 120, fontconfig, cursor) |
| 9 | GUI apps (Firefox ESR, Thunar, Evince, fonts, screenshots, MIME) |
| 10 | Python 3 + pip + venv |
| 11 | Node.js LTS arm64 (NodeSource) |
| 12 | Rust stable aarch64 (rustup) |
| 13 | Git + git-lfs + defaults |
| 14 | VS Code arm64 + Wayland flags |
| 15 | Tuning (inotify 524288, locale, env, XDG, memory if writable) |
| 16 | Flatpak + Flathub |
| 17 | Gaming packages (DOSBox, ScummVM, RetroArch) |
| 18 | SSH Ed25519 key |
| 19 | Container backup (--interactive) |
| 20 | Summary + verification |

## Config files written

GPU env, audio env, sommelier scaling, Qt theming, GTK 2/3/4 dark theme
(Noto Sans 11pt, grayscale AA for OLED), Xresources DPI 120, fontconfig,
Adwaita cursor, PulseAudio client, VS Code Wayland flags, inotify watchers,
shell env + PATH. Memory tuning attempted if /proc/sys/vm/ is writable.

## Features

  * **Unattended by default** — all 12 prompts auto-answered; `--interactive` restores them
  * **Checkpoint resume** — re-run to continue from last completed step
  * **`--dry-run`** — zero side effects, zero network, zero interaction
  * **`--minimal`** — skip heavy optional packages (e.g. gnome-disk-utility) for RAM-constrained devices
  * **Idempotent** — config files skip if already present
  * **Concurrent-safe** — PID-based mkdir lock
  * **Atomic writes** — tmpfile + mv for all config files
  * **No eval** — `run()` passes `"$@"` directly; `run_shell()` uses `bash -c` with hardcoded strings only (never user input)
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
pactl info                      # audio
fc-match sans-serif             # fonts
```

## Files

```
crostini-setup-duet5.sh    main script (bash)
README.md                  this file
CHANGELOG.txt              version history
```

See [CHANGELOG.txt](CHANGELOG.txt) for the full version history.

## License

[MIT](LICENSE)
