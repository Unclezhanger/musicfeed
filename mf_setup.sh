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
# v4.0.8: yt-dlp 版本管理按真实通道工作——「保持当前」不再把通道误写为
#         stable（此前 nightly 用户选保持，配置被写成 stable，下次 start.sh
#         自动升级会用 stable 覆盖 nightly）；菜单显示当前通道与两通道最新
#         版，选项 2/3 语义统一为「同通道=更新到最新，异通道=切换」；下载
#         成功补写 .version sidecar（start.sh 的比对基准，避免下次启动白白
#         重下）；首次安装先询问通道；node 检测升级为 >=22 校验（yt-dlp EJS
#         运行时要求），缺失/过旧/项目内旧于钉版时可一键装项目内 bin/node
#         （配置写 MF_NODE_PATH，不动系统安装）
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
    # v4.1: 回车 = 显示的默认值；非法输入重问
    while :; do
        m_ui_readline yn
        case "$yn" in
            "") [ "$def" = "y" ] && return 0 || return 1 ;;
            n|N) return 1 ;;
            b|B) return 1 ;;
            y|Y) return 0 ;;
            *) echo -n "$title [Y/n]: " >&2 ;;
        esac
    done
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
    local v2 pp
    if ( : < /dev/tty ) 2>/dev/null; then
        # v4.1: 自由文本改用 readline（read -e）——普通 read 的行编辑交给内核 tty，
        # 其退格擦除按字节处理、不认中日韩字符的显示宽度，退格修改中文会列数错位
        # 出乱码甚至撕出半个字符。readline 按字符+宽度编辑，根治。
        # \001/\002 是 readline 的提示串忽略标记，让宽度计算跳过 ANSI 色码
        # （printf -v 让 \001/\033 成为真实控制字节，双引号里它们只是字面文本）
        printf -v pp '%s \001\033[2m\002[%s]\001\033[0m\002: ' "$title" "$def"
        IFS= read -r -e -p "$pp" v2 < /dev/tty
    else
        printf '%s \033[2m[%s]\033[0m: ' "$title" "$def" >&2
        IFS= read -r v2
    fi
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
# v4.0.8: yt-dlp 更新频道初始化为现有配置值（无配置留空，首次安装/版本步会赋值）。
# 「保持当前」按真实通道写回，绝不默认 stable——nightly 被覆写的根因就在这
YTDLP_CHANNEL=$(grep '^MF_YTDLP_CHANNEL=' "$SCRIPT_DIR/mf_config.sh" 2>/dev/null | sed -E 's/^MF_YTDLP_CHANNEL="?([^"]*)"?.*/\1/')
# 项目内 node 钉版（yt-dlp EJS 运行时要求 node>=22；升级 = 改此变量重跑本脚本）
NODE_PIN="22.23.4"
# 项目内 node 安装路径（安装后非空 → 配置写 MF_NODE_PATH；与 v4.0.7 弃用的
# 环境 NODE_PATH 变量无关，名字刻意错开）
SETUP_NODE_LOCAL=""

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

    # v4.0.8: node 校验升级——yt-dlp 的 EJS JS 运行时要求 node>=22（node 20 会被
    # 判 unsupported，YouTube 反爬场景格式缺失/403）。项目内 bin/node 优先于系统
    if [ -x "$SCRIPT_DIR/bin/node" ]; then
        _node_ver="$("$SCRIPT_DIR/bin/node" --version 2>/dev/null)"
        _dep_say "  ✅ node: $_node_ver ($SCRIPT_DIR/bin/node, project)"
        SETUP_NODE_LOCAL="$SCRIPT_DIR/bin/node"
    elif command -v node &>/dev/null; then
        _node_ver="$(node --version 2>/dev/null)"
        _node_major="${_node_ver#v}"; _node_major="${_node_major%%.*}"
        if [ -n "$_node_major" ] && [ "$_node_major" -ge 22 ] 2>/dev/null; then
            _dep_say "  ✅ node: $_node_ver ($(command -v node))"
        else
            _dep_say "  ⚠️  node: ${_node_ver:-$(command -v node)} $(is_en && echo '— yt-dlp JS runtime requires >=22 (EJS); project-local install recommended' || echo '— yt-dlp JS 运行时要求 >=22（EJS），建议安装项目内 node')"
        fi
    else
        _dep_say "  ⚠️  node: $(is_en && echo 'not found — yt-dlp JS runtime requires >=22 (EJS); project-local install recommended' || echo '未找到——yt-dlp JS 运行时要求 >=22（EJS），建议安装项目内 node')"
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
        # v4.0.8: 补写 .version sidecar——start.sh 启动时以它和频道最新版比对，
        # 不写的话下次启动会把刚下载的二进制原样重下一次
        "$dest" --version > "$dest.version" 2>/dev/null
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
        # v4.0.8: 首次安装先问通道（此前硬编码 stable 不问）
        local CH
        CH=$(m_ui_menu "$(is_en && echo ' yt-dlp update channel' || echo ' yt-dlp 更新通道')" 1 \
            "$(is_en && echo 'stable — official latest stable (recommended)' || echo 'stable —— 官方最新稳定版（推荐）')" \
            "$(is_en && echo 'nightly — faster anti-bot fixes, less tested' || echo 'nightly —— 反爬修复跟进更快，稳定性稍弱')")
        [ $? -ne 0 ] && CH=1
        local _channel="stable"
        [ "$CH" = "2" ] && _channel="nightly"
        if dl_ytdlp_channel "$_channel" "$SCRIPT_DIR/bin/yt-dlp"; then
            YTDLP_PATH="$SCRIPT_DIR/bin/yt-dlp"
            YTDLP_CHANNEL="$_channel"
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

