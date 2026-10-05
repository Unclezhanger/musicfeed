#!/bin/bash
# ═════════════════════════════════════════════════
# musicfeed (音流) 配置引导脚本 mf_setup.sh
# v3.4: 全流程界面化（whiptail → 方向键 → 数字 三层降级，自包含不依赖 mf_lib）
# v4.0: yt-dlp 改为下载官方单文件二进制（不再走 pip venv）；
#       打标签依赖已在 musicfeed.sh 迁移到 ffmpeg；json 解析迁移到 jq。
#       本脚本彻底不再检测/安装 python3、mutagen，新增 jq 依赖
# v4.0.5: 依赖检测结果接入 whiptail 摘要弹窗（全绿 / 缺失两种标题，缺工具时
#         不再只有滚动的终端文本）；新增 yt-dlp stable/nightly 通道选择
#         （确认 nightly 后立即下载覆盖）；macOS 环境给出 GNU 工具依赖提示
# v4.0.6: yt-dlp 版本管理升级为三选菜单（保持当前 / 更新最新 stable / 切换
#         nightly）——环境检测已通过也照常出现，YouTube 反爬封杀旧版时用户
#         重跑向导即可自救，不必手动删二进制
# v4.0.7: 修复版本菜单多出一个空项（误按 ui_menu 三参签名传参，导致选中
#         nightly 实际落到 case 空分支、什么都不发生）；配置步骤重构为可
#         回退状态机——Esc=返回上一步（第一步原地重选），whiptail/方向键
#         层生效；隐藏文件夹空数组不再生成 ('' )
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
echo " 🎵 musicfeed v4.1 Setup / 配置引导"
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
        part="${part#"${part%%[![:space:]]*}"}"   # 去前导空白（不要用 xargs：它会解释引号/反斜杠）
        part="${part%"${part##*[![:space:]]}"}"   # 去尾随空白
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local s=${BASH_REMATCH[1]} e=${BASH_REMATCH[2]}
            if [ "$s" -ge 1 ] && [ "$e" -le "$max" ] && [ "$s" -le "$e" ]; then
                for ((i=s; i<=e; i++)); do result="${result}${result:+,}$i"; done
            else
                echo "INVALID:$part"; return 1      # 越界 → 整体失败
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -ge 1 ] && [ "$part" -le "$max" ]; then
                result="${result}${result:+,}$part"
            else
                echo "INVALID:$part"; return 1      # 越界 → 整体失败
            fi
        else
            echo "INVALID:$part"; return 1          # 非数字 → 整体失败
        fi
    done
    echo "$result"    # 空输入仍返回空：setup 里"回车 = 不选"是合法语义
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
        [ $? -ne 0 ] && { echo ""; return 255; }
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
        [ -z "$TI" ] && { echo ""; return 0; }        # 回车 = 不选
        local _P; _P=$(m_parse_sel "$TI" "$n")
        if [[ "$_P" == INVALID:* ]]; then
            printf '%s\n' "$(is_en && echo '  Invalid selection, retry (Enter=none)' || echo '  选择无效，重试（回车=不选）')" >&2
            continue
        fi
        echo "$_P"; return 0
    done
}

