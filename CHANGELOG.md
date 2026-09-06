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
