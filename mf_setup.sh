#!/bin/bash
# ═════════════════════════════════════════════════
# musicfeed (音流) 配置引导脚本 mf_setup.sh
# v3.4: 全流程界面化（whiptail → 方向键 → 数字 三层降级，自包含不依赖 mf_lib）
# ═════════════════════════════════════════════════

# ── bash 版本检查 ──────────────────────────────
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo ""
    echo "❌ bash 4.0+ is required to run musicfeed."
    echo ""
    echo "  Your current bash version: $BASH_VERSION"
    echo ""
    echo "  macOS users:"
    echo "    brew install bash"
    echo "    Then run this script with the new bash:"
    echo "    /usr/local/bin/bash mf_setup.sh"
    echo ""
    echo "  Linux users: please upgrade bash via your package manager."
    echo ""
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/mf_config.sh"

# 语言默认 en，选完语言后切换（is_en 在 mf_setup 内自带，自包含）
MF_LANG="en"
is_en() { [ "$MF_LANG" = "en" ]; }

echo "=================================================="
echo " 🎵 musicfeed Setup / 配置引导"
echo "=================================================="
echo ""

# ═════════════════════════════════════════════════
# 内嵌迷你 UI（三层降级，与主脚本 mf_lib.sh 同风格 + 同 whiptail 主题）
# ═════════════════════════════════════════════════
m_ui_can_tui() { [ "${MF_TUI:-auto}" != "off" ] && [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; }
m_ui_readline() { if ( : < /dev/tty ) 2>/dev/null; then IFS= read -r "$1" < /dev/tty; else IFS= read -r "$1"; fi; }

# whiptail 主题：黑底 + 灰边 + 绿高亮（与主脚本一致，通过 NEWT_COLORS_FILE 隔离）
m_ensure_whiptail_theme() {
    if [ -z "${MF_WT_COMMON+x}" ]; then
        local f="${TMPDIR:-/tmp}/.mf_newt_colors_setup_$$"
        cat > "$f" 2>/dev/null <<'C' || return 0
root=white,black
border=gray,black
window=white,black
title=green,black
textbox=white,black
button=black,lightgray
compactbutton=gray,black
actbutton=black,green
checkbox=gray,black
actcheckbox=black,green
lists=white,black
actlist=black,green
helpline=gray,black
C
        export NEWT_COLORS_FILE="$f"
        MF_WT_COMMON=(--ok-button "$(is_en && echo 'OK (Enter)' || echo '确定 (Enter)')" \
                      --cancel-button "$(is_en && echo 'Back (Esc)' || echo '返回 (Esc)')")
    fi
    return 0
}
m_ui_has_whiptail() { [ "${MF_TUI:-auto}" != "bash" ] && m_ui_can_tui && command -v whiptail >/dev/null 2>&1 && m_ensure_whiptail_theme; }

m_ui_readkey() {
    local k seq
    IFS= read -rsn1 k < /dev/tty
    if [[ "$k" == $'\x1b' ]]; then
        IFS= read -rsn2 seq < /dev/tty || true
        case "$seq" in '[A') KEY=up;; '[B') KEY=down;; '[C') KEY=right;; '[D') KEY=left;; *) KEY=esc;; esac
    elif [[ -z "$k" ]]; then KEY=enter
    elif [[ "$k" == ' ' ]]; then KEY=space
    else KEY="$k"; fi
}
m_ui_clear() { printf '\033[%dA\033[J' "$1" >&2; }