# m_ui_browse_dir "起始目录" → 输出选定的目录（whiptail 目录浏览器：进入/上级/确认）
m_ui_browse_dir() {
    local cur="$(cd "$1" 2>/dev/null && pwd)" || cur="$HOME"
    while :; do
        local subdirs=() d
        local _e
        while IFS= read -r -d '' _e; do
            d="${_e##*/}"
        [[ "$d" == *$'\n'* ]] && continue   # 含换行的目录名无法安全进入菜单/勾选列表，跳过
            [ -n "$d" ] && subdirs+=("$d")
        done < <(find -L "$cur" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z | head -z -n 100)
        local items=("✅ $(is_en && echo "Use this directory (current: ${cur/#$HOME/\~})" || echo "使用此目录（当前：${cur/#$HOME/\~}）")")
        items+=("⬆️  $(is_en && echo 'Up one level (..)' || echo '上一级 (..)')")
        local i
        for i in "${!subdirs[@]}"; do items+=("📁 ${subdirs[$i]}"); done
        items+=("✏️  $(is_en && echo 'Type path manually…' || echo '手动输入路径…')")
        local sel
        sel=$(m_ui_menu "📂 $(is_en && echo 'Select music library directory' || echo '选择音乐库目录')" 1 "${items[@]}")
        [ $? -ne 0 ] && return 1   # v4.0.7: Esc = 返回上一步（由调用方步骤处理）
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
echo "$(is_en && echo ' 🎵 musicfeed v4.1 Setup' || echo ' 🎵 musicfeed (音流) v4.1 配置引导')"
echo "=================================================="
echo ""

# ═════════════════════════════════════════════════
# 2. 依赖检测（可循环：装完自动复查）
# ═════════════════════════════════════════════════
YTDLP_PATH=""
VENV_DIR=""

DEP_REPORT_FILE=""
# v4.0.5: 检测行同写终端与报告文件——whiptail 摘要弹窗直接读文件渲染；
# 非 TUI 场景行为不变（原样打印到终端）
_dep_say() {
    printf '%s\n' "$1"
    printf '%s\n' "$1" >> "$DEP_REPORT_FILE"
}

check_deps() {
    MISSING=()
    [ -n "$DEP_REPORT_FILE" ] || DEP_REPORT_FILE="$(mktemp "${TMPDIR:-/tmp}/mf_dep_report_XXXXXX")"
    : > "$DEP_REPORT_FILE"
    _dep_say "$(is_en && echo '🔍 Checking dependencies...' || echo '🔍 检查依赖环境...')"
    _dep_say ""

    # v4.0: yt-dlp 优先找项目 bin/ 目录里的官方单文件二进制（无 Python 依赖）
    VENV_DIR=""
    local _bin_cand="$SCRIPT_DIR/bin/yt-dlp"
    if [ -x "$_bin_cand" ]; then
        YTDLP_PATH="$_bin_cand"
        _dep_say "  ✅ yt-dlp: $YTDLP_PATH (standalone binary)"
    elif command -v yt-dlp &>/dev/null; then
        YTDLP_PATH=$(command -v yt-dlp)
        _dep_say "  ✅ yt-dlp: $YTDLP_PATH"
    elif [ -f "$HOME/.local/bin/yt-dlp" ]; then
        YTDLP_PATH="$HOME/.local/bin/yt-dlp"
        _dep_say "  ✅ yt-dlp: $YTDLP_PATH"
    else
        YTDLP_PATH=""
        _dep_say "  ❌ yt-dlp: $(is_en && echo 'not found' || echo '未找到')"
        MISSING+=("yt-dlp")
    fi

    if command -v ffmpeg &>/dev/null; then
        _dep_say "  ✅ ffmpeg: $(command -v ffmpeg)"
    else
        _dep_say "  ❌ ffmpeg: $(is_en && echo 'not found' || echo '未找到')"
        MISSING+=("ffmpeg")
    fi

    # v4.0: json 解析/电台歌名提取已从 python3 迁移到 jq + 纯 bash，
    # 不再需要 python3——jq 是唯一新增的运行时依赖
    if command -v jq &>/dev/null; then
        _dep_say "  ✅ jq: $(command -v jq)"
    else
        _dep_say "  ❌ jq: $(is_en && echo 'not found' || echo '未找到')"
        MISSING+=("jq")
    fi

    if command -v curl &>/dev/null || command -v wget &>/dev/null; then
        _dep_say "  ✅ $(is_en && echo 'downloader (curl/wget): found' || echo '下载工具（curl/wget）：已找到')"
    else
        _dep_say "  ❌ curl/wget: $(is_en && echo 'not found (needed to fetch yt-dlp binary)' || echo '未找到（下载 yt-dlp 二进制需要）')"
        MISSING+=("curl")
    fi

    if command -v node &>/dev/null; then
        _dep_say "  ✅ node: $(command -v node)"
    else
        _dep_say "  ⚠️  node: $(is_en && echo 'not found (recommended — required by yt-dlp for some links)' || echo '未找到（部分链接可能需要，建议安装）')"
    fi

    # v4.0.5: macOS 提示——内核打标签链路用了 GNU sed/base64 专属参数，BSD 工具链
    # 不兼容；whiptail 亦非 macOS 自带，缺了会自动降级为方向键/数字菜单
    if [ "$(uname -s)" = "Darwin" ]; then
        _dep_say "  ⚠️  macOS: $(is_en \
            && echo 'tagging needs GNU tools: brew install gnu-sed coreutils (prepend gnubin/gsed to PATH); whiptail optional (UI auto-falls back)' \
            || echo '打标签依赖 GNU 工具：brew install gnu-sed coreutils 并把 gnubin/gsed 前置到 PATH；whiptail 可选（缺了 UI 自动降级）')"
    fi

    _dep_say ""
}

# v4.0.5: 依赖摘要弹窗——全绿显示 ✅，缺工具显示 ❌ + 明细（此前缺工具场景
# 只有会滚走的终端文本，whiptail 弹窗盖住后用户看不到缺了什么）。
# 无 whiptail 时跳过，明细保持在终端可见
show_dep_dialog() {
    m_ui_has_whiptail || return 0
    [ -s "$DEP_REPORT_FILE" ] || return 0
    local title
    if [ ${#MISSING[@]} -eq 0 ]; then
        if is_en; then title="✅ Environment OK"; else title="✅ 环境检测通过——依赖齐全"; fi
    else
        if is_en; then title="❌ Missing ${#MISSING[@]}: ${MISSING[*]}"; else title="❌ 缺少 ${#MISSING[@]} 个依赖：${MISSING[*]}"; fi
    fi
    whiptail --title "$title" --msgbox "$(cat "$DEP_REPORT_FILE")" 0 78 "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3
    return 0
}

# v4.0.5: yt-dlp 下载统一入口。channel=stable（yt-dlp 官方 latest）/ nightly
# （yt-dlp-nightly-builds，跟进 YouTube 反爬更快）；两通道都发布同名平台二进制，
# 直接覆盖 dest 即完成"切换通道"
dl_ytdlp_channel() {
    local channel="$1" dest="$2" _os _arch _asset _url
    _os="$(uname -s)"
    _arch="$(uname -m)"
    case "$_os" in
        Darwin) _asset="yt-dlp_macos" ;;
        Linux)
            case "$_arch" in
                aarch64|arm64) _asset="yt-dlp_linux_aarch64" ;;
                *) _asset="yt-dlp_linux" ;;
            esac
            ;;
        *) _asset="yt-dlp" ;;
    esac
    if [ "$channel" = "nightly" ]; then
        _url="https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/${_asset}"
    else
        _url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/${_asset}"
    fi
    mkdir -p "$(dirname "$dest")"
    echo "$(is_en && echo "⬇️  Downloading yt-dlp ($channel) binary: $_asset" || echo "⬇️  下载 yt-dlp（$channel）二进制：$_asset")"
    if command -v curl &>/dev/null; then
        curl -fL --retry 3 -o "$dest" "$_url"
    else
        wget -O "$dest" "$_url"
    fi
    if [ -s "$dest" ]; then
        chmod +x "$dest"
        echo "  ✅ yt-dlp ($channel): $dest ($("$dest" --version 2>/dev/null))"
        return 0
    fi
    echo "  ❌ $(is_en && echo 'yt-dlp download failed' || echo 'yt-dlp 下载失败')"
    rm -f "$dest"
    return 1
}

install_missing() {
    # 系统包（sudo）：ffmpeg / jq / curl
    local SYS_PKGS=()
    [[ " ${MISSING[*]} " == *" ffmpeg "* ]] && SYS_PKGS+=("ffmpeg")
    [[ " ${MISSING[*]} " == *" jq "* ]] && SYS_PKGS+=("jq")
    [[ " ${MISSING[*]} " == *" curl "* ]] && SYS_PKGS+=("curl")

    if [ ${#SYS_PKGS[@]} -gt 0 ]; then
        echo ""
        echo "$(is_en && echo "📦 Installing system packages (sudo): ${SYS_PKGS[*]}" || echo "📦 安装系统包（sudo）：${SYS_PKGS[*]}")"
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y "${SYS_PKGS[@]}"
        elif command -v brew &>/dev/null; then
            brew install "${SYS_PKGS[@]}"
        else
            echo "$(is_en && echo '❌ No supported package manager (apt-get/brew). Install manually:' || echo '❌ 无受支持的包管理器（apt-get/brew），请手动安装：')" >&2
            echo "    ${MISSING[*]}" >&2
            return 1
        fi
    fi

    if [[ " ${MISSING[*]} " == *" yt-dlp "* ]]; then
        echo ""
        echo "$(is_en && echo '⬇️  Installing yt-dlp standalone binary (no Python needed)...' || echo '⬇️  安装 yt-dlp 单文件二进制（无需 Python）...')"
        if dl_ytdlp_channel stable "$SCRIPT_DIR/bin/yt-dlp"; then
            YTDLP_PATH="$SCRIPT_DIR/bin/yt-dlp"
        else
            return 1
        fi
    fi
    return 0
}

check_deps
show_dep_dialog

SETUP_RETRY=0
while [ ${#MISSING[@]} -gt 0 ] && [ $SETUP_RETRY -lt 5 ]; do
    echo "❌ $(is_en && echo "Missing: ${MISSING[*]}" || echo "缺少依赖：${MISSING[*]}")"
    echo ""
    ISEL=$(m_ui_menu "$(is_en && echo '🛠 Dependencies' || echo '🛠 依赖安装')" 1 \
        "$(is_en && echo '⚡ One-click install (sudo for system pkgs + download yt-dlp binary)' || echo '⚡ 一键安装（系统包走 sudo，yt-dlp 直接下载二进制）')" \
        "$(is_en && echo '✋ Quit and install manually' || echo '✋ 退出，手动安装')")
    if [ "$ISEL" = "1" ]; then
        install_missing || { echo ""; echo "$(is_en && echo 'Install failed, retry or quit.' || echo '安装失败，可重试或退出。')"; }
        check_deps
        show_dep_dialog
        SETUP_RETRY=$((SETUP_RETRY+1))
    else
        echo ""
        echo "$(is_en && echo 'Install these manually, then rerun mf_setup.sh:' || echo '请手动安装以下依赖后重新运行 mf_setup.sh：')"
        echo "  ${MISSING[*]}"
        exit 1
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "❌ $(is_en && echo "Still missing: ${MISSING[*]}" || echo "仍缺少：${MISSING[*]}")"
    exit 1
fi

# ═════════════════════════════════════════════════
# 2.5–6 可回退配置步骤（v4.0.7 状态机：Esc = 返回上一步；已在第一步时原地重选）
# 与主脚本内核的步骤状态机同模式：步骤函数返回 0=通过/继续，1=用户要求回退
# ═════════════════════════════════════════════════

# ── step: yt-dlp 版本管理（更新 / 通道切换）──
# YouTube 反爬更新频繁，旧版 yt-dlp 可能突然整体失效——即使环境检测已通过，
# 这里也照常提供更新/切换入口：用户随时重跑本向导即可拉取最新 stable 或
# 切到 nightly，无需手动删除二进制
step_ytdlp_ver() {
    echo "$(is_en && echo '── 📦 yt-dlp Version ──' || echo '── 📦 yt-dlp 版本管理 ──')"
    echo ""
    YT_CUR_VER="$("$YTDLP_PATH" --version 2>/dev/null || echo 'unknown')"
    o_keep="$(is_en && echo 'Keep current version (no update)' || echo '保持当前版本（不更新）')"
    o_stable="$(is_en && echo 'Update to latest STABLE (overwrite)' || echo '更新到最新稳定版 stable（覆盖）')"
    o_nightly="$(is_en && echo 'Switch to NIGHTLY (faster anti-bot fixes, overwrite)' || echo '切换到 nightly 版（跟进反爬更快，覆盖）')"
    VSEL=$(m_ui_menu "$(is_en && echo "📦 yt-dlp version [current: ${YT_CUR_VER}]" || echo "📦 yt-dlp 版本管理〔当前 ${YT_CUR_VER}〕")" 1 "$o_keep" "$o_stable" "$o_nightly")
    [ $? -ne 0 ] && return 1
    case "$VSEL" in
        2)
            if dl_ytdlp_channel stable "$SCRIPT_DIR/bin/yt-dlp"; then
                YTDLP_PATH="$SCRIPT_DIR/bin/yt-dlp"
            else
                echo "  $(is_en && echo 'Download failed — keeping current yt-dlp.' || echo '下载失败——保留现有 yt-dlp。')"
            fi ;;
        3)
            if dl_ytdlp_channel nightly "$SCRIPT_DIR/bin/yt-dlp"; then
                YTDLP_PATH="$SCRIPT_DIR/bin/yt-dlp"
            else
                echo "  $(is_en && echo 'Download failed — keeping current yt-dlp.' || echo '下载失败——保留现有 yt-dlp。')"
            fi ;;
    esac
    if [ "$VSEL" != "1" ] && [ "$YTDLP_PATH" = "$SCRIPT_DIR/bin/yt-dlp" ]; then
        echo "  📝 $(is_en && echo "Config will point to $YTDLP_PATH (managed inside the project folder, system install untouched)" || echo "配置将指向 $YTDLP_PATH（项目内自管理，不动系统安装）")"
    fi
    [ -n "$DEP_REPORT_FILE" ] && rm -f "$DEP_REPORT_FILE"
    echo ""
    return 0
}

# ── step: 音乐库目录 ──
step_musicdir() {
    echo "$(is_en && echo '── 📂 Music Directory ──' || echo '── 📂 音乐目录配置 ──')"
    echo ""
    BASE_DIR=$(m_ui_browse_dir "$HOME")
    [ $? -ne 0 ] && return 1
    if [ ! -d "$BASE_DIR" ]; then
        m_ui_confirm "$(is_en && echo "Directory does not exist: $BASE_DIR — create it?" || echo "目录不存在：$BASE_DIR —— 创建它？")" y \
            && mkdir -p "$BASE_DIR" && echo "  ✅ $(is_en && echo 'Created:' || echo '已创建：') $BASE_DIR"
    fi
    echo "  ✅ $(is_en && echo 'Music directory:' || echo '音乐目录：') $BASE_DIR"
    echo ""
    return 0
}

# ── step: 默认歌手文件夹 ──
step_artist() {
    echo "$(is_en && echo '── 🎤 Default Artist Folder ──' || echo '── 🎤 默认歌手文件夹 ──')"
    echo ""
    folders=()
    folders+=("musicfeed")
    local _e
    while IFS= read -r -d '' _e; do
        line="${_e##*/}"
        [[ "$line" == *$'\n'* ]] && continue   # 含换行的目录名无法安全进入菜单/勾选列表，跳过
        [[ "$line" == "musicfeed" ]] && continue
        folders+=("$line")
    done < <(find -L "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z)

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
    [ $? -ne 0 ] && return 1
    [ -z "$_SEL" ] && _SEL=1
    if [ "$_SEL" = "${#_items[@]}" ]; then
        DEFAULT_ARTIST_DIR=$(m_ui_input "$(is_en && echo 'New folder name' || echo '新文件夹名称')" "musicfeed")
    else
        DEFAULT_ARTIST_DIR="${folders[$((_SEL-1))]}"
    fi
    echo "  ✅ $(is_en && echo 'Default artist folder:' || echo '默认歌手文件夹：') $DEFAULT_ARTIST_DIR"
    echo ""
    return 0
}

# ── step: 音频格式 ──
step_format() {
    echo "$(is_en && echo '── 🎵 Audio Format ──' || echo '── 🎵 音频格式 ──')"
    FMT_SEL=$(m_ui_menu "$(is_en && echo '🎵 Audio format' || echo '🎵 音频格式')" 1 \
        "$(is_en && echo 'Opus — smaller size, high quality (~160kbps VBR)' || echo 'Opus —— 体积小、音质好（约 160kbps VBR）')" \
        "$(is_en && echo 'M4A — native Apple device support, no transcoding' || echo 'M4A —— Apple 设备原生支持，无需转码')")
    [ $? -ne 0 ] && return 1
    [ -z "$FMT_SEL" ] && FMT_SEL=1
    if [ "$FMT_SEL" = "2" ]; then
        AUDIO_FORMAT="m4a"
    else
        AUDIO_FORMAT="opus"
    fi
    echo "  ✅ $(is_en && echo 'Audio format:' || echo '音频格式：') $AUDIO_FORMAT"
    echo ""
    return 0
}

# ── step: 隐藏文件夹（滚动 checklist，默认全不选）──
step_hidden() {
    echo "$(is_en && echo '── 🗂️ Hidden Folders ──' || echo '── 🗂️ 隐藏文件夹 ──')"
    echo ""

    # 候选 = 音乐库一级子目录（只列真实存在的目录，完全由用户勾选）
    hide_cands=()
    local _e
    while IFS= read -r -d '' _e; do
        line="${_e##*/}"
        [[ "$line" == *$'\n'* ]] && continue   # 含换行的目录名无法安全进入菜单/勾选列表，跳过
        hide_cands+=("$line")
    done < <(find -L "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z)

    HIDDEN_DIRS=()
    if [ ${#hide_cands[@]} -gt 0 ]; then
        HSEL=$(printf '%s\n' "${hide_cands[@]}" | m_ui_checklist "$(is_en && echo 'Select folders to hide in artist picker (default: none)' || echo '勾选需要在歌手选择界面隐藏的文件夹（默认全不选）')")
        [ $? -eq 255 ] && return 1
        for n_idx in ${HSEL//,/ }; do
            [[ "$n_idx" =~ ^[0-9]+$ ]] && HIDDEN_DIRS+=("${hide_cands[$((n_idx-1))]}")
        done
    fi

    # 去重（v4.0.7: 空数组不再过 printf——之前会读进一个空串，配置生成 ('' )）
    if [ ${#HIDDEN_DIRS[@]} -gt 0 ]; then
        HIDDEN_DIRS_SORTED=()
        while IFS= read -r line; do
            HIDDEN_DIRS_SORTED+=("$line")
        done < <(printf "%s\n" "${HIDDEN_DIRS[@]}" | sort -u)
        HIDDEN_DIRS=("${HIDDEN_DIRS_SORTED[@]}")
        echo "  ✅ $(is_en && echo 'Hidden folders:' || echo '已隐藏：') ${HIDDEN_DIRS[*]}"
    else
        echo "  ✅ $(is_en && echo 'No hidden folders' || echo '未隐藏任何文件夹')"
    fi
    echo ""
    return 0
}

WSTEPS=(ytdlp_ver musicdir artist format hidden)
wi=0
while :; do
    case "${WSTEPS[$wi]}" in
        ytdlp_ver) step_ytdlp_ver; r=$? ;;
        musicdir)  step_musicdir;  r=$? ;;
        artist)    step_artist;    r=$? ;;
        format)    step_format;    r=$? ;;
        hidden)    step_hidden;    r=$? ;;
    esac
    if [ $r -eq 0 ]; then
        wi=$((wi+1))
        [ $wi -ge ${#WSTEPS[@]} ] && break
    elif [ $wi -gt 0 ]; then
        wi=$((wi-1))
    fi
    # 已在第一步时 Esc：无事可回，原地重跑当前步骤
done

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
NODE_PATH_Q=$(shell_quote "")   # v4.0.7: 不再读环境变量 NODE_PATH（Node 官方模块路径变量）——此前
                           # 若用户环境设了它会被误写进配置，干扰 yt-dlp 的 JS 运行时探测
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

# v4.0 起弃用：yt-dlp 已改为独立二进制（$SCRIPT_DIR/bin/yt-dlp），不再需要 venv。
# 留空即可；非空时内核仍会把它的 bin 前置到 PATH（兼容旧配置）
MF_VENV=$VENV_DIR_Q

# node 路径（yt-dlp 解析用，留空则自动检测）
MF_NODE_PATH=$NODE_PATH_Q

# 默认歌手文件夹
MF_DEFAULT_ARTIST_DIR=$DEFAULT_ARTIST_DIR_Q

# 隐藏文件夹（在歌手选择界面中不显示）
MF_HIDDEN_DIRS=$HIDDEN_DIRS_STR

# 音频格式: opus / m4a
MF_AUDIO_FORMAT=$AUDIO_FORMAT_Q

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
