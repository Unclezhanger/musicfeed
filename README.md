[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md)
[![中文](https://img.shields.io/badge/lang-中文-red.svg)](README_zh.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)]()
[![Bash](https://img.shields.io/badge/bash-4%2B-green.svg)]()
[![Release](https://img.shields.io/badge/release-v3.5.2-success.svg)]()

# 🎵 musicfeed

**Intelligent batch downloader for the YouTube Music ecosystem.**

Most tools treat every YouTube link the same. musicfeed doesn't.

## 🖼️ The result

One album link + three singles from different albums, downloaded and dropped
into [Navidrome](https://www.navidrome.org/) — every track with the correct
cover, `album` / `album_artist` tags and a clean `artist - title` filename:

![Navidrome library result](docs/navidrome-result.png)

*Left to right: a full YTM album (unified cover) and three singles with
per-track MV covers — each lands in its own album entry with proper tags.*

## 🆚 What makes it different

### 1. Cover art that actually matches what you expect

YouTube Music pads album covers into 16:9 thumbnails. How a tool handles this determines whether your library looks right.

musicfeed reads each track's metadata **before** deciding what to do with the cover:

| Track type | Cover treatment |
| --- | --- |
| YTM audio track (has metadata) | 1:1 center crop — recovers the original square album cover |
| MV / video track (no metadata) | Compress only, keep original aspect ratio |
| YTM album (unified mode) | Downloads the playlist-level thumbnail directly |

### 2. Five link types, five different strategies

musicfeed detects the link type before asking any questions:

| Link type | Detection | Strategy |
| --- | --- | --- |
| YTM Album | `OLAK5uy_` share link **or** `MPREb_` browse link | Unified album cover + correct `album_artist` tag |
| YTM Radio / Mix | `RDCLAK5uy_` in URL | Per-track independent covers |
| YouTube Playlist | `PL...` in URL | MV mode: manual per-track input or auto strategy |
| Single track | `watch?v=` / `youtu.be/` | Smart metadata check & cover decision |

> `MPREb_…` is the album link you get by copying the address bar on
> music.youtube.com — `OLAK5uy_…` is what the share button produces. Both point
> to the same album entity and are handled identically.

### 3. Song titles that come out clean

Radio and video titles arrive polluted (`【MV】【動態歌詞】(Official Audio)`…). musicfeed's extraction engine reconstructs `artist - title` from the original title and the uploader channel:

- Book-title (`《》`) / bracket pollution-word stripping
- Uploader ↔ title cross-matching instead of blind `" - "` splitting
- No-metadata tracks are renamed and tagged with the extracted values

### 4. Correct ID3 tags for self-hosted libraries

`album_artist` is written correctly on every track. This matters for Navidrome and Jellyfin — without it, multi-artist albums split into multiple entries in your library.

### 5. A setup wizard and a TUI that always work

`mf_setup.sh` detects every dependency and can **one-click install** everything (system packages via sudo, yt-dlp/mutagen isolated in a project venv — no `sudo pip`). The interactive UI degrades gracefully: `whiptail` → arrow-key menu → numeric input, so it works over any SSH session.

## 🆕 What's New in v3.5.2

- **YTM album browse links (`MPREb_…`) now recognized** — pasting an album URL
  copied from the music.youtube.com address bar no longer fails with
  "unknown link type"; share links (`OLAK5uy_…`) and browse links are handled
  identically

<details>
<summary>v3.5.0 highlights</summary>

- **New title-extraction engine** for radios & MV playlists: book-title/bracket rules replace naive `" - "` splitting; uploader cross-matching; verified on 118 real radio tracks
- **Renaming for no-metadata radio tracks**: extracted `artist - title` is applied to both tags and filenames (duplicate-safe rename)
- **Meta safety net in MV mode**: when full info.json metadata exists, it overrides manually prefilled values
- **Track selection rebuilt**: whiptail native checklist with a "select all" item, or type ranges like `1,2,3-5,9`; `0`/`b` steps back
- **Per-step state machine**: every interactive step can go back one step
- **Subfolder semantics**: create / rename / none — consistent between CLI and Web UI
- **Isolated venv**: yt-dlp + mutagen live in the project's `.venv` — delete the folder to fully uninstall

</details>

<details>
<summary>v3.2.0 highlights</summary>

- Multi-artist tag support (`feat.` / `ft.` / `&` splitting, VA handling)
- Standard `ALBUMARTIST` field
- Removed download throttling (no more HTTP 403 from anti-bot detection)

</details>

## 📋 Requirements

* **bash 4.0+**
* `ffmpeg`
* `python3` (with `venv`)
* `node` ≥ 20 (optional, for concurrency)

> **⚠️ macOS Users Note:** macOS ships with Bash 3.2; install Bash 4+ via Homebrew (`brew install bash`). yt-dlp and mutagen are installed into the project venv automatically by `mf_setup.sh`.

## 📦 Quick Start

```bash
git clone https://github.com/Unclezhanger/musicfeed.git
cd musicfeed

# One-time setup (deps check + one-click install, music path, audio format)
bash mf_setup.sh

# Start downloading
bash musicfeed.sh
```

## 🖥️ Prefer a Web UI?

This repo is the **CLI edition**. The companion project [**mfui**](https://github.com/Unclezhanger/mfui) adds:

- A web interface (paste links, pick tracks, configure, download — with live logs)
- Multi-link queue downloads with unified progress
- PWA support (install on your phone, share links straight into the download queue)
- **Docker** distribution (single container, recommended for NAS/home-server users)

Both share the same download kernel — your `mf_config.sh` works in either.

## 📁 Project Structure

| File | Purpose |
|------|---------|
| `musicfeed.sh` | Main script (self-contained) |
| `mf_setup.sh` | Setup wizard |
| `mf_config.sh` | Generated config (do not edit manually) |

## ⚠️ Disclaimer

For personal and educational use only. Please respect copyright laws in your region. The author assumes no liability for any misuse.

## 📄 License

MIT License © 2026 Unclezhanger
