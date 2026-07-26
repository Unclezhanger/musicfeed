[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md)
[![中文](https://img.shields.io/badge/lang-中文-red.svg)](README_zh.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)]()
[![Bash](https://img.shields.io/badge/bash-4%2B-green.svg)]()

# 🎵 musicfeed

**Intelligent batch downloader for the YouTube Music ecosystem.**

Most tools treat every YouTube link the same. musicfeed doesn't.

## 🆚 What makes it different

### 1. Cover art that actually matches what you expect

YouTube Music pads album covers into 16:9 thumbnails. How a tool handles this determines whether your library looks right.

musicfeed reads each track's metadata **before** deciding what to do with the cover:

| Track type | Cover treatment |
| --- | --- |
| YTM audio track (has metadata) | 1:1 center crop — recovers the original square album cover |
| MV / video track (no metadata) | Compress only, keep original aspect ratio |
| YTM album (unified mode) | Downloads the playlist-level thumbnail directly |

### 2. Four link types, four different strategies

musicfeed detects the link type before asking any questions:

| Link type | Detection | Strategy |
| --- | --- | --- |
| YTM Album | `OLAK5uy_` in URL | Unified album cover + correct `album_artist` tag |
| YTM Radio / Mix | `RDCLAK5uy_` in URL | Per-track independent covers |
| YouTube Playlist | `PL...` in URL | MV mode: manual per-track input or auto strategy |
| Single track | `watch?v=` | Smart metadata check & cover decision |

### 3. Correct ID3 tags for self-hosted libraries

`album_artist` is written correctly on every track. This matters for Navidrome and Jellyfin — without it, multi-artist albums split into multiple entries in your library.

### 4. Dual audio format support

Choose your format once in `mf_setup.sh`:

* **Opus** (default) — higher quality (~160kbps VBR), smaller files
* **M4A** — native Apple device support, no transcoding needed

## 🆕 v3.0.0 Highlights

### 🎵 Enhanced Playlist Support
- **Large playlist handling**: Successfully downloads playlists with over 100 tracks (thanks to recent yt-dlp updates).
- **Global chart integration**: Built-in support for syncing global popular charts.

### 🖥️ Improved Interactive Experience
- **Smart terminal pagination**: Playlist and folder selections now automatically paginate based on your terminal size.
- **Simplified configuration**: A cleaner setup wizard with better defaults.

### 📁 Robust Folder Management
- **Intelligent hidden folders**: Automatically detects and manages system-generated folders (`.DS_Store`, `@eaDir`).

## 📋 Requirements

* **bash 4.0+**
* **yt-dlp** (must be the **latest version**)
* `ffmpeg`
* `python3` + **mutagen** (`pip3 install mutagen`)
* `node` (optional but recommended)

> **⚠️ macOS Users Note:**

> This project requires Bash 4.0+. macOS ships with the outdated Bash 3.2.

Installation Issue on Older macOS:
If you are on older macOS versions (e.g., Catalina), installing Bash 4 via Homebrew (`brew install bash`) may fail or hang during the compilation process. This is a known system compatibility issue.

Solution:
We recommend downloading a pre-compiled Bash binary package (e.g., from `osx-brew-builds` or similar sources) to bypass the compilation step.

## 📦 Quick Start

```bash
git clone https://github.com/Unclezhanger/musicfeed.git
cd musicfeed

# One-time setup (select music path, default folder, audio format)
bash mf_setup.sh

# Start downloading
bash musicfeed.sh
```

`mf_setup.sh` auto-detects all dependencies and guides you through configuration. Re-run anytime to change settings.

## 📁 Project Structure

| File | Purpose |
|------|---------|
| `musicfeed.sh` | Main script |
| `mf_setup.sh` | Setup wizard |
| `mf_config.sh` | Generated config (do not edit manually) |


## ⚠️ Disclaimer

For personal and educational use only. Please respect copyright laws in your region. The author assumes no liability for any misuse.

## 📄 License

MIT License © 2026 Unclezhanger

---

**About**: musicfeed is a focused tool designed specifically for the YouTube Music ecosystem, providing intelligent batch downloading with correct metadata handling for self-hosted music libraries.

**Topics**: `bash` `cover-art` `id3-tags` `jellyfin` `meta` `music` `navidrome` `plex` `youtube`