# m_ui_menu "标题" 默认序号 "选项1" "选项2" ... → 输出序号
m_ui_menu() {
    local title="$1" def="${2:-1}"; shift 2
    local items=("$@") n=$#
    [ "$n" -eq 0 ] && return 1
    if m_ui_has_whiptail; then
        local args=(--title "$title" --menu "" 0 64 "$n") i sel
        for i in "${!items[@]}"; do args+=("$((i+1))" "${items[$i]}"); done
        sel=$(whiptail "${args[@]}" --default-item "$def" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return 1
        echo "$sel"; return 0
    fi
    if m_ui_can_tui; then
        local cur=$((def-1)) last=$((n-1)) redraw=1 i2
        while :; do
            if [ $redraw -eq 1 ]; then
                echo "" >&2
                printf '\033[1m%s\033[0m\n' "$title" >&2
                for i2 in "${!items[@]}"; do
                    if [ $i2 -eq $cur ]; then
                        printf '  \033[1;32m❯ ●\033[0m \033[1m%s\033[0m\n' "${items[$i2]}" >&2
                    else
                        printf '    ○  %s\n' "${items[$i2]}" >&2
                    fi
                done
                printf '\033[2m%s\033[0m\n' "$(is_en && echo '↑↓ move · Enter confirm · number jump' || echo '↑↓ 移动 · 回车 确认 · 数字 直达')" >&2
                redraw=0
            fi
            m_ui_readkey
            case "$KEY" in
                up)   [ $cur -gt 0 ] && { m_ui_clear $((n+3)); cur=$((cur-1)); redraw=1; } ;;
                down) [ $cur -lt $last ] && { m_ui_clear $((n+3)); cur=$((cur+1)); redraw=1; } ;;
                enter) echo "" >&2; echo $((cur+1)); return 0 ;;
                [1-9]) if [ "$KEY" -le "$n" ]; then m_ui_clear $((n+3)); echo "" >&2; echo "$KEY"; return 0; fi ;;
            esac
        done
    fi
    echo "" >&2
    printf '\033[1m%s\033[0m\n' "$title" >&2
    local i3 c
    for i3 in "${!items[@]}"; do echo "  [$((i3+1))] ${items[$i3]}" >&2; done
    while :; do
        m_ui_readline c
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ]; then echo "$c"; return 0; fi
        echo "$(is_en && echo '  Invalid, retry' || echo '  无效输入，重试')" >&2
    done
}

# m_ui_confirm "标题" 默认(y/n) → 0=是 1=否
m_ui_confirm() {
    local title="$1" def="${2:-y}" rc
    if m_ui_has_whiptail; then
        if [ "$def" = "y" ]; then whiptail --title "$title" --yesno "$title" 0 64 "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3; rc=$?
        else whiptail --title "$title" --yesno "$title" 0 64 --defaultno "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3; rc=$?; fi
        [ $rc -eq 255 ] && return 1
        return $rc
    fi
    local yn
    if [ "$def" = "y" ]; then echo -n "$title [Y/n]: " >&2; else echo -n "$title [y/N]: " >&2; fi
    m_ui_readline yn
    case "$yn" in n|N) return 1;; *) return 0;; esac
}

# m_ui_input "标题" 默认值 ["提示行"] → 输出文本
m_ui_input() {
    local title="$1" def="$2" prompt="${3:-}" v
    if m_ui_has_whiptail; then
        v=$(whiptail --title "$title" --inputbox "${prompt:-$title}" 0 64 "$def" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && { echo "$def"; return 0; }
        [ -z "$v" ] && v="$def"
        echo "$v"; return 0
    fi
    [ -n "$prompt" ] && printf '\033[2m%s\033[0m\n' "$prompt" >&2
    printf '%s \033[2m[%s]\033[0m: ' "$title" "$def" >&2
    local v2; m_ui_readline v2
    [ -z "$v2" ] && v2="$def"
    echo "$v2"
}

# 简易选号解析（"1,3,5-7" → "1,3,5,6,7"；空 → ""）
m_parse_sel() {
    local input="$1" max="$2" result="" part
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local s=${BASH_REMATCH[1]} e=${BASH_REMATCH[2]}
            if [ "$s" -ge 1 ] && [ "$e" -le "$max" ] && [ "$s" -le "$e" ]; then
                for ((i=s; i<=e; i++)); do result="${result}${result:+,}$i"; done
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "$max" ]; then
            result="${result}${result:+,}$part"
        fi
    done
    echo "$result"
}

