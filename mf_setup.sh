#!/bin/bash
# ─────────────────────────────────────────────
# musicfeed setup V3.0.0
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/mf_config.sh"

# 默认配置
MF_LANG="${MF_LANG:-zh}"
MF_BASE_DIR="${MF_BASE_DIR:-$HOME/navidrome/music}"
MF_DEFAULT_ARTIST_DIR="${MF_DEFAULT_ARTIST_DIR:-musicfeed}"
MF_AUDIO_FORMAT="${MF_AUDIO_FORMAT:-opus}"
MF_PLAYLIST_SLEEP_REQUESTS="${MF_PLAYLIST_SLEEP_REQUESTS:-0}"
MF_PLAYLIST_SLEEP_INTERVAL="${MF_PLAYLIST_SLEEP_INTERVAL:-0}"
MF_NODE_PATH="${MF_NODE_PATH:-}"

echo "=================================================="
echo " 🎵 musicfeed 配置引导 V3.0.0"
echo "=================================================="
echo ""

# 检测 macOS 版本
OS_TYPE="unknown"
NEED_MANUAL_INSTALL=0

if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
    MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    if [[ "$MACOS_VERSION" -le 11 ]]; then
        NEED_MANUAL_INSTALL=1
    fi
fi

say() {
    if [ "$MF_LANG" = "en" ]; then printf "%s\n" "$2"; else printf "%s\n" "$1"; fi
}

ask() {
    if [ "$MF_LANG" = "en" ]; then printf "%s" "$2"; else printf "%s" "$1"; fi
}

# ── 依赖检测 ──

say "🔍 检查依赖..." "🔍 Checking dependencies..."

# Bash 4+
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    say "❌ Bash 版本过低: ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" "❌ Bash version too low: ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
    if [ "$OS_TYPE" = "macos" ]; then
        if [ "$NEED_MANUAL_INSTALL" -eq 1 ]; then
            say "💡 macOS Big Sur 或更旧：强烈不建议使用 Homebrew（会触发漫长的源码编译）。" \
                "💡 macOS Big Sur or older: Strongly NOT recommended to use Homebrew (will trigger slow source builds)."
            say "   建议手动编译 Bash 5.x，示例：" \
                "   Recommend manually building Bash 5.x, example:"
            echo ""
            echo "  curl -O https://ftp.gnu.org/gnu/bash/bash-5.2.21.tar.gz"
            echo "  tar xf bash-5.2.21.tar.gz && cd bash-5.2.21"
            echo "  ./configure --prefix=/usr/local"
            echo "  make && sudo make install"
            echo "  sudo sh -c 'echo /usr/local/bin/bash >> /etc/shells'"
            echo "  chsh -s /usr/local/bin/bash"
            echo ""
        else
            say "   macOS: brew install bash" "   macOS: brew install bash"
        fi
    else
        say "   Linux: 使用系统包管理器或手动编译 Bash 5.x" \
            "   Linux: use system package manager or build Bash 5.x from source"
    fi
    say "   安装后重新运行本脚本。" "   Re-run this script after installation."
    exit 1
else
    say "✅ Bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" "✅ Bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
fi

# Python 3
PYTHON_VERSION=$(python3 -c 'import sys; print(sys.version_info.major*100+sys.version_info.minor)' 2>/dev/null || echo 0)
if [ "$PYTHON_VERSION" -lt 309 ]; then
    say "❌ Python 版本过低 (< 3.9)，yt-dlp 需要至少 Python 3.9" \
        "❌ Python version too low (< 3.9), yt-dlp requires Python 3.9+"
    if [ "$OS_TYPE" = "macos" ]; then
        if [ "$NEED_MANUAL_INSTALL" -eq 1 ]; then
            say "💡 macOS Big Sur：强烈建议从 python.org 下载官方 .pkg 安装：" \
                "💡 macOS Big Sur: strongly recommend downloading the official .pkg from python.org:"
            echo "  https://www.python.org/downloads/"
            say "   安装后运行：" "   After install, run:"
            echo '  /Applications/Python\ 3.12/Install\ Certificates.command'
        else
            say "   macOS: brew install python@3.11" "   macOS: brew install python@3.11"
        fi
    else
        say "   Linux: 使用系统包管理器安装 python3.9+ 或从源码编译" \
            "   Linux: use system package manager to install python3.9+ or build from source"
    fi
    exit 1
else
    say "✅ Python $(python3 -c 'import sys; print(sys.version_info.major)+"."+str(sys.version_info.minor)')" \
        "✅ Python $(python3 -c 'import sys; print(sys.version_info.major)+"."+str(sys.version_info.minor)')"
fi

# yt-dlp
if ! command -v yt-dlp &>/dev/null; then
    say "❌ 未找到 yt-dlp" "❌ yt-dlp not found"
    if [ "$OS_TYPE" = "macos" ]; then
        say "   macOS: 建议使用 Python 3.12 安装：" "   macOS: recommend using Python 3.12:"
        echo '  /usr/local/bin/python3.12 -m pip install yt-dlp'
    else
        say "   Linux: python3 -m pip install --user yt-dlp" \
            "   Linux: python3 -m pip install --user yt-dlp"
    fi
    exit 1
