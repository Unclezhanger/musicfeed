# Changelog - musicfeed v3.2.0
Date: 2026-08-15

## 🚀 Major Changes / 主要变更

### 1. Removed Download Throttling Logic / 移除下载限流逻辑
- **Issue**: HTTP 403 errors occurred with sleep-delay mechanisms triggering YouTube's anti-bot detection.
  **问题**: 睡眠延迟机制触发 YouTube 反爬虫机制，导致 HTTP 403 错误。
- **Fix**: Completely removed `SLEEP_REQUESTS` and `SLEEP_INTERVAL` configurations from both `musicfeed.sh` and `mf_setup.sh`. Now relies on yt-dlp's built-in smart retry mechanism.
  **修复**: 彻底移除 `SLEEP_REQUESTS` 和 `SLEEP_INTERVAL` 配置。现依赖 yt-dlp 内置的智能重试机制。
- **Result**: Stable download performance, no more 403 errors.
  **效果**: 下载性能稳定，不再出现 403 错误。

### 2. Multi-Artist Tag Smart Splitting / 多艺人标签智能拆分
- **Feature**: Automatically splits artist names by common delimiters (`,`, `&`, `feat.`, `ft.`, `with`, `vs.`).
  **功能**: 自动识别并拆分常见分隔符（`,`、`&`、`feat.`、`ft.`、`with`、`vs.`）。
- **Format Support**: 
  - Opus: Writes multi-value `artist` field (Vorbis Comments standard)
  - M4A: Writes multi-value `\xa9ART` field (MP4 atom standard)
  **格式支持**: 
  - Opus: 写入多值 `artist` 字段（Vorbis Comments 标准）
  - M4A: 写入多值 `\xa9ART` 字段（MP4 原子标准）
- **Compatibility**: Perfect display in Navidrome, Jellyfin, Music Tag Web.
  **兼容性**: 在 Navidrome、Jellyfin、Music Tag Web 中完美显示。

### 3. Album Artist Field Standardization / 专辑艺人字段标准化
- **Opus**: Changed from `album_artist` to `ALBUMARTIST` (uppercase, Vorbis Comments standard).
  **Opus**: 从 `album_artist` 改为 `ALBUMARTIST`（大写，Vorbis Comments 标准）。
- **M4A**: Uses `aART` (MP4 atom standard).
  **M4A**: 使用 `aART`（MP4 原子标准）。

### 4. Codebase Cleanup / 代码库清理
- Refactored to a cleaner structure based on v3.0.0 stable core.
  基于 v3.0.0 稳定核心重构为更清晰的代码结构。
- Removed experimental whiptail/dialog UI code for future implementation.
  移除实验性的 whiptail/dialog UI 代码，留待未来版本实现。
- Enhanced error handling and logging robustness.
  增强错误处理和日志记录的健壮性。

## 📝 Documentation Updates / 文档更新

- README.md & README_zh.md: Updated to reflect v3.0.0 → v3.2.0 feature jump.
  **README**: 更新以反映从 v3.0.0 到 v3.2.0 的功能跨越。
- "Global Charts Auto-Sync" marked as Roadmap item.
  **"全球榜单自动同步"** 已标记为未来计划。
- Clear installation and usage instructions.
  **清晰的安装和使用说明**。

## 🛠️ Technical Details / 技术细节

- Deleted functions: `apply_sleep_delay()`, all SLEEP_* variable references.
  **删除的函数**: `apply_sleep_delay()` 及所有 SLEEP_* 变量引用。
- Added Python function: `split_artists()` for intelligent delimiter recognition.
  **新增 Python 函数**: `split_artists()` 用于智能分隔符识别。
- Modified functions: `mv_write_id3()`, `embed_cover()` for multi-artist support.
  **修改的函数**: `mv_write_id3()`、`embed_cover()` 支持多艺人。

## ⬆️ Upgrade from v3.0.0 / 从 v3.0.0 升级

1. Backup your config: `cp mf_config.sh mf_config.sh.bak`
   备份配置：`cp mf_config.sh mf_config.sh.bak`
2. Replace scripts: Copy new `musicfeed.sh` and `mf_setup.sh`
   替换脚本：复制新的 `musicfeed.sh` 和 `mf_setup.sh`
3. Re-run setup (optional): `bash mf_setup.sh` to clean old sleep settings
   重新运行配置（可选）：`bash mf_setup.sh` 清理旧的睡眠设置
4. Test download: Try a multi-artist track to verify tag splitting
   测试下载：尝试多艺人曲目验证标签拆分

---
**Full Version History / 完整版本历史**
- v3.0.0: Initial stable release with smart cover processing
- v3.1.x: Development versions (not publicly released)
- v3.2.0: Stable release with multi-artist tags & throttling removal
