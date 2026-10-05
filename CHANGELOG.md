## v4.1 (2026-10-05)

### Selection-parsing hardening
- Track-selection input is no longer trimmed with `xargs`, which silently
  interpreted quotes and backslashes (`1\2` selected track 12, `1"` or a
  whitespace-only input downloaded ALL tracks) — whitespace is trimmed with
  pure parameter expansion now
- An empty parse result is `INVALID:empty` instead of "select all" (callers
  already map Enter/a to an explicit ALL, so an empty result can only mean
  a broken parse)
- `mf_setup.sh`: invalid or out-of-range fragments fail the whole selection
  instead of being silently dropped, and the numeric checklist retries on
  invalid input (Enter = select none, unchanged)

### Directory listing
- All 4 `ls -F | grep '/$'` listing sites replaced with
  `find -L … -print0 | sort -z`: symlinked directories now show up (GNU
  `ls -F` marks them `@`, so the old pipeline silently skipped them), and
  directory names containing newlines can no longer tear the list into
  phantom entries; dot-directories stay excluded, ordering preserved
- macOS: the setup directory browser now also needs GNU `head -z` /
  `sort -z` (`brew install coreutils findutils`) — or run the mfui container

### Cover & metadata pairing
- Fixed: very long "artist - title" names silently lost the embedded cover.
  yt-dlp's `--trim-filenames` misreads dots inside the base name
  (`rsplit('.', 2)` treats `feat.` or artist names like `asiatic.wav` as
  extension separators), so the `.info.json` and the audio file could end
  up with different names and the worker skipped tagging/cover for that
  track without any warning. Filename length is now capped at the yt-dlp
  template level (`%(artist,uploader).50s - %(title).25s`), which keeps both
  names identical
- The `artist` tag now comes from the JSON metadata (`.artist`) when
  available instead of being derived from the filename; also fixed a
  stale per-file variable in the enhanced-mode post-processing loop

### Fixed
- The run summary (and the 150-track-per-run cap) under-counted by one for
  any link with exactly one track — single-track albums, playlists and
  radios all skip the track-selection step, but the "always 1 track"
  compensation previously applied only to single-video links
- Backspace-editing Chinese text in free-text inputs (tags, artist,
  subfolder names) no longer produces garbled/misaligned text: those
  prompts now use readline (`read -e`), which edits by character and
  display width instead of the kernel tty's byte-wise erase — this also
  brings arrow-key editing and (in the manual path prompt) Tab completion
- Radio no-metadata extraction: label-official-MV titles following the
  `artist [ song ] Official MV` convention no longer lose the song to a
  trailing attribution bracket (e.g. `- 公視《劇名》影集插曲`) — a
  left-to-right scan of `[ … ]` groups now prefers the first one whose
  artist prefix is short, verified against 188 real playlist/radio titles
  with zero regressions (e.g. 蘇慧倫 Tarcy Su [ 貴得可以 Not Expensive At
  All ]… now extracts 貴得可以 Not Expensive At All / 蘇慧倫 Tarcy Su
  instead of 欠妳的那場婚禮 / uploader)

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