else
    say "✅ yt-dlp $(yt-dlp --version 2>/dev/null || echo '?')" \
        "✅ yt-dlp $(yt-dlp --version 2>/dev/null || echo '?')"
fi

# ffmpeg
if ! command -v ffmpeg &>/dev/null; then
    say "❌ 未找到 ffmpeg" "❌ ffmpeg not found"
    if [ "$OS_TYPE" = "macos" ]; then
        if [ "$NEED_MANUAL_INSTALL" -eq 1 ]; then
            say "💡 macOS Big Sur：强烈不建议 brew install ffmpeg（会编译几十个依赖）。" \
                "💡 macOS Big Sur: strongly NOT recommended to brew install ffmpeg (will build many deps)."
            say "   建议从 evermeet.cx 下载预编译二进制：" \
                "   Recommend downloading prebuilt binary from evermeet.cx:"
            echo "  https://evermeet.cx/ffmpeg/"
            say "   解压后执行：" "   After unzip, run:"
            echo "  sudo cp ffmpeg /usr/local/bin/"
            echo "  sudo chmod +x /usr/local/bin/ffmpeg"
        else
            say "   macOS: brew install ffmpeg" "   macOS: brew install ffmpeg"
        fi
    else
        say "   Linux: 使用系统包管理器安装 ffmpeg" \
            "   Linux: use system package manager to install ffmpeg"
    fi
    exit 1
else
    say "✅ ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')" \
        "✅ ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')"
fi

# mutagen
if ! python3 -c 'import mutagen' 2>/dev/null; then
    say "❌ 未找到 Python mutagen 库" "❌ Python mutagen not found"
    say "   安装：python3 -m pip install mutagen" \
        "   Install: python3 -m pip install mutagen"
    exit 1
else
    say "✅ mutagen installed" "✅ mutagen installed"
fi

echo ""

# ── 配置项 ──

say "📝 配置路径：" "📝 Configure paths:"

ask " 音乐库根目录 [回车=$MF_BASE_DIR]: " \
    " Music library root [Enter=$MF_BASE_DIR]: "
read -r BASE_INPUT
[ -n "$BASE_INPUT" ] && MF_BASE_DIR="$BASE_INPUT"

ask " 默认歌手文件夹 [回车=$MF_DEFAULT_ARTIST_DIR]: " \
    " Default artist folder [Enter=$MF_DEFAULT_ARTIST_DIR]: "
read -r ARTIST_INPUT
[ -n "$ARTIST_INPUT" ] && MF_DEFAULT_ARTIST_DIR="$ARTIST_INPUT"

ask " 音频格式 (opus/m4a) [回车=$MF_AUDIO_FORMAT]: " \
    " Audio format (opus/m4a) [Enter=$MF_AUDIO_FORMAT]: "
read -r FORMAT_INPUT
[ -n "$FORMAT_INPUT" ] && MF_AUDIO_FORMAT="$FORMAT_INPUT"

ask " 语言 (zh/en) [回车=$MF_LANG]: " \
    " Language (zh/en) [Enter=$MF_LANG]: "
read -r LANG_INPUT
[ -n "$LANG_INPUT" ] && MF_LANG="$LANG_INPUT"

# 可选：yt-dlp 路径
ask " yt-dlp 路径 [回车=自动检测]: " \
    " yt-dlp path [Enter=auto detect]: "
read -r YTDLP_INPUT
[ -n "$YTDLP_INPUT" ] && MF_YTDLP="$YTDLP_INPUT" || MF_YTDLP="yt-dlp"

# 可选：Node 路径
if command -v node &>/dev/null; then
    ask " Node.js 路径（可选，回车跳过）: " \
        " Node.js path (optional, Enter to skip): "
    read -r NODE_INPUT
    [ -n "$NODE_INPUT" ] && MF_NODE_PATH="$NODE_INPUT"
fi

# ── 写入配置文件 ──

say "" ""
say "📝 生成配置文件: $CONFIG_FILE" "📝 Generating config: $CONFIG_FILE"

cat > "$CONFIG_FILE" << CONFEOF
# musicfeed 配置文件 V3.0.0
# 由 mf_setup.sh 自动生成，可手动编辑

MF_LANG="$MF_LANG"
MF_BASE_DIR="$MF_BASE_DIR"
MF_DEFAULT_ARTIST_DIR="$MF_DEFAULT_ARTIST_DIR"
MF_AUDIO_FORMAT="$MF_AUDIO_FORMAT"
MF_PLAYLIST_SLEEP_REQUESTS="$MF_PLAYLIST_SLEEP_REQUESTS"
MF_PLAYLIST_SLEEP_INTERVAL="$MF_PLAYLIST_SLEEP_INTERVAL"
MF_YTDLP="$MF_YTDLP"
MF_NODE_PATH="$MF_NODE_PATH"

# 隐藏目录（不会显示在歌手列表中）
MF_HIDDEN_DIRS=("attachments" "@eaDir" ".DS_Store")
CONFEOF

say "✅ 配置文件已生成" "✅ Config file generated"
say "   路径: $CONFIG_FILE" "   Path: $CONFIG_FILE"

echo ""
say "🚀 现在可以运行：" "🚀 Now you can run:"
echo "  bash musicfeed.sh"
say "   开始下载。" "   to start downloading."