# ── v4.0.8: node 就位检查（yt-dlp EJS 运行时要求 >=22）──
# 不算 MISSING（内核多数链接无 node 也能下），但缺失/过旧时主动提供项目内安装：
# bin/node + 配置 MF_NODE_PATH（内核唯一的 node 消费点 --js-runtimes），不动系统。
# 项目内 node 旧于钉版同样提供更新。系统 node 已 >=22 时不打扰。
install_project_node_mf() {
    local ver="$NODE_PIN" asset
    case "$(uname -m)" in
        aarch64|arm64) asset="linux-arm64" ;;
        *)             asset="linux-x64" ;;
    esac
    echo "$(is_en && echo "⬇️  Downloading Node.js v$ver ($asset) → $SCRIPT_DIR/bin/node ..." || echo "⬇️  下载 Node.js v$ver（$asset）→ $SCRIPT_DIR/bin/node ...")"
    mkdir -p "$SCRIPT_DIR/bin"
    # --strip-components=2：成员 node-vX-linux-x64/bin/node → 直接落为 bin/node
    # （=1 会得到 bin/bin/node 嵌套，[ -x bin/node ] 永远失败）
    if curl -fsSL --retry 3 "https://nodejs.org/dist/v$ver/node-v$ver-$asset.tar.xz" -o /tmp/mf-node.tar.xz \
        && tar -xJf /tmp/mf-node.tar.xz -C "$SCRIPT_DIR/bin" --strip-components=2 "node-v$ver-$asset/bin/node" \
        && rm -f /tmp/mf-node.tar.xz \
        && [ -x "$SCRIPT_DIR/bin/node" ]; then
        SETUP_NODE_LOCAL="$SCRIPT_DIR/bin/node"
        echo "  ✅ $(is_en && echo "project node: $($SCRIPT_DIR/bin/node --version 2>/dev/null) (config MF_NODE_PATH will point here)" || echo "项目内 node：$($SCRIPT_DIR/bin/node --version 2>/dev/null)（配置 MF_NODE_PATH 将指向此处）")"
        return 0
    fi
    rm -f /tmp/mf-node.tar.xz
    echo "  ❌ $(is_en && echo 'node download failed — continuing without it' || echo 'node 下载失败——继续（无 node 也可运行）')"
    return 1
}
mf_ver_ge() { [ "$1" = "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" ]; }
maybe_install_node() {
    local node_bin="$SCRIPT_DIR/bin/node" cur="" major=""
    [ -x "$node_bin" ] && cur="$("$node_bin" --version 2>/dev/null)"
    if [ -z "$cur" ] && command -v node &>/dev/null; then
        cur="$(node --version 2>/dev/null)"
    fi
    major="${cur#v}"; major="${major%%.*}"
    if [ -n "$major" ] && [ "$major" -ge 22 ] 2>/dev/null; then
        # 已达标。项目内且旧于钉版 → 提供更新；其余只报状态
        if [ -x "$node_bin" ] && [ -n "$cur" ] && ! mf_ver_ge "${cur#v}" "$NODE_PIN"; then
            echo ""
            m_ui_confirm "$(is_en && echo "  Project node $cur is older than pinned v$NODE_PIN — update it?" || echo "  项目内 node $cur 旧于钉版 v$NODE_PIN——更新吗？")" y \
                && install_project_node_mf
        else
            local _src=""
            [ -x "$node_bin" ] && _src="(project)"
            echo "$(is_en && echo "✅ node OK: ${cur}${_src:+ $_src}" || echo "✅ node 达标：${cur}${_src:+ $_src}")"
        fi
        return 0
    fi
    # 缺失或 <22 → 建议安装
    echo ""
    echo "$(is_en && echo "⚠️  node ${cur:-not found} — yt-dlp's JS runtime (EJS) requires >=22; without it YouTube downloads may hit missing formats / bot checks." || echo "⚠️  node ${cur:-未找到}——yt-dlp 的 JS 运行时（EJS）要求 >=22，缺失时 YouTube 下载可能格式缺失/触发反爬。")"
    if m_ui_confirm "$(is_en && echo "  Install project-local Node.js v$NODE_PIN → $node_bin (config MF_NODE_PATH; system install untouched)? [recommended]" || echo "  安装项目内 Node.js v$NODE_PIN → $node_bin（配置写 MF_NODE_PATH；不动系统安装）？[推荐]")" y; then
        install_project_node_mf
    fi
    return 0
}
maybe_install_node

