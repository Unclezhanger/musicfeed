[![English](https://img.shields.io/badge/lang-English-blue.svg)](README.md)
[![中文](https://img.shields.io/badge/lang-中文-red.svg)](README_zh.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)]()
[![Bash](https://img.shields.io/badge/bash-4%2B-green.svg)]()

# 🎵 musicfeed

**专为 YouTube Music 生态设计的智能批量下载器。**

大多数工具对所有 YouTube 链接一视同仁。musicfeed 不一样。

## 🆚 它有什么不同

### 1. 封面处理，真的符合预期

YouTube Music 把专辑封面填充成 16:9 的缩略图。工具如何处理这个决定了你的音乐库看起来是否正常。

musicfeed 在决定如何处理封面之前，**先读取每条音轨的元数据**：

| 音轨类型 | 封面处理方式 |
| --- | --- |
| YTM 音轨（有元数据） | 1:1 中心裁剪 — 恢复原始的方形专辑封面 |
| MV / 视频音轨（无元数据） | 仅压缩，保持原始宽高比 |
| YTM 专辑（统一模式） | 直接下载播放列表级别的缩略图 — 真正的方形专辑封面 |

### 2. 四种链接类型，四种不同策略

musicfeed 在询问任何问题之前，先检测链接类型：

| 链接类型 | 检测方式 | 策略 |
| --- | --- | --- |
| YTM 专辑 | URL 中包含 `OLAK5uy_` | 统一专辑封面 + `album_artist` 标签，以便在库中正确分组 |
| YTM 电台 / 合集 | URL 中包含 `RDCLAK5uy_` | 每条音轨独立封面 |
| YouTube 播放列表 | URL 中包含 `PL...` | MV 模式：手动逐轨输入或自动策略 |
| 单曲 | URL 中包含 `watch?v=` | 相同的元数据检查，相同的智能封面决策 |

### 3. 为自托管音乐库准备的正确 ID3 标签

每条音轨的 `album_artist` 标签都会被正确写入。这对 Navidrome 和 Jellyfin 至关重要 —— 没有它，多艺术家专辑会在你的库中分裂成多个条目。

### 4. 双音频格式支持

在 `mf_setup.sh` 中一次选择你的格式：

* **Opus**（默认）—— 更高音质（约 160kbps VBR），文件更小
* **M4A** —— Apple 设备原生支持，无需为 CarPlay / AirPlay / 本地播放转码

## 🆕 v3.0.0 更新亮点

### 🎵 播放列表支持增强
- **大型播放列表处理**：得益于 yt-dlp 的近期更新，musicfeed 现在能成功下载超过100首的播放列表，突破了之前的限制。
- **全球榜单集成**：内置支持同步全球热门榜单（如“热门音频视频每日排行榜 - 全球”），通过专用配置即可启用。

### 🖥️ 交互体验优化
- **智能终端分页**：播放列表和文件夹选择现在会根据你的终端大小自动分页，确保大型库的显示整洁且易于管理。
- **配置流程简化**：设置向导现在提供更简洁、更流畅的配置流程，带有更好的默认值和更清晰的提示。

### 📁 文件夹管理增强
- **智能隐藏文件夹**：自动检测并管理应从歌手列表中隐藏的系统生成文件夹（如 `.DS_Store`、`@eaDir`）。

## 📋 系统要求

* **bash 4.0+**
* **yt-dlp**（必须是最新版本）
* `ffmpeg`
* `python3` + **mutagen** (`pip3 install mutagen`)
* `node`（可选但推荐）

> **⚠️ macOS 用户注意：**

> 本项目需要 Bash 4.0+。macOS 自带的 Bash 版本过旧（3.2）。

旧版 macOS 安装问题：
在旧版 macOS（如 Catalina）上，通过 Homebrew 安装 Bash 4 (`brew install bash`) 时可能会因编译问题导致卡死或安装失败。

解决方案：
建议直接下载 已编译的 Bash 二进制包（如 `osx-brew-builds` 提供的版本）进行手动安装，跳过编译步骤。

## 📦 快速开始

```bash
git clone https://github.com/Unclezhanger/musicfeed.git
cd musicfeed

# 一次性设置（选择音乐路径、默认文件夹、音频格式）
bash mf_setup.sh

# 开始下载
bash musicfeed.sh
```

`mf_setup.sh` 会自动检测所有依赖并引导你完成配置。

## 📁 项目结构

| File | Purpose |
|------|---------|
| `musicfeed.sh` | 主下载脚本 |
| `mf_setup.sh` | 交互式设置向导 |
| `mf_config.sh` | 自动生成的配置文件（请勿手动编辑） |


## ⚠️ 免责声明

仅供个人和教育用途。请尊重你所在地区的版权法。作者对任何滥用不承担任何责任。

## 📄 许可证

MIT 许可证 © 2026 Unclezhanger