# m_ui_checklist "标题"  条目经 stdin 传入 → 输出选中编号 "1,3,5"（可空）
# 默认全不选；whiptail 层空格勾选，数字层输入编号
m_ui_checklist() {
    local title="$1"
    local items=() line
    while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
    done
    local n=${#items[@]}
    [ "$n" -eq 0 ] && { echo ""; return 0; }

    if m_ui_has_whiptail; then
        local res s c t lh
        lh=$n; [ $lh -gt 15 ] && lh=15
        local args=(--title "$title" --checklist "" 0 72 $lh)
        for i in "${!items[@]}"; do
            args+=("$((i+1))" "${items[$i]}" off)
        done
        res=$(whiptail "${args[@]}" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && { echo ""; return 0; }
        s=""; c=0
        for t in $(printf '%s' "$res" | tr -d '"'); do
            if [[ "$t" =~ ^[0-9]+$ ]]; then s="${s}${s:+,}$t"; c=$((c+1)); fi
        done
        echo "$s"; return 0
    fi

    echo "" >&2
    printf '\033[1m%s\033[0m\n' "$title" >&2
    local i5
    for i5 in "${!items[@]}"; do
        printf '  %3d. %s\n' $((i5+1)) "${items[$i5]}" >&2
    done
    echo "" >&2
    while :; do
        printf '%s' "$(is_en && echo 'Numbers to select (e.g. 1,3,5-7 · Enter=none): ' || echo '要选择的编号（如 1,3,5-7 · 回车=不选）: ')" >&2
        local TI; m_ui_readline TI
        echo "$(m_parse_sel "$TI" "$n")"; return 0
    done
}

# m_ui_browse_dir "起始目录" → 输出选定的目录（whiptail 目录浏览器：进入/上级/确认）
m_ui_browse_dir() {
    local cur="$(cd "$1" 2>/dev/null && pwd)" || cur="$HOME"
    while :; do
        local subdirs=() d
        while IFS= read -r d; do
            [ -n "$d" ] && subdirs+=("$d")
        done < <(ls -F "$cur" 2>/dev/null | grep '/$' | sed 's/\///' | sort | head -100)
        local items=("✅ $(is_en && echo "Use this directory (current: ${cur/#$HOME/\~})" || echo "使用此目录（当前：${cur/#$HOME/\~}）")")
        items+=("⬆️  $(is_en && echo 'Up one level (..)' || echo '上一级 (..)')")
        local i
        for i in "${!subdirs[@]}"; do items+=("📁 ${subdirs[$i]}"); done
        items+=("✏️  $(is_en && echo 'Type path manually…' || echo '手动输入路径…')")
        local sel
        sel=$(m_ui_menu "📂 $(is_en && echo 'Select music library directory' || echo '选择音乐库目录')" 1 "${items[@]}")
        [ -z "$sel" ] && sel=1
        if [ "$sel" = "1" ]; then
            echo "$cur"; return 0
        elif [ "$sel" = "2" ]; then
            local up; up=$(dirname "$cur")
            [ "$up" != "$cur" ] && cur="$up"
        elif [ "$sel" = "${#items[@]}" ]; then
            local mp; mp=$(m_ui_input "$(is_en && echo 'Path' || echo '路径')" "$cur")
            if [ -d "$mp" ]; then cur="$(cd "$mp" && pwd)"; fi
        else
            local nd="${subdirs[$((sel-3))]}"
            [ -d "$cur/$nd" ] && cur="$cur/$nd"
        fi
    done
}

# ═════════════════════════════════════════════════
# 1. 语言选择（界面化）
# ═════════════════════════════════════════════════
LSEL=$(m_ui_menu "🌐 Language / 语言" 1 "English" "中文")
[ -z "$LSEL" ] && LSEL=1
[ "$LSEL" = "2" ] && MF_LANG="zh"

echo "=================================================="
echo "$(is_en && echo ' 🎵 musicfeed Setup' || echo ' 🎵 musicfeed (音流) 配置引导')"
echo "=================================================="
echo ""

# ═════════════════════════════════════════════════
# 2. 依赖检测（可循环：装完自动复查）
# ═════════════════════════════════════════════════
YTDLP_PATH=""
VENV_DIR=""

check_deps() {
    MISSING=()
    echo "$(is_en && echo '🔍 Checking dependencies...' || echo '🔍 检查依赖环境...')"
    echo ""

    # 项目 venv 优先（mfui v4 起 yt-dlp 可装在项目根的 .venv/ 里，与系统隔离）
    VENV_DIR=""
    local _cand
    for _cand in "$SCRIPT_DIR/.venv" "$SCRIPT_DIR/../.venv"; do
        if [ -x "$_cand/bin/yt-dlp" ]; then
            VENV_DIR="$(cd "$(dirname "$_cand")" && pwd)/.venv"
            break
        fi
    done

    if [ -n "$VENV_DIR" ]; then
        YTDLP_PATH="$VENV_DIR/bin/yt-dlp"
        echo "  ✅ yt-dlp: $YTDLP_PATH (venv)"
    elif command -v yt-dlp &>/dev/null; then
        YTDLP_PATH=$(command -v yt-dlp)
        echo "  ✅ yt-dlp: $YTDLP_PATH"
    elif [ -f "$HOME/.local/bin/yt-dlp" ]; then
        YTDLP_PATH="$HOME/.local/bin/yt-dlp"
        echo "  ✅ yt-dlp: $YTDLP_PATH"
    else
        YTDLP_PATH=""
        echo "  ❌ yt-dlp: $(is_en && echo 'not found' || echo '未找到')"
        MISSING+=("yt-dlp")
    fi

    if command -v ffmpeg &>/dev/null; then
        echo "  ✅ ffmpeg: $(command -v ffmpeg)"
    else
        echo "  ❌ ffmpeg: $(is_en && echo 'not found' || echo '未找到')"
        MISSING+=("ffmpeg")
    fi

    if command -v python3 &>/dev/null; then
        echo "  ✅ python3: $(command -v python3)"
        PYTHON_VERSION=$(python3 -c 'import sys; print(sys.version_info.major * 100 + sys.version_info.minor)' 2>/dev/null || echo 0)
        if [ "$PYTHON_VERSION" -lt 309 ]; then
            echo "  ❌ Python $(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null) < 3.9"
            MISSING+=("python3>=3.9")
        fi
        if ! python3 -m venv --help &>/dev/null; then
            echo "  ❌ python3-venv: $(is_en && echo 'missing (needed for isolated env)' || echo '缺失（隔离环境需要）')"
            MISSING+=("python3-venv")
        fi
    else
        echo "  ❌ python3: $(is_en && echo 'not found' || echo '未找到')"
        MISSING+=("python3")
    fi

    if command -v node &>/dev/null; then
        echo "  ✅ node: $(command -v node)"
    else
        echo "  ⚠️  node: $(is_en && echo 'not found (recommended — required by yt-dlp for some links)' || echo '未找到（部分链接可能需要，建议安装）')"
    fi

    echo ""
    echo "$(is_en && echo '🔍 Checking Python modules...' || echo '🔍 检查 Python 模块...')"
    if python3 -c "import mutagen" 2>/dev/null || { [ -n "$VENV_DIR" ] && "$VENV_DIR/bin/python" -c "import mutagen" 2>/dev/null; }; then
        echo "  ✅ mutagen"
    else
        echo "  ❌ mutagen: $(is_en && echo 'not installed' || echo '未安装')"
        MISSING+=("python3-mutagen")
    fi
    echo ""
}

install_missing() {
    # 系统包（sudo）+ venv（yt-dlp/mutagen，无 sudo）
    local SYS_PKGS=()
    [[ " ${MISSING[*]} " == *" ffmpeg "* ]] && SYS_PKGS+=("ffmpeg")
    [[ " ${MISSING[*]} " == *"python3-venv"* ]] && SYS_PKGS+=("python3-venv")
    [[ " ${MISSING[*]} " == *" python3 "* ]] && SYS_PKGS+=("python3")

    local NEED_VENV=0
    [[ " ${MISSING[*]} " == *" yt-dlp "* ]] && NEED_VENV=1
    [[ " ${MISSING[*]} " == *"python3-mutagen"* ]] && NEED_VENV=1
    [[ " ${MISSING[*]} " == *"python3>=3.9"* ]] && NEED_VENV=0

    if [ ${#SYS_PKGS[@]} -gt 0 ]; then
        echo ""
        echo "$(is_en && echo "📦 Installing system packages (sudo): ${SYS_PKGS[*]}" || echo "📦 安装系统包（sudo）：${SYS_PKGS[*]}")"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y "${SYS_PKGS[@]}"
        elif command -v brew &>/dev/null; then
            # brew 无 python3-venv 概念，映射成 python
            local BREW_PKGS=()
            for p in "${SYS_PKGS[@]}"; do
                case "$p" in python3-venv) BREW_PKGS+=("python");; *) BREW_PKGS+=("$p");; esac
            done
            brew install "${BREW_PKGS[@]}"
        else
            echo "$(is_en && echo '❌ No supported package manager (apt-get/brew). Install manually:' || echo '❌ 无受支持的包管理器（apt-get/brew），请手动安装：')" >&2
            echo "    ${MISSING[*]}" >&2
            return 1
        fi
    fi

    if [ "$NEED_VENV" = "1" ] || { [ ${#SYS_PKGS[@]} -eq 0 ] && [ ${#MISSING[@]} -eq 0 ]; }; then
        echo ""
        echo "$(is_en && echo '🐍 Creating isolated venv (yt-dlp + mutagen, no sudo)...' || echo '🐍 创建隔离 venv（yt-dlp + mutagen，无需 sudo）...')"
        VENV_DIR="$SCRIPT_DIR/.venv"
        if python3 -m venv "$VENV_DIR" \
            && "$VENV_DIR/bin/pip" install --quiet --upgrade pip yt-dlp mutagen; then
            YTDLP_PATH="$VENV_DIR/bin/yt-dlp"
            echo "  ✅ venv: $VENV_DIR (yt-dlp $("$VENV_DIR/bin/yt-dlp" --version 2>/dev/null))"
        else
            echo "  ❌ $(is_en && echo 'venv creation failed' || echo 'venv 创建失败')"
            VENV_DIR=""
            return 1
        fi
    fi
    return 0
}

check_deps

SETUP_RETRY=0
while [ ${#MISSING[@]} -gt 0 ] && [ $SETUP_RETRY -lt 5 ]; do
    echo "❌ $(is_en && echo "Missing: ${MISSING[*]}" || echo "缺少依赖：${MISSING[*]}")"
    echo ""
    ISEL=$(m_ui_menu "$(is_en && echo '🛠 Dependencies' || echo '🛠 依赖安装')" 1 \
        "$(is_en && echo '⚡ One-click install (sudo for system pkgs + venv for yt-dlp/mutagen)' || echo '⚡ 一键安装（系统包走 sudo，yt-dlp/mutagen 走 venv）')" \
        "$(is_en && echo '✋ Quit and install manually' || echo '✋ 退出，手动安装')")
    if [ "$ISEL" = "1" ]; then
        install_missing || { echo ""; echo "$(is_en && echo 'Install failed, retry or quit.' || echo '安装失败，可重试或退出。')"; }
        check_deps
        SETUP_RETRY=$((SETUP_RETRY+1))
    else
        echo ""
        echo "$(is_en && echo 'Install these manually, then rerun mf_setup.sh:' || echo '请手动安装以下依赖后重新运行 mf_setup.sh：')"
        echo "  ${MISSING[*]}"
        exit 1
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "❌ $(is_en && echo 'Still missing: ${MISSING[*]}' || echo "仍缺少：${MISSING[*]}")"
    exit 1
fi

# 全齐时的可选 venv（不污染系统）
if [ -z "$VENV_DIR" ]; then
    m_ui_confirm "$(is_en && echo 'Create an isolated venv for yt-dlp + mutagen? (independent from system Python)' || echo '创建独立 venv 安装 yt-dlp + mutagen？（与系统 Python 隔离，升级互不影响）')" n \
        && install_missing && check_deps
fi

# ═════════════════════════════════════════════════
# 3. 音乐库目录（目录浏览器，从 $HOME 开始）
# ═════════════════════════════════════════════════
echo "$(is_en && echo '── 📂 Music Directory ──' || echo '── 📂 音乐目录配置 ──')"
echo ""
BASE_DIR=$(m_ui_browse_dir "$HOME")

if [ ! -d "$BASE_DIR" ]; then
    m_ui_confirm "$(is_en && echo "Directory does not exist: $BASE_DIR — create it?" || echo "目录不存在：$BASE_DIR —— 创建它？")" y \
        && mkdir -p "$BASE_DIR" && echo "  ✅ $(is_en && echo 'Created:' || echo '已创建：') $BASE_DIR"
fi
echo "  ✅ $(is_en && echo 'Music directory:' || echo '音乐目录：') $BASE_DIR"
echo ""

# ═════════════════════════════════════════════════
# 4. 默认歌手文件夹
# ═════════════════════════════════════════════════
echo "$(is_en && echo '── 🎤 Default Artist Folder ──' || echo '── 🎤 默认歌手文件夹 ──')"
echo ""

folders=()
folders+=("musicfeed")
while IFS= read -r line; do
    [[ "$line" == "musicfeed" ]] && continue
    folders+=("$line")
done < <(ls -F "$BASE_DIR" 2>/dev/null | grep '/$' | sed 's/\///')

_items=()
for i in "${!folders[@]}"; do
    if [ "$i" -eq 0 ]; then
        _items+=("📁 ${folders[$i]}$(is_en && echo ' (default)' || echo ' （默认）')")
    else
        _items+=("📁 ${folders[$i]}")
    fi
done
_items+=("➕ $(is_en && echo 'Create new folder…' || echo '新建文件夹…')")

_SEL=$(m_ui_menu "$(is_en && echo '🎤 Default artist folder' || echo '🎤 默认歌手文件夹')" 1 "${_items[@]}")
[ -z "$_SEL" ] && _SEL=1
if [ "$_SEL" = "${#_items[@]}" ]; then
    DEFAULT_ARTIST_DIR=$(m_ui_input "$(is_en && echo 'New folder name' || echo '新文件夹名称')" "musicfeed")
else
    DEFAULT_ARTIST_DIR="${folders[$((_SEL-1))]}"
fi
echo "  ✅ $(is_en && echo 'Default artist folder:' || echo '默认歌手文件夹：') $DEFAULT_ARTIST_DIR"
echo ""

# ═════════════════════════════════════════════════
# 5. 音频格式
# ═════════════════════════════════════════════════
echo "$(is_en && echo '── 🎵 Audio Format ──' || echo '── 🎵 音频格式 ──')"
FMT_SEL=$(m_ui_menu "$(is_en && echo '🎵 Audio format' || echo '🎵 音频格式')" 1 \
    "$(is_en && echo 'Opus — smaller size, high quality (~160kbps VBR)' || echo 'Opus —— 体积小、音质好（约 160kbps VBR）')" \
    "$(is_en && echo 'M4A — native Apple device support, no transcoding' || echo 'M4A —— Apple 设备原生支持，无需转码')")
[ -z "$FMT_SEL" ] && FMT_SEL=1
if [ "$FMT_SEL" = "2" ]; then
    AUDIO_FORMAT="m4a"
else
    AUDIO_FORMAT="opus"
fi
echo "  ✅ $(is_en && echo 'Audio format:' || echo '音频格式：') $AUDIO_FORMAT"
echo ""

# ═════════════════════════════════════════════════
# 6. 隐藏文件夹（滚动 checklist，默认全不选）
# ═════════════════════════════════════════════════
echo "$(is_en && echo '── 🗂️ Hidden Folders ──' || echo '── 🗂️ 隐藏文件夹 ──')"
echo ""

# 候选 = 音乐库一级子目录 + 常见噪音目录（attachments/@eaDir/.DS_Store）
hide_cands=()
while IFS= read -r line; do
    hide_cands+=("$line")
done < <(ls -F "$BASE_DIR" 2>/dev/null | grep '/$' | sed 's/\///')
for classic in "attachments" "@eaDir" ".DS_Store"; do
    [[ " ${hide_cands[*]} " == *" $classic "* ]] || hide_cands+=("$classic")
done

HIDDEN_DIRS=()
if [ ${#hide_cands[@]} -gt 0 ]; then
    HSEL=$(printf '%s\n' "${hide_cands[@]}" | m_ui_checklist "$(is_en && echo 'Select folders to hide in artist picker (default: none)' || echo '勾选需要在歌手选择界面隐藏的文件夹（默认全不选）')")
    for n_idx in ${HSEL//,/ }; do
        [[ "$n_idx" =~ ^[0-9]+$ ]] && HIDDEN_DIRS+=("${hide_cands[$((n_idx-1))]}")
    done
fi

# 去重
HIDDEN_DIRS_SORTED=()
while IFS= read -r line; do
    HIDDEN_DIRS_SORTED+=("$line")
done < <(printf "%s\n" "${HIDDEN_DIRS[@]}" | sort -u)
HIDDEN_DIRS=("${HIDDEN_DIRS_SORTED[@]}")

if [ ${#HIDDEN_DIRS[@]} -gt 0 ]; then
    echo "  ✅ $(is_en && echo 'Hidden folders:' || echo '已隐藏：') ${HIDDEN_DIRS[*]}"
else
    echo "  ✅ $(is_en && echo 'No hidden folders' || echo '未隐藏任何文件夹')"
fi
echo ""

# ═════════════════════════════════════════════════
# 7. 生成配置文件
# ═════════════════════════════════════════════════
echo "$(is_en && echo '── 📝 Generating Config ──' || echo '── 📝 生成配置文件 ──')"

shell_quote() {
    printf "%q" "$1"
}

HIDDEN_DIRS_STR="("
for hd in "${HIDDEN_DIRS[@]}"; do
    HIDDEN_DIRS_STR+="$(shell_quote "$hd") "
done
HIDDEN_DIRS_STR+=")"

MF_LANG_Q=$(shell_quote "$MF_LANG")
BASE_DIR_Q=$(shell_quote "$BASE_DIR")
YTDLP_PATH_Q=$(shell_quote "$YTDLP_PATH")
NODE_PATH_Q=$(shell_quote "${NODE_PATH:-}")
DEFAULT_ARTIST_DIR_Q=$(shell_quote "$DEFAULT_ARTIST_DIR")
AUDIO_FORMAT_Q=$(shell_quote "$AUDIO_FORMAT")
VENV_DIR_Q=$(shell_quote "${VENV_DIR:-}")

cat > "$CONFIG_FILE" << CFGEOF
#!/bin/bash
# musicfeed (音流) 配置文件
# 由 mf_setup.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')

# 语言设置 (en/zh)
MF_LANG=$MF_LANG_Q

# 音乐库根目录
MF_BASE_DIR=$BASE_DIR_Q

# yt-dlp 路径
MF_YTDLP=$YTDLP_PATH_Q

# Python 虚拟环境（yt-dlp/mutagen 隔离安装；非空时内核会把它的 bin 前置到 PATH）
MF_VENV=$VENV_DIR_Q

# node 路径（yt-dlp 解析用，留空则自动检测）
MF_NODE_PATH=$NODE_PATH_Q

# 默认歌手文件夹
MF_DEFAULT_ARTIST_DIR=$DEFAULT_ARTIST_DIR_Q

# 隐藏文件夹（在歌手选择界面中不显示）
MF_HIDDEN_DIRS=$HIDDEN_DIRS_STR

# 音频格式: opus / m4a
MF_AUDIO_FORMAT=$AUDIO_FORMAT_Q

# 播放列表下载间隔（秒，0=不限制）
CFGEOF

chmod +x "$CONFIG_FILE"
echo "  ✅ $(is_en && echo 'Config saved:' || echo '配置文件已保存：') $CONFIG_FILE"
echo ""

echo "=================================================="
echo " $(is_en && echo '🎉 Setup complete!' || echo '🎉 配置完成！')"
echo "=================================================="
echo ""
echo "$(is_en && echo 'Usage:' || echo '使用方法：')"
echo "  bash musicfeed.sh"
echo ""
echo "$(is_en && echo 'Modify config:' || echo '修改配置：')"
echo "  $(is_en && echo 'Edit' || echo '编辑') $CONFIG_FILE"
echo ""
echo "$(is_en && echo 'Reconfigure:' || echo '重新配置：')"
echo "  bash mf_setup.sh"
echo ""
