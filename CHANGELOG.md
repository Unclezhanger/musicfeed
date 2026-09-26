## v4.0 (2026-09-27)

### Zero-Python kernel
- Tagging & cover embedding migrated from python3+mutagen to a pure-ffmpeg
  engine: existing tags merged via an ffmetadata file (no ARG_MAX limits),
  hand-constructed FLAC Picture blocks for Opus covers (byte-equivalent to
  mutagen's output, plus real width/height), JPEG covers stream-copied
  byte-identical into M4A, audio always `-c:a copy`
- JSON metadata parsing migrated from python3 to jq
- Radio/community-list title extraction rewritten in pure bash+grep+sed,
  verified byte-for-byte against the previous Python engine across all
  algorithm branches
- Runtime dependencies are now: bash 4+, ffmpeg, jq, curl/wget (node
  recommended as the yt-dlp JS runtime) — python3 no longer needed

### yt-dlp lifecycle management
- yt-dlp now ships as the official standalone binary (no pip, no venv)
- New setup step on every run: keep current / update to latest stable /
  switch to nightly — a yt-dlp broken by a YouTube anti-bot update is fixed
  by re-running the wizard, no manual binary deletion
- Dependency checks warn on macOS about the GNU sed/base64 requirement

### Concurrency hardening
- Per-library-folder flock serialization (MF_FLOCK_TIMEOUT tunable; on
  timeout a warning is logged and the task proceeds) — prevents yt-dlp
  same-name .part collisions when several runs target one folder
- Worker temp files PID-scoped (temp_$$_mv_*): concurrent runs can no longer
  delete or misread each other's temp downloads, info.json or covers; one-
  time sweep of pre-4.0.8 legacy temp_mv_* leftovers on first run
- Fixed: playlist parsing dropped empty fields (IFS tab collapsing shifted
  uploader/album/artist columns and misflagged has_meta); empty album
  entries produced a phantom "Unknown" track; M4A covers were silently
  re-encoded (now embedded byte-identical via -c:v copy for JPEG sources)

### CLI fixes & setup UX
- Fixed: multi-link runs double-counted tracks (singles inherited the
  previous link's selection count and a stale --playlist-items could leak
  into the worker); per-link state is now reset and singles count as 1 track
- Setup: dependency results shown in a summary dialog (all-green or missing
  + one-click install); every config step supports Esc-to-go-back (state
  machine); NODE_PATH env var no longer leaks into the generated config;
  hidden-folder selection no longer emits an empty ('' ) entry; removed a
  stale comment from the config template

## v3.5.2 (2026-09-06)

### YTM album browse links
- `get_link_type` now recognizes `MPREb_…` URLs (album/release pages copied
  from the music.youtube.com address bar) as album type — previously only
  share links (`OLAK5uy_…`) were accepted and address-bar links failed with
  "unknown link type"
- Both id families point to the same album entity and are handled identically

# Changelog — musicfeed kernel

## v3.5.0 (2026-08-30)

### Title extraction engine rebuild
- Removed naive `" - "` title splitting (misfired on radios and MV playlists)
- New `extract_nm_info`: book-title `《》` / bracket pollution-word stripping,
  uploader ↔ title cross-matching, blind prefix guess as fallback
- Verified against 118 real radio tracks (mixed languages, full-width brackets,
  dirty suffixes) with known graceful degradations

### No-metadata radio track renaming
- Extracted `artist - title` now applied to filenames as well as tags, in all
  four post-processing paths (batch/CLI × normal/enhanced)
- Duplicate-safe rename: if the target name already exists, the new copy is
  removed (aligns with the skip-existing dedup semantics)

### MV mode meta safety net
- In MV manual mode, complete info.json metadata (artist + album) now
  overrides manually prefilled values — preview heuristics can miss

### TUI / UX
- Track selection: native whiptail checklist with a pinned "select all" item;
  numeric fallback accepts ranges (`1,2,3-5,9`); `0`/`b` goes back
- Per-step state machine in the interactive flow — every step can step back
- Subfolder semantics: create / rename / none (`none` flattens into the
  artist folder); consistent with the Web UI
- `mf_setup.sh` fully wizard-driven: language, one-click dependency install
  (system packages via sudo, yt-dlp/mutagen into project venv), directory
  browser, hidden-folder multi-select

### Packaging
- Scripts are self-contained; `mf_lib.sh` is inlined at build time

## v3.2.0

- Multi-artist tag support (`feat.` / `ft.` / `&` / `,` splitting, VA handling)
- Standard `ALBUMARTIST` Vorbis field
- Removed artificial download throttling (anti-bot 403 fix)
