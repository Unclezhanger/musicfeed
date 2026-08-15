# Changelog - musicfeed v3.2.0

**Date:** 2026-08-15

---

## English

### 🏷️ Multi-Artist Tag Support
- **Smart artist splitting**: Automatically recognizes separators like `feat.`, `ft.`, `&`, `,`, `with`, `vs.` in track titles.
- **Correct metadata format**: Writes multiple artists as separate values in Opus (Vorbis Comments) and M4A (MP4 atoms) formats.
- **Perfect compatibility**: Displays correctly in Navidrome, Jellyfin, and Music Tag Web.

### 🛠️ Album Artist Standardization
- **ALBUMARTIST field**: Uses the standard Vorbis Comments field name for proper library organization.
- **VA handling**: Correctly handles Various Artists compilations.

### 🚫 Removed Download Throttling
- **No more HTTP 403 errors**: Removed artificial sleep delays that triggered YouTube's anti-bot detection.
- **Smart retry mechanism**: Relies on yt-dlp's built-in intelligent retry logic for better success rates.

### 🧹 Code Cleanup
- **Back to stable core**: Refactored based on v3.0.0 stable kernel for maximum reliability.
- **Cleaner codebase**: Removed experimental features for a focused, maintainable codebase.

---

## 中文

### 🏷️ 多艺人标签支持
- **智能艺人拆分**：自动识别音轨标题中的分隔符，如 `feat.`、`ft.`、`&`、`,`、`with`、`vs.`。
- **正确的元数据格式**：在 Opus（Vorbis Comments）和 M4A（MP4 atoms）格式中将多个艺人写入为独立的值。
- **完美兼容**：在 Navidrome、Jellyfin 和 Music Tag Web 中正确显示多个艺人。

### 🛠️ 专辑艺人字段标准化
- **ALBUMARTIST 字段**：使用标准的 Vorbis Comments 字段名，确保音乐库正确组织。
- **VA 处理**：正确处理 Various Artists（合辑）类型。

### 🚫 移除下载限流
- **不再出现 HTTP 403 错误**：移除了触发 YouTube 反爬虫机制的人工延迟。
- **智能重试机制**：依赖 yt-dlp 内置的智能重试逻辑，提高下载成功率。

### 🧹 代码清理
- **回归稳定内核**：基于 v3.0.0 稳定内核重构，确保最大可靠性。
- **更干净的代码库**：移除实验性功能，保持代码专注且易于维护。

---

## Technical Details / 技术细节

- Removed `SLEEP_REQUESTS` and `SLEEP_INTERVAL` configuration options and related code.
  删除了 `SLEEP_REQUESTS` 和 `SLEEP_INTERVAL` 配置选项及相关代码。

- Added `split_artists()` function in post-processing stage for multi-artist tag handling.
  在后处理阶段添加 `split_artists()` 函数用于多艺人标签处理。

- Changed Opus format album artist field from `album_artist` to `ALBUMARTIST` (uppercase, standard Vorbis Comments).
  将 Opus 格式的专辑艺人字段从 `album_artist` 改为 `ALBUMARTIST`（大写，标准 Vorbis Comments）。

- Refactored codebase based on v3.0.0 stable version for improved reliability.
  基于 v3.0.0 稳定版本重构代码库以提高可靠性。
