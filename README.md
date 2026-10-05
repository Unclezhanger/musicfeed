[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md)
[![中文](https://img.shields.io/badge/lang-中文-red.svg)](README_zh.md)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Docker-lightgrey.svg)]()
[![Bash](https://img.shields.io/badge/bash-4%2B-green.svg)]()
[![Python](https://img.shields.io/badge/python-free-success.svg)]()
[![Release](https://img.shields.io/badge/release-v4.1-success.svg)]()

# 🎵 musicfeed

**Intelligent batch downloader for the YouTube Music ecosystem.**

Most tools treat every YouTube link the same. musicfeed doesn't.

**v4.0 is a ground-up rework of the download kernel: it now runs with zero
Python — tagging, covers, JSON parsing and title extraction are all handled
by `ffmpeg`, `jq` and plain Bash.**

## 🖼️ The result

One album link + four singles from different albums, downloaded and dropped
into [Navidrome](https://www.navidrome.org/) — every track with the correct
cover, `album` / `album_artist` tags and a clean `artist - title` filename:

![Navidrome library result](docs/navidrome-result.png)

*Left to right: a full YTM album (unified cover) and four singles with
per-track MV covers — every MV single is tagged with album = song title, so
each lands in its own album entry with the matching cover and proper tags.*

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

In v4.0 the whole engine was ported from Python to pure Bash + `grep`/`sed`,
verified byte-for-byte against the previous implementation across every
branch of the algorithm.

### 4. Correct tags for self-hosted libraries

`album_artist` is written correctly on every track. This matters for Navidrome and Jellyfin — without it, multi-artist albums split into multiple entries in your library.

Tagging runs entirely through `ffmpeg` now: existing tags are merged, not
wiped; the audio stream is stream-copied (`-c:a copy`, bit-identical); covers
are embedded as real `attached_pic` streams (M4A) or standard
`METADATA_BLOCK_PICTURE` comments (Opus) — verified readable by Navidrome,
Jellyfin and Mutagen alike.

### 5. A setup wizard that also manages yt-dlp for you

`mf_setup.sh` checks every dependency, shows the result in a summary dialog
(✅ all green, or ❌ exactly what's missing), and can **one-click install**
everything — system packages via sudo, yt-dlp as the official **standalone
binary** (no pip, no venv).

YouTube's anti-bot updates regularly break older yt-dlp builds, so the wizard
also asks on every run:

- **Keep current version**
- **Update to latest stable**
- **Switch to nightly** (tracks anti-bot fixes faster)

Re-running the wizard is always enough to refresh a broken yt-dlp — no
manual binary deletion, no pip.

The interactive UI degrades gracefully: `whiptail` → arrow-key menu →
numeric input, and every config step supports **Esc to go back**.

### 6. Safe to run concurrently

Each library folder is serialized with `flock` and worker temp files are
PID-scoped — launching several downloads into the same folder no longer
races on temp files, info.json or covers. (Timeout tunable via
`MF_FLOCK_TIMEOUT`.)

## 🆕 What's New in v4.1

- **Hardened track-selection input** — quotes, backslashes or
  whitespace-only input can no longer trigger "download all" or silently
  pick the wrong track; the setup wizard's numeric menus retry on invalid
  input instead of dropping it
- **Symlinked folders now appear** in the artist-folder picker (GNU `ls -F`
  marks them `@`, so the old pipeline skipped them), and directory names
  containing newlines can no longer corrupt the list
- **Fixed**: very long "artist - title" names silently lost their embedded
  cover (yt-dlp filename trimming desynced the audio file from its metadata
  JSON); the artist tag is now taken from the JSON metadata instead of the
  filename
- macOS now additionally needs GNU `head -z`/`sort -z` — `brew install
  coreutils findutils`, or use the mfui container

## 🆕 What's New in v4.0

- **Zero-Python kernel** — tagging/covers via `ffmpeg` (existing tags merged,
  audio stream-copied bit-identical, hand-built FLAC Picture blocks for Opus),
  JSON via `jq`, title extraction in pure Bash
- **yt-dlp as a standalone binary** with stable/nightly channel management in
  the setup wizard
- **Concurrency hardening**: per-folder `flock` + PID-scoped temp files
- **Fixed**: multi-link runs double-counted tracks (singles inherited the
  previous link's selection count); playlist parsing lost empty fields;
  empty album entries produced a phantom track; M4A covers were silently
  re-encoded (now embedded byte-identical)
- **Setup UX**: dependency summary dialogs, full back navigation, macOS
  advisory

<details>
<summary>v3.5.x highlights</summary>

- Title-extraction engine for radios & MV playlists: book-title/bracket rules, uploader cross-matching; verified on 118 real radio tracks
- Renaming for no-metadata radio tracks (duplicate-safe), metadata safety net in MV mode
- Track selection: whiptail checklist with "select all" + range input (`1,2,3-5,9`); per-step state machine
- YTM album browse links (`MPREb_…`) recognized
- Multi-artist tag support, standard `ALBUMARTIST` field, no download throttling

</details>

## 📋 Requirements

* **bash 4.0+**
* `ffmpeg` (tagging, covers, audio conversion)
* `jq` (metadata parsing)
* `curl` or `wget` (fetches the yt-dlp binary)
* `node` ≥ 20 (recommended — used by yt-dlp as a JS runtime for some links)

> No Python at all — the venv/mutagen stack from v3.x is gone.

> **⚠️ macOS Users Note:** v4.0's tagging pipeline uses GNU `sed`/`base64`
> flags that BSD tools don't support — install `brew install gnu-sed
> coreutils` and put their gnubin/gsed paths first in `PATH` (the setup
> wizard prints this warning automatically). `whiptail` is optional; the UI
> falls back to arrow-key menus.

## 📦 Quick Start

```bash
git clone https://github.com/Unclezhanger/musicfeed.git
cd musicfeed

# One-time setup: dependency check + one-click install, yt-dlp channel,
# music library path, audio format (opus / m4a)
bash mf_setup.sh

# Start downloading
bash musicfeed.sh
```

If downloads ever start failing en masse (YouTube anti-bot update), just run
`bash mf_setup.sh` again and pick **Update to latest stable** or **Switch to
nightly**.

## 🖥️ Prefer a Web UI?

This repo is the **CLI edition**. The companion project [**mfui**](https://github.com/Unclezhanger/mfui) adds:

- A web interface (paste links, pick tracks, configure, download — with live logs)
- Multi-link queue downloads with unified progress
- PWA support (install on your phone, share links straight into the download queue)
- **Docker** distribution (single container, recommended for NAS/home-server users)

Both share the same download kernel design — your `mf_config.sh` works in
either. (mfui is being adapted to the v4.0 kernel.)

## 📁 Project Structure

| File | Purpose |
|------|---------|
| `musicfeed.sh` | Main script (self-contained) |
| `mf_setup.sh` | Setup wizard (deps, yt-dlp channel, config) |
| `mf_config.sh` | Generated config (do not edit manually) |

## ⚠️ Disclaimer

For personal and educational use only. Please respect copyright laws in your region. The author assumes no liability for any misuse.

## 📄 License

MIT License © 2026 Unclezhanger