# ═════════════════════════════════════════════════
# 2.5–6 可回退配置步骤（v4.0.7 状态机：Esc = 返回上一步；已在第一步时原地重选）
# 与主脚本内核的步骤状态机同模式：步骤函数返回 0=通过/继续，1=用户要求回退
# ═════════════════════════════════════════════════

# ── step: yt-dlp 版本管理（更新 / 通道切换）──
# v4.0.8 起按「真实通道」工作：显示当前版本+通道与两通道最新版；「保持当前」
# 按真实通道写回配置（此前无条件写 stable，nightly 用户选保持会被下次 start.sh
# 的自动升级用 stable 覆盖）；选项 2/3 = 同通道更新到最新 / 异通道切换（选中即
# 下载 + 持久化通道）。通道内日常更新由 start.sh 启动检测负责，本步管「选通道」。
step_ytdlp_ver() {
    echo "$(is_en && echo '── 📦 yt-dlp Version ──' || echo '── 📦 yt-dlp 版本管理 ──')"
    echo ""
    YT_CUR_VER="$("$YTDLP_PATH" --version 2>/dev/null || echo 'unknown')"
    # 当前通道：配置值优先；无配置时与两通道最新版比对猜测；都判不出按 stable 对待
    local _latest_s="" _latest_n=""
    _latest_s=$(curl -fsSL --max-time 8 "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    _latest_n=$(curl -fsSL --max-time 8 "https://api.github.com/repos/yt-dlp/yt-dlp-nightly-builds/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    # api.github.com 匿名限额 60 次/小时/IP，超额时回退 github.com 302 Location（不计配额）
    [ -z "$_latest_s" ] && _latest_s=$(curl -fsSI --max-time 8 "https://github.com/yt-dlp/yt-dlp/releases/latest" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ll]ocation:.*\/releases\/tag\///p' | head -1)
    [ -z "$_latest_n" ] && _latest_n=$(curl -fsSI --max-time 8 "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ll]ocation:.*\/releases\/tag\///p' | head -1)
    if [ -n "$YTDLP_CHANNEL" ]; then
        YT_CUR_CHANNEL="$YTDLP_CHANNEL"
    elif [ -n "$_latest_s" ] && [ "$YT_CUR_VER" = "$_latest_s" ]; then
        YT_CUR_CHANNEL="stable"
    elif [ -n "$_latest_n" ] && [ "$YT_CUR_VER" = "$_latest_n" ]; then
        YT_CUR_CHANNEL="nightly"
    else
        YT_CUR_CHANNEL="stable"
    fi
    # 状态行（含过时提示；GitHub API 失败显示 ?，菜单照常可用）
    local _s_note="" _n_note="" _guess=""
    if [ -n "$_latest_s" ] && [ "$YT_CUR_VER" != "$_latest_s" ]; then _s_note="$(is_en && echo ' (update available)' || echo '（有更新）')"; fi
    if [ -n "$_latest_n" ] && [ "$YT_CUR_VER" != "$_latest_n" ]; then _n_note="$(is_en && echo ' (update available)' || echo '（有更新）')"; fi
    [ -z "$YTDLP_CHANNEL" ] && _guess="$(is_en && echo ' (guessed)' || echo '（推测）')"
    echo "$(is_en && echo "  Current: $YT_CUR_VER · $YT_CUR_CHANNEL$_guess" || echo "  当前：$YT_CUR_VER · $YT_CUR_CHANNEL$_guess")"
    echo "$(is_en && echo "  Latest stable: ${_latest_s:-?}$_s_note   Latest nightly: ${_latest_n:-?}$_n_note" || echo "  最新 stable：${_latest_s:-?}$_s_note ｜ 最新 nightly：${_latest_n:-?}$_n_note")"
    echo ""

    # 动态标签：同通道 = 更新到最新，异通道 = 切换
    local o_keep o_stable o_nightly
    o_keep="$(is_en && echo "Keep current ($YT_CUR_CHANNEL · $YT_CUR_VER)" || echo "保持当前（$YT_CUR_CHANNEL · $YT_CUR_VER）")"
    if [ "$YT_CUR_CHANNEL" = "stable" ]; then
        if [ -n "$_latest_s" ] && [ "$YT_CUR_VER" != "$_latest_s" ]; then
            o_stable="$(is_en && echo "Update to latest stable ($YT_CUR_VER → $_latest_s)" || echo "更新到最新 stable（$YT_CUR_VER → $_latest_s）")"
        else
            o_stable="$(is_en && echo "Re-download latest stable${_latest_s:+ ($_latest_s)}" || echo "重下最新 stable${_latest_s:+（$_latest_s）}")"
        fi
        o_nightly="$(is_en && echo "Switch to NIGHTLY${_latest_n:+ ($_latest_n)} (faster anti-bot fixes)" || echo "切换到 nightly${_latest_n:+（$_latest_n）}（反爬修复跟进更快）")"
    else
        if [ -n "$_latest_n" ] && [ "$YT_CUR_VER" != "$_latest_n" ]; then
            o_nightly="$(is_en && echo "Update to latest nightly ($YT_CUR_VER → $_latest_n)" || echo "更新到最新 nightly（$YT_CUR_VER → $_latest_n）")"
        else
            o_nightly="$(is_en && echo "Re-download latest nightly${_latest_n:+ ($_latest_n)}" || echo "重下最新 nightly${_latest_n:+（$_latest_n）}")"
        fi
        o_stable="$(is_en && echo "Switch to STABLE${_latest_s:+ ($_latest_s)}" || echo "切换到 stable${_latest_s:+（$_latest_s）}")"
    fi

    VSEL=$(m_ui_menu "$(is_en && echo "📦 yt-dlp version [current: $YT_CUR_VER · $YT_CUR_CHANNEL]" || echo "📦 yt-dlp 版本管理〔当前 $YT_CUR_VER · $YT_CUR_CHANNEL〕")" 1 "$o_keep" "$o_stable" "$o_nightly")
    [ $? -ne 0 ] && return 1
    case "$VSEL" in
        2)
            YTDLP_CHANNEL="stable"
            if dl_ytdlp_channel stable "$SCRIPT_DIR/bin/yt-dlp"; then
                YTDLP_PATH="$SCRIPT_DIR/bin/yt-dlp"
            else
                echo "  $(is_en && echo 'Download failed — current binary kept; channel set to stable, next start.sh run will retry it.' || echo '下载失败——保留现有 yt-dlp；通道已记为 stable，下次 start.sh 启动会按此补下。')"
            fi ;;
        3)
            YTDLP_CHANNEL="nightly"
            if dl_ytdlp_channel nightly "$SCRIPT_DIR/bin/yt-dlp"; then
                YTDLP_PATH="$SCRIPT_DIR/bin/yt-dlp"
            else
                echo "  $(is_en && echo 'Download failed — current binary kept; channel set to nightly, next start.sh run will retry it.' || echo '下载失败——保留现有 yt-dlp；通道已记为 nightly，下次 start.sh 启动会按此补下。')"
            fi ;;
        *)
            # 保持当前：按真实通道写回配置，不下载任何东西
            YTDLP_CHANNEL="$YT_CUR_CHANNEL" ;;
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
# v4.0.8: 项目内 node（bin/node）安装后写 MF_NODE_PATH；与 v4.0.7 弃用的环境
# NODE_PATH（Node 官方模块路径变量，避免误读进配置）名字刻意错开
NODE_PATH_Q=$(shell_quote "$SETUP_NODE_LOCAL")
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

# yt-dlp 更新频道 (stable / nightly)
MF_YTDLP_CHANNEL="${YTDLP_CHANNEL:-stable}"

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
