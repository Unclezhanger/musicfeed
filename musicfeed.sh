#!/bin/bash
# ─────────────────────────────────────────────
# musicfeed V3.5.2
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 加载纯函数库（配置加载、常量、工具函数、yt-dlp 元数据抓取、链接类型检测）
# shellcheck disable=SC1091
# ══════════ mf_lib.sh（构建时内联，勿直接编辑本段）══════════
#!/bin/bash
# mf_lib.sh - musicfeed 纯函数库（无交互）
# 被 mf_batch.sh 和 musicfeed.sh 共用
# 抽取自 musicfeed.sh v3.2.0 line 1-389
#
# 设计原则：
#   - 被 source 时不产生任何 stdout/stderr 输出
#   - 不调用 read / 不依赖 tty
#   - 不修改全局 trap（仅在文件被 source 时设置一次 cleanup trap）

# ─────────────────────────────────────────────
# 1. 配置加载
# ─────────────────────────────────────────────
MF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MF_CONFIG_FILE="${MF_LIB_DIR}/mf_config.sh"

if [ ! -f "$MF_CONFIG_FILE" ]; then
    echo "==================================================" >&2
    echo " ❌ 未找到配置文件: $MF_CONFIG_FILE" >&2
    echo "==================================================" >&2
    echo "📝 首次使用，请先运行配置引导脚本： bash mf_setup.sh" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$MF_CONFIG_FILE"

# 默认值兜底（line 21-29）
: "${MF_LANG:=en}"
: "${MF_BASE_DIR:=$HOME/navidrome/music}"
: "${MF_YTDLP:=yt-dlp}"
: "${MF_DEFAULT_ARTIST_DIR:=musicfeed}"
: "${MF_NODE_PATH:=}"
: "${MF_AUDIO_FORMAT:=opus}"
: "${MF_VENV:=}"

# v3.3: 独立 venv（mf_setup 可选创建）——bin 前置到 PATH，
# 使 yt-dlp 与打标签用的 python3+mutagen 都从 venv 解析，与系统隔离
if [ -n "$MF_VENV" ] && [ -d "$MF_VENV/bin" ]; then
    case ":$PATH:" in
        *":$MF_VENV/bin:"*) ;;
        *) export PATH="$MF_VENV/bin:$PATH" ;;
    esac
    # venv 存在时 yt-dlp 默认指向 venv 内（配置里显式路径优先级更高）
    if [ "$MF_YTDLP" = "yt-dlp" ] && [ -x "$MF_VENV/bin/yt-dlp" ]; then
        MF_YTDLP="$MF_VENV/bin/yt-dlp"
    fi
fi

# 隐藏文件夹完全由用户在 mf_setup 中勾选，为空 = 不隐藏任何目录

# MF_NODE_ARGS 探测（line 31-36）
MF_NODE_ARGS=""
if [ -n "$MF_NODE_PATH" ]; then
    MF_NODE_ARGS="--js-runtimes node:$MF_NODE_PATH"
elif command -v node &>/dev/null; then
    MF_NODE_ARGS="--js-runtimes node:$(command -v node)"
fi

# ─────────────────────────────────────────────
# 2. 临时文件清理
# ─────────────────────────────────────────────
CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 3. 国际化
# ─────────────────────────────────────────────
is_en() { [ "$MF_LANG" = "en" ]; }

tr_text() {
    local zh="$1" en="$2"
    if is_en; then printf "%s" "$en"; else printf "%s" "$zh"; fi
}

# 注意：say/ask 面向用户输出，一律走 stderr——
# musicfeed.sh 的交互函数常被 $() 捕获返回值（如 AA_RESULT=$(input_album_artist)），
# 若提示走 stdout 会污染捕获结果、写进音乐标签
say() {
    local zh="$1" en="$2"
    tr_text "$zh" "$en" >&2
    printf "\n" >&2
}

ask() {
    local zh="$1" en="$2"
    tr_text "$zh" "$en" >&2
}

# ─────────────────────────────────────────────
# 4. 上限常量
# ─────────────────────────────────────────────
MF_MAX_LINKS_PER_RUN=10
MF_MAX_TRACKS_PER_RUN=150

# ─────────────────────────────────────────────
# 5. 工具函数（无交互）
# ─────────────────────────────────────────────
file_size() {
    local f="$1"
    if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"; else stat -f%z "$f"; fi
}

sanitize_filename() {
    echo "$1" | sed 's/[\/:*?"<>|]/-/g' | sed 's/^-//' | sed 's/-$//';
}

fullwidth_to_halfwidth() {
    echo "$1" | sed 's/，/,/g' | sed 's/－/-/g';
}

safe_field() {
    echo "$1" | sed 's/|/｜/g';
}

safe_strip() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//';
}

get_term_lines() {
    if command -v tput &>/dev/null; then
        local lines=$(tput lines 2>/dev/null)
        [[ "$lines" =~ ^[0-9]+$ ]] && [ "$lines" -gt 10 ] && echo "$lines" && return
    fi
    echo 24
}

# ─────────────────────────────────────────────
# 6. 选号解析（无交互）
# ─────────────────────────────────────────────
# 输入: "1,3,5-7" 或空字符串, max=最大编号
# 输出: "1,3,5,6,7" 或 "ALL" 或 "INVALID:<part>"
parse_track_selection() {
    local input="$1" max="$2" result=""
    input=$(fullwidth_to_halfwidth "$input")
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
            if [ "$start" -ge 1 ] && [ "$end" -le "$max" ] && [ "$start" -le "$end" ]; then
                for ((i=start; i<=end; i++)); do
                    [ -n "$result" ] && result="$result,$i" || result="$i"
                done
            else echo "INVALID:$part"; return 1; fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            [ "$part" -ge 1 ] && [ "$part" -le "$max" ] && { [ -n "$result" ] && result="$result,$part" || result="$part"; } || { echo "INVALID:$part"; return 1; }
        else echo "INVALID:$part"; return 1; fi
    done
    [ -z "$result" ] && echo "ALL" || echo "$result"
}

# ─────────────────────────────────────────────
# 7. MV 标题解析（无交互）
# ─────────────────────────────────────────────
# 从视频标题提取 "歌名|歌手"（3 种正则依次尝试：书名号/引号/去前缀截断）
# v4.3: 移除 " - " 拆分——播放列表/电台场景信息混乱命中率极低，单曲 MV 一并统一
extract_song_info() {
    local title="$1"
    if [[ "$title" =~ 《([^》]+)》 ]]; then
        local s="${BASH_REMATCH[1]}"; s=$(echo "$s" | sed 's/|/｜/g')
        echo "${s}|"; return
    fi
    if [[ "$title" =~ \"([^\"]+)\" ]]; then
        local s="${BASH_REMATCH[1]}"; s=$(echo "$s" | sed 's/|/｜/g')
        echo "${s}|"; return
    fi
    local cleaned=$(echo "$title" | sed 's/^【[^】]*】//' | sed 's/^Stage: //' | sed 's/^纯享[：:]//')
    cleaned=$(safe_strip "$cleaned")
    cleaned=$(echo "$cleaned" | sed 's/|/｜/g')
    echo "${cleaned:0:50}|"
}

# ─────────────────────────────────────────────
# 7.5 电台/社区列表无元数据曲目的歌名/歌手提取（无交互）
# ─────────────────────────────────────────────
# 用法: extract_nm_info "原始标题" "uploader"
# 输出: "歌名|歌手"
# 算法（v4.3，经两个真实电台 118 首验证）:
#   1) 歌名书名号优先：《》→【】→[ ]，取第一个合格括号去壳内容，其后文字全部丢弃
#   2) 括号逐层处理：污染词连符号整删；白名单(feat/ft/国/粵/粤)保留本层符号；
#      其余去壳留内容（外层自然剥除，如《K歌之王(國)》→ K歌之王(國)）
#   3) 无书名号：按 " - " 分段，uploader 与某段互相包含 → 该段为歌手；
#      匹配不上盲猜左段为歌手；纯歌名 → 歌手 fallback uploader
extract_nm_info() {
    python3 - "$1" "$2" << 'NM_PYEOF'
import re, sys

POLL = re.compile(r'歌詞|歌词|動態|动态|MV|Official|官方|Video|Audio|Visualizer|Live|完整版|主題曲|主题曲|片尾曲|片頭曲|片头曲', re.I)
KEEP = re.compile(r'feat|ft\.|国|國|粤|粵', re.I)
BR = re.compile(r'（([^（）()]*)）|\(([^()]*)\)|『([^『』]*)』|「([^「」]*)」|【([^【】]*)】|《([^《》]*)》|\[([^\[\]]*)\]')

def inner_of(m):
    return next(g for g in m.groups() if g is not None)

def br_proc(s):
    # 逐层（最内层优先）迭代：污染词连符号删；白名单层整体保留；
    # 其余去壳留内容。嵌套判定只看本层自身文字（剥离内层括号后再匹配）
    prev = None
    while prev != s:
        prev = s
        def repl(m):
            inner = inner_of(m)
            flat = BR.sub(' ', inner)
            if POLL.search(flat):
                return ''
            if KEEP.search(flat):
                return m.group(0)
            return inner
        s = BR.sub(repl, s)
    return s

def clean(s):
    s = re.sub(r'\s*-\s*$', '', s)
    s = re.sub(r'\s{2,}', ' ', s)
    return s.strip(' -').strip()

def esc(s):
    return (s or '').replace('|', '｜')

title = sys.argv[1] or ''
up = re.sub(r'\s*-\s*Topic\s*$', '', sys.argv[2] or '').strip()
t = title.replace('–', '-').replace('—', '-')

# 1) 歌名书名号优先（内容被污染词清空时视为无书名号，继续走后面分支）
m = re.search(r'《([^《》]*)》', t) or re.search(r'【([^【】]*)】', t) or re.search(r'\[([^\[\]]*)\]', t)
if m:
    song = br_proc(m.group(1)).strip()
    # 括号内容本身（已无括号包裹）也可能整个是污染词（如【動態歌詞】），需再扁平检查
    if song and not POLL.search(BR.sub(' ', song)):
        prefix = re.sub(r'^(\[[^\]]*\]\s*)+', '', t[:m.start()].strip())
        prefix = re.sub(r'[\s\-:：*|｜]+$', '', prefix).strip()
        # 前缀过长（宣传文案）时歌手 fallback uploader
        artist = prefix if prefix and len(prefix) <= 30 else up
        print(f"{esc(song)}|{esc(artist)}")
        sys.exit(0)

# 2) 无书名号：括号清洗后按 " - " 分段
t2 = br_proc(t)
segs = [s.strip() for s in t2.split(' - ') if s.strip()]
if len(segs) >= 2:
    if up:
        keep = [s for s in segs if not (s in up or up in s)]
        if keep and len(keep) < len(segs):
            print(f"{esc(clean(keep[0]))}|{esc(up)}")
            sys.exit(0)
    # 盲猜：左段为歌手（无法区分 歌手-歌名 / 歌名-歌手，已知局限）
    print(f"{esc(clean(' - '.join(segs[1:])))}|{esc(segs[0])}")
    sys.exit(0)

# 3) 纯歌名
print(f"{esc(clean(t2))}|{esc(up)}")
NM_PYEOF
}

# ─────────────────────────────────────────────
# 8. yt-dlp 元数据抓取（无交互）
# ─────────────────────────────────────────────

# get_album_info: 抓 YTM 专辑元数据
# stdout 4+ 行：album / count / artist / "idx. title"...
get_album_info() {
    local url="$1"
    tmp_json=$(mktemp)
    CLEANUP_FILES+=("$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --flat-playlist --no-warnings -J "$url" > "$tmp_json" 2>/dev/null
    if [ ! -s "$tmp_json" ]; then
        echo "Unknown Album"; echo "0"; echo "Unknown Artist"
        rm -f "$tmp_json"; return
    fi
    python3 - "$tmp_json" << 'PYEOF'
import json, re, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
raw = d.get('title', '') or ''
album = re.sub(r'^.+? - ', '', raw).strip().replace('|', '｜') or 'Unknown Album'
count = d.get('playlist_count', 0)
artist = 'Unknown Artist'
entries = d.get('entries', [])
if entries:
    artist = re.sub(r' - Topic$', '', entries[0].get('uploader', '')).strip().replace('|', '｜') or 'Unknown Artist'
print(album); print(count); print(artist)
for idx, e in enumerate(entries, 1):
    t = re.sub(r'^.+? - ', '', e.get('title', 'Unknown')).replace('|', '｜')
    print(f"{idx}. {t}")
PYEOF
    rm -f "$tmp_json"
}

# get_playlist_info: 抓播放列表 / YTM 电台元数据
# stdout 3+N 行：playlist / count / "idx. title|vid|has_meta|uploader"
# （uploader 为第 4 字段，旧解析只取前 3 字段，向后兼容）
get_playlist_info() {
    local url="$1"
    tmp_json=$(mktemp)
    CLEANUP_FILES+=("$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --flat-playlist --no-warnings -J "$url" > "$tmp_json" 2>/dev/null
    if [ ! -s "$tmp_json" ]; then
        echo "Unknown Playlist"; echo "0"
        rm -f "$tmp_json"; return
    fi
    python3 - "$tmp_json" << 'PYEOF'
import json, re, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
playlist = d.get('title', '').strip().replace('|', '｜') or 'Unknown Playlist'
count = d.get('playlist_count', 0)
print(playlist); print(count)
entries = d.get('entries', [])
for idx, e in enumerate(entries, 1):
    if e is None:
        print(f"{idx}. [unavailable]||False"); continue
    title = e.get('title') or f'Track {idx}'
    title = title.replace('|', '｜')
    vid = e.get('id', '')
    uploader_raw = e.get('uploader') or e.get('channel') or ''
    # v4.3: flat-playlist 看不到 album/artist，但 " - Topic"（YTM 歌手自动频道）
    # 的曲目下载时 info.json 必带完整 meta——预览阶段按 Topic 预判 has_meta
    is_topic = ' - Topic' in uploader_raw
    has_meta = 'True' if (e.get('album') or e.get('artist') or is_topic) else 'False'
    uploader = re.sub(r' - Topic$', '', uploader_raw).strip().replace('|', '｜')
    print(f"{idx}. {title}|{vid}|{has_meta}|{uploader}")
PYEOF
    rm -f "$tmp_json"
}

# get_single_info: 抓单曲 info.json
# stdout 5 行：album / title / artist / uploader / has_metadata(bool)
get_single_info() {
    local url="$1"
    tmp_json="/tmp/ytm_single_$$"
    CLEANUP_FILES+=("${tmp_json}.info.json" "$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --write-info-json --skip-download -o "$tmp_json" "$url" >/dev/null 2>&1
    local json_file="${tmp_json}.info.json"
    if [ ! -f "$json_file" ]; then
        echo "Unknown"; echo "1"; echo ""; echo ""; echo "False"
        rm -f "$tmp_json" "$json_file" 2>/dev/null; return
    fi
    python3 - "$json_file" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
album = d.get('album', '') or ''
title = d.get('title', 'Unknown')
artist = d.get('artist', '') or ''
uploader = d.get('uploader', '') or ''
has_metadata = bool(artist and album)
print(album); print(title); print(artist); print(uploader); print(has_metadata)
PYEOF
    rm -f "$tmp_json" "$json_file" 2>/dev/null
}

# ─────────────────────────────────────────────
# 9. 链接类型检测（无交互）
# ─────────────────────────────────────────────
# 输出: album | ytm_radio | playlist | single | unknown
get_link_type() {
    local url="$1"
    # OLAK5uy_ = YTM 分享链接；MPREb_ = YTM 专辑/发行 browse 链接
    # （从 music.youtube.com 地址栏直接复制，与 OLAK5uy 指向同一专辑实体）
    [[ "$url" =~ OLAK5uy_ ]] || [[ "$url" =~ MPREb_ ]] && { echo "album"; return; }
    [[ "$url" =~ RDCLAK5uy_ ]] && { echo "ytm_radio"; return; }
    if [[ "$url" =~ playlist\?list=PL ]] || [[ "$url" =~ playlist\?list=LM ]]; then echo "playlist"; return; fi
    [[ "$url" =~ youtube\.com/playlist ]] && { echo "playlist"; return; }
    [[ "$url" =~ watch\?v= ]] || [[ "$url" =~ youtu\.be/ ]] && { echo "single"; return; }
    echo "unknown"
}

# ─────────────────────────────────────────────
# 10. 交互 UI（v3.3）—— 三层降级
#     whiptail → bash 原生方向键 → 纯数字输入
#     MF_TUI: auto（默认，自动检测）/ on（强制 TUI）/ off（强制数字）
# 约定：所有 ui_* 返回码 255 = 用户要求返回上一步
# ─────────────────────────────────────────────

ui_can_tui() { [ "${MF_TUI:-auto}" != "off" ] && [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; }

# 数字层读行：能开终端就读终端（stdin 可能被条目管道占用），否则读 stdin
_ui_readline() { if ( : < /dev/tty ) 2>/dev/null; then IFS= read -r "$1" < /dev/tty; else IFS= read -r "$1"; fi; }

# whiptail 主题：黑底 + 灰色复选框 + 绿色高亮（默认紫底太晃眼），
# 按钮标签自带按键提示。通过 NEWT_COLORS_FILE 实现，不影响系统其他程序
_ensure_whiptail_theme() {
    if [ -z "${MF_WT_COMMON+x}" ]; then
        local f="${TMPDIR:-/tmp}/.mf_newt_colors_$$"
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
ui_has_whiptail() { [ "$MF_TUI" != "bash" ] && ui_can_tui && command -v whiptail >/dev/null 2>&1 && _ensure_whiptail_theme; }

# 读一个按键 → KEY = up/down/left/right/enter/space/esc/单个字符
_ui_readkey() {
    local k seq
    IFS= read -rsn1 k < /dev/tty
    if [[ "$k" == $'\x1b' ]]; then
        IFS= read -rsn2 seq < /dev/tty || true
        case "$seq" in
            '[A') KEY=up ;;
            '[B') KEY=down ;;
            '[C') KEY=right ;;
            '[D') KEY=left ;;
            *)   KEY=esc ;;
        esac
    elif [[ -z "$k" ]]; then
        KEY=enter
    elif [[ "$k" == ' ' ]]; then
        KEY=space
    else
        KEY="$k"
    fi
}

# ANSI 重绘：光标上移 $1 行并清屏到底
_ui_clear() { printf '\033[%dA\033[J' "$1" >&2; }

# ── 单选菜单 ─────────────────────────────────
# 用法: ui_menu "标题" "提示" 默认序号 "选项1" "选项2" ...
# 输出: 选中的序号(1 起)；返回 255 = 返回上一步
ui_menu() {
    local title="$1" prompt="$2" def="${3:-1}"; shift 3
    local items=("$@")
    local n=${#items[@]}
    [ "$n" -eq 0 ] && return 255

    if ui_has_whiptail; then
        local args=(--title "$title" --menu "$prompt" 0 60 "$n")
        local i sel rc
        for i in "${!items[@]}"; do
            args+=("$((i+1))" "${items[$i]}")
        done
        sel=$(whiptail "${args[@]}" "${MF_WT_COMMON[@]}" --default-item "$def" 3>&1 1>&2 2>&3)
        rc=$?
        [ $rc -ne 0 ] && return 255
        # 防 whiptail 输出带引号（与 checklist 同理，稳妥起见统一剥离）
        sel=${sel//\"/}
        echo "$sel"
        return 0
    fi

    if ui_can_tui; then
        local cur=$((def-1)) last=$((n-1)) redraw=1 i2
        while :; do
            if [ $redraw -eq 1 ]; then
                echo "" >&2
                printf '\033[1m%s\033[0m\n' "$title" >&2
                [ -n "$prompt" ] && printf '\033[2m%s\033[0m\n' "$prompt" >&2
                for i2 in "${!items[@]}"; do
                    if [ $i2 -eq $cur ]; then
                        printf '  \033[1;32m❯ ●\033[0m \033[1m%s\033[0m\n' "${items[$i2]}" >&2
                    else
                        printf '    ○  %s\n' "${items[$i2]}" >&2
                    fi
                done
                printf '\033[2m%s\033[0m\n' "$(is_en && echo '↑↓ move · Enter confirm · number jump · Esc/b back' || echo '↑↓ 移动 · 回车 确认 · 数字 直达 · Esc/b 返回')" >&2
                redraw=0
            fi
            _ui_readkey
            case "$KEY" in
                up)   [ $cur -gt 0 ] && { _ui_clear $((n+4)); cur=$((cur-1)); redraw=1; } ;;
                down) [ $cur -lt $last ] && { _ui_clear $((n+4)); cur=$((cur+1)); redraw=1; } ;;
                enter) echo "" >&2; echo $((cur+1)); return 0 ;;
                b|B|esc) echo "" >&2; return 255 ;;
                [1-9])
                    if [ "$KEY" -le "$n" ]; then
                        _ui_clear $((n+4))
                        echo "" >&2
                        echo "$KEY"; return 0
                    fi ;;
            esac
        done
    fi

    # 数字降级
    echo "" >&2
    printf '\033[1m%s\033[0m\n' "$title" >&2
    [ -n "$prompt" ] && echo "$prompt" >&2
    local i3 c
    for i3 in "${!items[@]}"; do
        echo "  [$((i3+1))] ${items[$i3]}" >&2
    done
    while :; do
        _ui_readline c
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ]; then echo "$c"; return 0; fi
        if [[ "$c" == "0" || "$c" == "b" ]]; then return 255; fi
        echo "$(is_en && echo '  Invalid, retry (0=back)' || echo '  无效输入，重试（0=返回）')" >&2
    done
}

# ── 是/否确认 ────────────────────────────────
# 用法: ui_confirm "标题" 默认(y/n)；返回 0=是 1=否 255=返回
ui_confirm() {
    local title="$1" def="${2:-y}" rc
    if ui_has_whiptail; then
        if [ "$def" = "y" ]; then
            whiptail --title "$title" --yesno "$title" 0 60 "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3
            rc=$?
        else
            whiptail --title "$title" --yesno "$title" 0 60 --defaultno "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3
            rc=$?
        fi
        [ $rc -eq 255 ] && return 255
        return $rc
    fi
    local yn
    if [ "$def" = "y" ]; then
        ask "$title [Y/n/b]: " "$title [Y/n/b]: "
    else
        ask "$title [y/N/b]: " "$title [y/N/b]: "
    fi
    _ui_readline yn
    case "$yn" in
        b|B) return 255 ;;
        n|N) return 1 ;;
        *) return 0 ;;
    esac
}

# ── 自由文本输入 ─────────────────────────────
# 用法: ui_input "标题" 默认值 ["提示行"(可选，如原始视频 title)]
# 输出: 文本（空→默认值）；返回 255 = 返回上一步（输入 < 或 b）
ui_input() {
    local title="$1" def="$2" prompt="${3:-}" v
    if ui_has_whiptail; then
        v=$(whiptail --title "$title" --inputbox "${prompt:-$title}" 0 60 "$def" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return 255
        [ -z "$v" ] && v="$def"
        echo "$v"; return 0
    fi
    if [ -n "$prompt" ]; then printf '\033[2m🎬 %s\033[0m\n' "$prompt" >&2; fi
    if is_en; then printf '%s \033[2m[%s] (< = back)\033[0m: ' "$title" "$def" >&2
    else printf '%s \033[2m[%s]（< = 返回上一步）\033[0m: ' "$title" "$def" >&2; fi
    local v2
    _ui_readline v2
    if [ "$v2" = "<" ] || [ "$v2" = "b" ]; then return 255; fi
    [ -z "$v2" ] && v2="$def"
    echo "$v2"
}

# ── 勾选列表（v3.4：滚动编号列表 + 顶部「全选」项）──
# 用法: 条目逐行经 stdin 传入: printf '%s\n' "a" "b" | ui_checklist "标题" 每页行数
# 输出: "ALL" 或 "1,3,5"；返回 255 = 返回上一步
# 语义: 顶部「全选」项默认勾选（=下载全部）；取消全选后曲目默认全部不选，
#       用户空格逐条勾选需要的曲目
# 按键: ↑↓ 移动 · 空格 勾选 · a 全选 · n 全不选 · ←→ 翻页 · 数字 页内直达 · 回车 确认 · b 返回
ui_checklist() {
    local title="$1" page_n="${2:-12}"
    local items=() line
    while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
    done
    local n=${#items[@]}
    [ "$n" -eq 0 ] && { echo "ALL"; return 0; }
    local total_pages=$(( (n - 1) / page_n + 1 ))
    local page=0 cur=0 i
    local -a on=()
    for i in $(seq 0 $((n-1))); do on[$i]=0; done
    local all_on=1

    _ui_sel_str() {
        local s="" c=0 i2
        for i2 in $(seq 0 $((n-1))); do
            if [ "${on[$i2]}" = "1" ]; then s="${s}${s:+,}$((i2+1))"; c=$((c+1)); fi
        done
        echo "$s"
    }
    _ui_sel_cnt() {
        local c=0 i3
        for i3 in $(seq 0 $((n-1))); do [ "${on[$i3]}" = 1 ] && c=$((c+1)); done
        echo $c
    }

    if ui_has_whiptail; then
        local res s c t lh
        lh=$((n+1)); [ $lh -gt 15 ] && lh=15
        while :; do
            local args=(--title "$title" --checklist \
                "$(is_en && echo 'ALL = download everything; untick ALL and space-select the tracks you want' || echo '勾选 ALL=下载全部；取消 ALL 后用空格勾选需要的曲目')" \
                0 78 $lh \
                "ALL" "$(is_en && echo '★ Select ALL tracks' || echo '★ 全选所有曲目')" \
                "$([ $all_on -eq 1 ] && echo on || echo off)")
            for i in "${!items[@]}"; do
                args+=("$((i+1))" "${items[$i]}" "$([ "${on[$i]}" = 1 ] && echo on || echo off)")
            done
            res=$(whiptail "${args[@]}" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
            [ $? -ne 0 ] && return 255
            # checklist 输出形如: "ALL" "1" "3" —— 剥引号后逐 tag 判断
            if printf '%s\n' "$res" | tr ' ' '\n' | tr -d '"' | grep -qx 'ALL'; then
                echo "ALL"; return 0
            fi
            s=""; c=0
            for t in $(printf '%s' "$res" | tr -d '"'); do
                if [[ "$t" =~ ^[0-9]+$ ]]; then s="${s}${s:+,}$t"; c=$((c+1)); fi
            done
            if [ $c -eq 0 ]; then
                whiptail --title "$title" --msgbox \
                    "$(is_en && echo 'Nothing selected — tick ALL or select tracks.' || echo '未选择任何曲目——勾选 ALL 或勾选具体曲目。')" \
                    0 60 "${MF_WT_COMMON[@]}"
                continue
            fi
            echo "$s"; return 0
        done
    fi

    if ui_can_tui; then
        # cur=0 是「全选」伪条目，1..n 对应曲目（显示编号 = cur）
        local redraw=1 flash="" start end i4 mark rel t2
        while :; do
            if [ $redraw -eq 1 ]; then
                [ $cur -gt 0 ] && page=$(( (cur-1) / page_n ))
                start=$((page * page_n))
                end=$((start + page_n - 1)); [ $end -ge $n ] && end=$((n-1))
                echo "" >&2
                printf '\033[1m%s\033[0m  \033[2m(%s %d/%d · %s %s/%d)\033[0m\n' \
                    "$title" "$(is_en && echo page || echo 页)" $((page+1)) $total_pages \
                    "$(is_en && echo selected || echo 已选)" \
                    "$([ $all_on -eq 1 ] && echo ALL || echo "$(_ui_sel_cnt)")" "$n" >&2
                mark="[ ]"; [ $all_on -eq 1 ] && mark="\033[32m[✓]\033[0m"
                if [ $cur -eq 0 ]; then
                    printf '\033[1;32m ❯\033[0m %s \033[1m  ★ %s\033[0m\n' "$mark" "$(is_en && echo 'Select ALL tracks' || echo '全选所有曲目')" >&2
                else
                    printf '    %s   ★ %s\n' "$mark" "$(is_en && echo 'Select ALL tracks' || echo '全选所有曲目')" >&2
                fi
                for i4 in $(seq $start $end); do
                    mark="[ ]"; [ "${on[$i4]}" = 1 ] && mark="\033[32m[✓]\033[0m"
                    if [ $i4 -eq $((cur-1)) ]; then
                        printf '\033[1;32m ❯\033[0m %s \033[1m%3d. %s\033[0m\n' "$mark" $((i4+1)) "${items[$i4]}" >&2
                    else
                        printf '    %s %3d. %s\n' "$mark" $((i4+1)) "${items[$i4]}" >&2
                    fi
                done
                if [ -n "$flash" ]; then printf '\033[33m%s\033[0m\n' "$flash" >&2; else echo "" >&2; fi
                printf '\033[2m%s\033[0m\n' "$(is_en \
                    && echo '↑↓ move · space toggle · a ALL · n NONE · ←→ page · Enter OK · b back' \
                    || echo '↑↓移动 · 空格勾选 · a全选 · n全不选 · ←→翻页 · 回车确认 · b返回')" >&2
                flash=""; redraw=0
            fi
            _ui_readkey
            case "$KEY" in
                up)   [ $cur -gt 0 ] && { cur=$((cur-1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                down) [ $cur -lt $n ] && { cur=$((cur+1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                left)  [ $page -gt 0 ] && { page=$((page-1)); cur=$((page*page_n+1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                right) [ $page -lt $((total_pages-1)) ] && { page=$((page+1)); cur=$((page*page_n+1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                space)
                    if [ $cur -eq 0 ]; then
                        all_on=$((1-all_on))
                        for i in $(seq 0 $((n-1))); do on[$i]=$all_on; done
                    else
                        on[$((cur-1))]=$((1 - on[$((cur-1))]))
                    fi
                    _ui_clear $((page_n+6)); redraw=1 ;;
                a|A) all_on=1; for i in $(seq 0 $((n-1))); do on[$i]=1; done; _ui_clear $((page_n+6)); redraw=1 ;;
                n|N) all_on=0; for i in $(seq 0 $((n-1))); do on[$i]=0; done; _ui_clear $((page_n+6)); redraw=1 ;;
                enter)
                    if [ $all_on -eq 1 ]; then echo "" >&2; echo "ALL"; return 0; fi
                    if [ "$(_ui_sel_cnt)" -eq 0 ]; then
                        flash="$(is_en && echo '⚠ nothing selected' || echo '⚠ 未选择任何条目')"
                        _ui_clear $((page_n+6)); redraw=1; continue
                    fi
                    echo "" >&2
                    _ui_sel_str; return 0 ;;
                b|B|esc) echo "" >&2; return 255 ;;
                [1-9])
                    rel=$KEY; start=$((page * page_n)); t2=$((start + rel - 1))
                    if [ $t2 -lt $n ] && [ $t2 -ge $start ]; then
                        cur=$((t2+1)); on[$t2]=$((1 - on[$t2])); _ui_clear $((page_n+6)); redraw=1
                    fi ;;
            esac
        done
    fi

    # 数字降级：编号列表 + 输入（支持 1,3,5-7；回车=全部）
    echo "" >&2
    printf '\033[1m%s\033[0m\n' "$title" >&2
    local i5 TI P
    for i5 in "${!items[@]}"; do
        printf '  %3d. %s\n' $((i5+1)) "${items[$i5]}" >&2
    done
    echo "" >&2
    while :; do
        # 提示走 stderr，避免污染 $( ) 捕获的结果
        printf '%s' "$(is_en && echo 'Numbers [Enter=all, e.g. 1,3,5-7 · 0=back]: ' || echo '编号 [回车=全部，支持 1,3,5-7 · 0=返回]: ')" >&2
        _ui_readline TI
        if [ "$TI" = "0" ] || [ "$TI" = "b" ]; then return 255; fi
        if [ -z "$TI" ] || [ "$TI" = "a" ] || [ "$TI" = "A" ]; then echo "ALL"; return 0; fi
        P=$(parse_track_selection "$TI" "$n")
        if [[ "$P" == INVALID:* ]]; then
            echo "$(is_en && echo '  Invalid selection' || echo '  选择无效')" >&2
            continue
        fi
        echo "$P"; return 0
    done
}

# ── 曲目选择（分页列表 + 输入框）─────────────────
# v3.3: 长列表勾选太累，回到"分页浏览 + 编号输入"——回车=全部，支持 1,3,5-7，
# a=全部，0/b=返回上一步。所有 UI 层统一用此交互（不依赖 whiptail）
# 用法: 条目逐行经 stdin 传入；输出 "ALL" 或 "1,3,5"；返回 255 = 返回
ui_pick_tracks() {
    local title="$1" page_n="${2:-15}"
    local items=() line
    while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
    done
    local n=${#items[@]}
    [ "$n" -eq 0 ] && { echo "ALL"; return 0; }
    local total_pages=$(( (n - 1) / page_n + 1 ))
    local page=0 i

    # 分页浏览：回车翻页，q/直接回车到最后页后进入输入
    echo "" >&2
    printf '\033[1m%s\033[0m  (%d %s, %d %s/页)\n' "$title" "$n" \
        "$(is_en && echo tracks || echo 首)" "$page_n" >&2
    while [ $page -lt $total_pages ]; do
        local start=$((page * page_n)) end=$((start + page_n - 1))
        [ $end -ge $n ] && end=$((n - 1))
        for i in $(seq $start $end); do
            printf '  %3d. %s\n' $((i+1)) "${items[$i]}" >&2
        done
        page=$((page + 1))
        if [ $page -lt $total_pages ]; then
            printf '\033[2m%s\033[0m' "$(is_en \
                && echo "── Page $page/$total_pages · Enter=next page · q=input now ── " \
                || echo "── 第 $page/$total_pages 页 · 回车=下一页 · q=直接输入 ── ")" >&2
            local key=""
            _ui_readline key
            [ "$key" = "q" ] || [ "$key" = "Q" ] && break
        fi
    done

    # 输入框
    while :; do
        printf '%s' "$(is_en \
            && echo "Numbers [Enter/a=all, e.g. 1,3,5-7 · 0=back]: " \
            || echo "编号 [回车/a=全部，支持 1,3,5-7 · 0=返回]: ")" >&2
        local TI P
        _ui_readline TI
        if [ "$TI" = "0" ] || [ "$TI" = "b" ]; then return 255; fi
        if [ -z "$TI" ] || [ "$TI" = "a" ] || [ "$TI" = "A" ]; then echo "ALL"; return 0; fi
        P=$(parse_track_selection "$TI" "$n")
        if [[ "$P" == INVALID:* ]]; then
            printf '\033[33m%s\033[0m\n' "$(is_en && echo '  Invalid selection, retry' || echo '  选择无效，重试')" >&2
            continue
        fi
        echo "$P"; return 0
    done
}
# ══════════ mf_lib.sh 内联结束 ══════════

echo "=================================================="
echo " 🎵 musicfeed V3.5.2"
echo "=================================================="
say "支持: 专辑 / 播放列表 / YTM电台 / 单曲" "Supports: albums / playlists / YTM radios / singles"
echo "=================================================="

display_paged_list() {
    local -a items=("$@")
    local total=${#items[@]}
    [ "$total" -eq 0 ] && return 0
    local term_lines=$(get_term_lines)
    local page_size=$((term_lines - 6))
    [ "$page_size" -lt 5 ] && page_size=10
    local total_pages=$(( (total - 1) / page_size + 1 ))
    local page=0

    while true; do
        local start=$((page * page_size))
        local end=$((start + page_size))
        [ "$end" -gt "$total" ] && end=$total

        for ((i=start; i<end; i++)); do
            printf "%s\n" "${items[$i]}"
        done

        if [ "$end" -ge "$total" ]; then
            return 0
        fi

        echo ""
        if is_en; then
            echo "━━━━ Page $((page+1))/$total_pages | Enter=next, q=quit ━━━━"
        else
            echo "━━━━ 第 $((page+1))/$total_pages 页 | 回车继续, q退出 ━━━━"
        fi
        read -r -n 1 key < /dev/tty
        echo ""

        if [[ "$key" =~ ^[Qq]$ ]]; then
            return 1
        fi
        page=$((page + 1))
    done
}

select_artist_folder() {
    local prompt_suffix="$1"
    local folders=()
    folders+=("$MF_DEFAULT_ARTIST_DIR")

    while IFS= read -r line; do
        [[ "$line" == "$MF_DEFAULT_ARTIST_DIR" ]] && continue
        local hidden=0
        for h in "${MF_HIDDEN_DIRS[@]}"; do
            [[ "$line" == "$h" ]] && hidden=1 && break
        done
        [ $hidden -eq 1 ] && continue
        folders+=("$line")
    done < <(ls -F "$MF_BASE_DIR" 2>/dev/null | grep '/$' | sed 's/\///')

    local items=() i
    for i in "${!folders[@]}"; do
        if [ "$i" -eq 0 ]; then
            is_en && items+=("📁 ${folders[$i]} (default)") || items+=("📁 ${folders[$i]} （默认）")
        else
            items+=("📁 ${folders[$i]}")
        fi
    done
    items+=("➕ $(is_en && echo 'Create new folder…' || echo '新建文件夹…')")

    local sel rc
    sel=$(ui_menu "$(is_en && echo "📂 Select artist folder${prompt_suffix}" || echo "📂 请选择歌手文件夹${prompt_suffix}")" "" 1 "${items[@]}")
    rc=$?
    [ $rc -ne 0 ] && return 255

    if [ "$sel" -eq "${#items[@]}" ]; then
        local nn
        nn=$(ui_input "$(is_en && echo 'New folder name' || echo '新文件夹名称')" "")
        [ $? -ne 0 ] && return 255
        [ -n "$nn" ] || nn="$MF_DEFAULT_ARTIST_DIR"
        echo "$nn"
    else
        echo "${folders[$((sel-1))]}"
    fi
}

input_album_artist() {
    local default_name="$1" sel rc o1 o2 o3
    if is_en; then
        o1="Use default: $default_name"
        o2="Skip (don't write album artist)"
        o3="Custom input…"
    else
        o1="使用默认值「$default_name」"
        o2="跳过（不写入专辑艺术家）"
        o3="自定义输入…"
    fi
    sel=$(ui_menu "$(is_en && echo '🎤 Album Artist' || echo '🎤 专辑艺术家')" "" 1 "$o1" "$o2" "$o3")
    rc=$?
    [ $rc -ne 0 ] && return 255
    case "$sel" in
        1) say "✅ 专辑艺术家: $default_name（默认）" "✅ Album artist: $default_name (default)"; echo "$default_name" ;;
        2) say "⏭️ 跳过专辑艺术家" "⏭️ Album artist skipped"; echo "SKIP" ;;
        3)
            local v
            v=$(ui_input "$(is_en && echo 'Album artist' || echo '专辑艺术家')" "$default_name")
            [ $? -ne 0 ] && return 255
            v=$(echo "$v" | sed 's/|/｜/g')
            say "✅ 专辑艺术家: $v（自定义）" "✅ Album artist: $v (custom)"
            echo "$v"
            ;;
    esac
}

input_mv_full() {
    local default_title="$1" default_artist="$2" raw_title="${3:-}" t a al
    local hint=""
    [ -n "$raw_title" ] && hint="🎬 ${raw_title:0:70}"
    t=$(ui_input "$(is_en && echo '🎤 Title' || echo '🎤 歌名')" "$default_title" "$hint")
    [ $? -ne 0 ] && return 255
    a=$(ui_input "$(is_en && echo '👤 Artist' || echo '👤 歌手')" "$default_artist" "$hint")
    [ $? -ne 0 ] && return 255
    al=$(ui_input "$(is_en && echo '💿 Album (Enter = same as title)' || echo '💿 专辑（回车=同歌名）')" "$t" "$hint")
    [ $? -ne 0 ] && return 255
    t=$(echo "$t" | sed 's/|/｜/g; s/=/＝/g')
    a=$(echo "$a" | sed 's/|/｜/g; s/=/＝/g')
    al=$(echo "$al" | sed 's/|/｜/g; s/=/＝/g')
    echo "${t}|${a}|${al}"
}

echo ""
say "请粘贴链接（一行一条），空行或输入 end 开始：" "Paste links, one per line. Submit an empty line or type end to start:"

URLS=()
while true; do
    read -r line
    [[ "$line" == "end" ]] && break
    [[ -z "$line" ]] && break
    URLS+=("$line")
    [ ${#URLS[@]} -ge $MF_MAX_LINKS_PER_RUN ] && { say "⚠️ 已达上限" "⚠️ Link limit reached"; break; }
done

[ ${#URLS[@]} -eq 0 ] && { say "❌ 未检测到链接" "❌ No links detected"; exit 1; }

echo ""
say "🔍 检测链接类型..." "🔍 Detecting link types..."

VALID_URLS=(); URL_TYPES=(); URL_NAMES=()
for url in "${URLS[@]}"; do
    TYPE=$(get_link_type "$url")
    if [ "$TYPE" != "unknown" ]; then
        VALID_URLS+=("$url"); URL_TYPES+=("$TYPE")
        case "$TYPE" in
            album) if is_en; then N="Album"; else N="专辑"; fi;;
            playlist) if is_en; then N="Playlist"; else N="播放列表"; fi;;
            ytm_radio) if is_en; then N="YTM Radio"; else N="YTM电台"; fi;;
            single) if is_en; then N="Single"; else N="单曲"; fi;;
        esac
        URL_NAMES+=("$N")
        echo "✅ $N: $url"
    else
        if is_en; then echo "⚠️ Skipping invalid link: $url"; else echo "⚠️ 跳过无效: $url"; fi
    fi
done

[ ${#VALID_URLS[@]} -eq 0 ] && { say "❌ 没有有效链接" "❌ No valid links"; exit 1; }

echo ""
if is_en; then echo "📊 Valid links: ${#VALID_URLS[@]}"; else echo "📊 有效链接: ${#VALID_URLS[@]} 个"; fi

declare -a ALBUM_CONFIGS
TOTAL_SELECTED=0

for idx in "${!VALID_URLS[@]}"; do
    url="${VALID_URLS[$idx]}"; TYPE="${URL_TYPES[$idx]}"

    echo ""
    echo "=========================================="
    if is_en; then echo "🔍 Fetching info: ${URL_NAMES[$idx]}"; else echo "🔍 获取信息: ${URL_NAMES[$idx]}"; fi
    echo "=========================================="

    IS_SINGLE=false; IS_PLAYLIST=false; IS_ALBUM=false; IS_YTM_RADIO=false
    HAS_METADATA="False"; DISPLAY_NAME=""; TRACK_COUNT=0; DISPLAY_ARTIST=""
    SONG_LIST=""; SONG_LIST_FULL=""
    MV_TITLE=""; MV_ARTIST=""; MV_ALBUM=""; MV_ALBUM_ARTIST=""
    BATCH_ALBUM=""; NORMAL_SELECTION=""; MV_VIDS=""; MV_INFO=""; MV_STRATEGY=""

    if [ "$TYPE" == "album" ]; then
        IS_ALBUM=true; HAS_METADATA="True"
        INFO=$(get_album_info "$url")
        DISPLAY_NAME=$(echo "$INFO" | sed -n '1p'); TRACK_COUNT=$(echo "$INFO" | sed -n '2p')
        [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
        DISPLAY_ARTIST=$(echo "$INFO" | sed -n '3p'); SONG_LIST=$(echo "$INFO" | tail -n +4)
    elif [ "$TYPE" == "ytm_radio" ]; then
        IS_YTM_RADIO=true
        INFO=$(get_playlist_info "$url")
        DISPLAY_NAME=$(echo "$INFO" | sed -n '1p'); TRACK_COUNT=$(echo "$INFO" | sed -n '2p')
        [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
        SONG_LIST_FULL=$(echo "$INFO" | tail -n +3); SONG_LIST=$(echo "$SONG_LIST_FULL" | sed 's/|.*//')
    elif [ "$TYPE" == "playlist" ]; then
        IS_PLAYLIST=true
        INFO=$(get_playlist_info "$url")
        DISPLAY_NAME=$(echo "$INFO" | sed -n '1p'); TRACK_COUNT=$(echo "$INFO" | sed -n '2p')
        [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
        SONG_LIST_FULL=$(echo "$INFO" | tail -n +3); SONG_LIST=$(echo "$SONG_LIST_FULL" | sed 's/|.*//')
    else
        IS_SINGLE=true
        SINGLE_INFO=$(get_single_info "$url")
        SINGLE_ALBUM=$(echo "$SINGLE_INFO" | sed -n '1p'); SINGLE_TITLE=$(echo "$SINGLE_INFO" | sed -n '2p')
        SINGLE_ARTIST=$(echo "$SINGLE_INFO" | sed -n '3p'); SINGLE_UPLOADER=$(echo "$SINGLE_INFO" | sed -n '4p')
        HAS_METADATA=$(echo "$SINGLE_INFO" | sed -n '5p')
        DISPLAY_NAME="${SINGLE_ALBUM:-$SINGLE_TITLE}"; DISPLAY_ARTIST="${SINGLE_ARTIST:-$SINGLE_UPLOADER}"
        SONG_LIST="1. $SINGLE_TITLE"; TRACK_COUNT=1
    fi

    [ -z "$DISPLAY_NAME" ] && { say "⚠️ 无法获取信息，跳过" "⚠️ Could not fetch info, skipping"; continue; }

    if [ "$TRACK_COUNT" -gt 100 ]; then
        if is_en; then
            echo "⚠️ Note: Playlist has $TRACK_COUNT tracks. Due to yt-dlp limits, only the first 100 can be fetched."
        else
            echo "⚠️ 提示: 播放列表共 $TRACK_COUNT 首。受 yt-dlp 限制，目前仅能抓取并下载前 100 首。"
        fi
    fi

    SAFE_NAME=$(sanitize_filename "$DISPLAY_NAME")

    echo ""
    if is_en; then echo "📀 Item: $SAFE_NAME"; else echo "📀 项目: $SAFE_NAME"; fi
    [ -n "$DISPLAY_ARTIST" ] && [ "$DISPLAY_ARTIST" != "Unknown Artist" ] && { if is_en; then echo "🎤 Artist: $DISPLAY_ARTIST"; else echo "🎤 歌手: $DISPLAY_ARTIST"; fi; }
    if is_en; then echo "🎵 Tracks: $TRACK_COUNT"; else echo "🎵 曲目数: $TRACK_COUNT"; fi

    [ "$IS_ALBUM" == true ] && { if is_en; then echo "📌 Type: YTM album"; else echo "📌 类型: 正规专辑"; fi; }
    [ "$IS_YTM_RADIO" == true ] && { if is_en; then echo "📌 Type: YTM radio/mix"; else echo "📌 类型: YTM 电台/合集"; fi; }
    [ "$IS_PLAYLIST" == true ] && { if is_en; then echo "📌 Type: YouTube playlist"; else echo "📌 类型: YouTube 播放列表"; fi; }
    [ "$IS_SINGLE" == true ] && {
        if [ "$HAS_METADATA" == "True" ]; then
            if is_en; then echo "🔧 Type: audio single"; else echo "🔧 类型: 纯音频单曲"; fi;
        else
            if is_en; then echo "🎬 Type: MV single"; else echo "🎬 类型: MV 单曲"; fi;
        fi
    }

    # ═══ v3.3 步骤式交互（whiptail/方向键/数字三层 UI，可回退上一步）═══
    ALBUM_ARTIST=""; ENHANCED_MODE=false
    if [ "$IS_ALBUM" != true ]; then
        ENHANCED_MODE=true
        [ "$IS_YTM_RADIO" == true ] && say "📌 YTM 电台：自动使用独立封面模式" "📌 YTM radio: per-track cover mode automatically"
    fi

    step_pl_type() {
        local t1 t2 sel pos
        pos="$((idx+1))/${#VALID_URLS[@]}"
        if is_en; then t1="YouTube video playlist (MV mode)"; t2="YouTube Music user playlist (per-track mode)"
        else t1="YouTube 视频播放列表（MV 模式）"; t2="YouTube Music 用户自建播放列表（独立封面模式）"; fi
        sel=$(ui_menu "$(is_en && echo "🎬 Playlist type [$pos]: $DISPLAY_NAME" || echo "🎬 播放列表类型 [$pos]：《$DISPLAY_NAME》")" "" 1 "$t1" "$t2")
        [ $? -ne 0 ] && return 1
        if [ "$sel" = "2" ]; then
            IS_PLAYLIST=false; IS_YTM_RADIO=true; TYPE="ytm_radio"
            say "📌 已切换为: YTM 电台/合集模式" "📌 Switched to: YTM radio/mix mode"
        else
            say "📌 使用: MV 模式" "📌 Using: MV mode"
        fi
        return 0
    }

    step_path() {
        ARTIST_DIR=$(select_artist_folder " (《$SAFE_NAME》)")
        [ $? -ne 0 ] && return 1
        ARTIST_PATH="$MF_BASE_DIR/$ARTIST_DIR"
        FINAL_PATH="$ARTIST_PATH"
        local create_subfolder default_subfolder SUB rc
        default_subfolder="$SAFE_NAME"
        # v4.1: 单曲/MV 单曲默认不建子文件夹（列表/专辑/电台默认建），对齐 WebUI 策略
        create_subfolder=y
        [ "$IS_SINGLE" == true ] && create_subfolder=n
        ui_confirm "$(is_en && echo "Create subfolder 《$default_subfolder》?" || echo "创建子文件夹《$default_subfolder》？")" "$create_subfolder"
        rc=$?
        [ $rc -eq 255 ] && return 1
        if [ $rc -eq 0 ]; then
            SUB=$(ui_input "$(is_en && echo '📂 Custom subfolder (Enter = default name)' || echo '📂 自定义子文件夹（回车=默认名称）')" "$default_subfolder")
            [ $? -ne 0 ] && return 1
            [ -n "$SUB" ] || SUB="$default_subfolder"
            local SAFE_SUB
            SAFE_SUB=$(sanitize_filename "$SUB")
            [ -n "$SAFE_SUB" ] && FINAL_PATH="$FINAL_PATH/$SAFE_SUB"
        fi
        mkdir -p "$FINAL_PATH"
        say "✅ 路径: $FINAL_PATH" "✅ Path: $FINAL_PATH"
        return 0
    }

    step_album_opts() {
        local AA_RESULT
        AA_RESULT=$(input_album_artist "$ARTIST_DIR")
        [ $? -ne 0 ] && return 1
        [ "$AA_RESULT" != "SKIP" ] && ALBUM_ARTIST="$AA_RESULT"
        local c1 c2 sel
        if is_en; then c1="Unified cover (one album cover)"; c2="Per-track covers (each song its own)"
        else c1="统一封面（整张专辑一张封面）"; c2="独立封面（每首各自封面）"; fi
        sel=$(ui_menu "$(is_en && echo '🖼️ Cover mode' || echo '🖼️ 封面模式')" "" 1 "$c1" "$c2")
        [ $? -ne 0 ] && return 1
        ENHANCED_MODE=false
        [ "$sel" = "2" ] && ENHANCED_MODE=true
        return 0
    }

    step_tracks() {
        local songs_display=() line SEL
        while IFS= read -r line; do songs_display+=("$line"); done <<< "$SONG_LIST"
        if [ "$TRACK_COUNT" -gt 50 ]; then
            say "💡 共 $TRACK_COUNT 首，建议分批下载（如 1-50, 51-100）" "💡 $TRACK_COUNT tracks total. Consider batches (e.g. 1-50, 51-100)."
        fi
        SEL=$(printf '%s\n' "${songs_display[@]}" | ui_checklist "$(is_en && echo "🎵 Select tracks [$((idx+1))/${#VALID_URLS[@]}]: $DISPLAY_NAME" || echo "🎵 选择曲目 〔$((idx+1))/${#VALID_URLS[@]}〕《$DISPLAY_NAME》")" 12)
        [ $? -ne 0 ] && return 1
        if [ "$SEL" = "ALL" ]; then
            SELECTION="ALL"; SELECTED_COUNT=$TRACK_COUNT
        else
            SELECTION="$SEL"; SELECTED_COUNT=$(echo "$SELECTION" | tr ',' '\n' | wc -l)
        fi
        return 0
    }

    step_mv_single() {
        say "⚠️ MV 单曲：YouTube 未提供音乐元数据" "⚠️ MV single: no music metadata from YouTube"
        local SI ST SA
        SI=$(extract_song_info "$SINGLE_TITLE"); ST=$(echo "$SI" | cut -d'|' -f1); SA=$(echo "$SI" | cut -d'|' -f2)
        [ -z "$SA" ] && SA="$ARTIST_DIR"
        local m1 m2 sel
        if is_en; then m1="Enter title / artist / album manually"; m2="Use video defaults (artist = channel name)"
        else m1="手动输入 歌名 / 歌手 / 专辑"; m2="使用视频默认值（歌手=上传频道名）"; fi
        sel=$(ui_menu "$(is_en && echo '🎬 Track info' || echo '🎬 歌曲信息')" "" 1 "$m1" "$m2")
        [ $? -ne 0 ] && return 1
        if [ "$sel" = "1" ]; then
            MV_STRATEGY="1"
            local MV_INPUT
            MV_INPUT=$(input_mv_full "$ST" "$SA" "$SINGLE_TITLE")
            [ $? -ne 0 ] && return 1
            MV_TITLE=$(echo "$MV_INPUT" | cut -d'|' -f1)
            MV_ARTIST=$(echo "$MV_INPUT" | cut -d'|' -f2)
            MV_ALBUM=$(echo "$MV_INPUT" | cut -d'|' -f3)
        else
            MV_STRATEGY="2"
            MV_TITLE="$SINGLE_TITLE"; MV_ARTIST="$SINGLE_UPLOADER"; MV_ALBUM="$SINGLE_TITLE"
        fi
        return 0
    }

    step_pl_mv() {
        [ "$IS_PLAYLIST" != true ] && return 0
        local SEL_ITEMS="" inum L VID HAS
        if [ "$SELECTION" = "ALL" ]; then
            for ((inum=1; inum<=TRACK_COUNT; inum++)); do SEL_ITEMS="${SEL_ITEMS}${SEL_ITEMS:+ }$inum"; done
        else
            SEL_ITEMS=$(echo "$SELECTION" | tr ',' ' ')
        fi
        local NORMAL_LIST="" MV_LIST=""
        for inum in $SEL_ITEMS; do
            L=$(echo "$SONG_LIST_FULL" | sed -n "${inum}p")
            [ -z "$L" ] && continue
            # 固定字段号（同 mf_batch.sh：$(NF-1)/$NF 在 4 字段行格式下取错列）
            VID=$(echo "$L" | awk -F'|' '{print $2}')
            HAS=$(echo "$L" | awk -F'|' '{print $3}')
            if [ "$HAS" != "True" ]; then MV_LIST="$MV_LIST $VID"; else NORMAL_LIST="${NORMAL_LIST}${NORMAL_LIST:+,}$inum"; fi
        done
        NORMAL_SELECTION="$NORMAL_LIST"
        MV_VIDS=$(echo "$MV_LIST" | xargs)
        if [ -z "$MV_VIDS" ]; then MV_STRATEGY="2"; return 0; fi

        local mv_cnt m1 m2 sel
        mv_cnt=$(echo "$MV_VIDS" | wc -w)
        if is_en; then m1="Enter title / artist / album for each"; m2="Use video defaults (artist = channel name)"
        else m1="逐首输入 歌名 / 歌手 / 专辑"; m2="使用视频默认值（歌手=上传频道名）"; fi
        sel=$(ui_menu "$(is_en && echo "🎬 $mv_cnt MV track(s) in playlist" || echo "🎬 检测到 $mv_cnt 首 MV 曲目")" "" 1 "$m1" "$m2")
        [ $? -ne 0 ] && return 1
        if [ "$sel" = "1" ]; then
            MV_STRATEGY="1"
            echo ""
            say "--- 🎬 逐首确认 ---" "--- 🎬 Confirm each MV track ---"
            MV_INFO=""
            local VID2 LINE INUM RAW_TITLE SInfo ST2 SA2 NAME_INPUT TITLE ARTIST ALBUM
            while IFS= read -r VID2; do
                [ -z "$VID2" ] && continue
                LINE=$(echo "$SONG_LIST_FULL" | grep -F -- "|$VID2|")
                [ -z "$LINE" ] && continue
                INUM=$(echo "$LINE" | sed 's/^\([0-9]*\)\. .*/\1/')
                RAW_TITLE=$(echo "$LINE" | sed 's/^[0-9]*\. //; s/|[^|]*|[^|]*$//')
                SInfo=$(extract_song_info "$RAW_TITLE"); ST2=$(echo "$SInfo" | cut -d'|' -f1); SA2=$(echo "$SInfo" | cut -d'|' -f2)
                [ -z "$SA2" ] && SA2="$ARTIST_DIR"
                echo "" >&2
                if is_en; then echo "━━━━ Track ${INUM}: ${RAW_TITLE:0:60}..." >&2
                else echo "━━━━ 第 ${INUM} 首: ${RAW_TITLE:0:60}..." >&2; fi
                NAME_INPUT=$(input_mv_full "$ST2" "$SA2" "$RAW_TITLE")
                [ $? -ne 0 ] && return 1
                TITLE=$(echo "$NAME_INPUT" | cut -d'|' -f1)
                ARTIST=$(echo "$NAME_INPUT" | cut -d'|' -f2)
                ALBUM=$(echo "$NAME_INPUT" | cut -d'|' -f3)
                [ -n "$MV_INFO" ] && MV_INFO="${MV_INFO};"
                MV_INFO="${MV_INFO}${VID2}=${TITLE}=${ARTIST}=${ALBUM}"
            done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
        else
            MV_STRATEGY="2"
            NORMAL_SELECTION="$SELECTION"; MV_VIDS=""; MV_INFO=""
        fi
        if [ -n "$NORMAL_SELECTION" ]; then SELECTION="$NORMAL_SELECTION"; else SELECTION=""; fi
        return 0
    }

    # 组装本链接的步骤链（按类型裁剪），状态机驱动，支持回退
    STEPS=(); si=0; r=0   # for 循环顶层非函数内，不能用 local
    [ "$IS_PLAYLIST" == true ] && STEPS+=(pl_type)
    STEPS+=(path)
    [ "$IS_ALBUM" == true ] && STEPS+=(album_opts)
    [ "$TRACK_COUNT" -gt 1 ] && STEPS+=(tracks)
    { [ "$IS_SINGLE" == true ] && [ "$HAS_METADATA" != "True" ]; } && STEPS+=(mv_single)
    STEPS+=(pl_mv)

    si=0
    while :; do
        case "${STEPS[$si]}" in
            pl_type)    step_pl_type; r=$? ;;
            path)       step_path; r=$? ;;
            album_opts) step_album_opts; r=$? ;;
            tracks)     step_tracks; r=$? ;;
            mv_single)  step_mv_single; r=$? ;;
            pl_mv)      step_pl_mv; r=$? ;;
        esac
        if [ $r -eq 0 ]; then
            si=$((si+1))
            [ $si -ge ${#STEPS[@]} ] && break
        else
            if [ $si -gt 0 ]; then
                si=$((si-1))
            else
                ui_confirm "$(is_en && echo 'No previous step here — skip this link?' || echo '已是最早步骤——跳过这个链接？')" n
                [ $? -eq 0 ] && { say "⏭️ 已跳过" "⏭️ Skipped"; continue 2; }
            fi
        fi
    done

    NT=$((TOTAL_SELECTED + SELECTED_COUNT))
    [ "$NT" -gt "$MF_MAX_TRACKS_PER_RUN" ] && { if is_en; then echo "⚠️ Total selection exceeds $MF_MAX_TRACKS_PER_RUN tracks"; else echo "⚠️ 累计超限 $MF_MAX_TRACKS_PER_RUN 首"; fi; continue; }
    TOTAL_SELECTED=$NT

    ALBUM_CONFIGS+=("$(safe_field "$SAFE_NAME")|$SELECTION|$url|$FINAL_PATH|$(safe_field "$ALBUM_ARTIST")|$ENHANCED_MODE|$TYPE|$HAS_METADATA|$(safe_field "$MV_TITLE")|$(safe_field "$MV_ARTIST")|$(safe_field "$MV_ALBUM")|$(safe_field "$MV_ALBUM_ARTIST")|$(safe_field "$BATCH_ALBUM")|||$NORMAL_SELECTION|$MV_VIDS|$(safe_field "$MV_INFO")|$MV_STRATEGY")

    echo ""
done

[ ${#ALBUM_CONFIGS[@]} -eq 0 ] && { say "❌ 没有项目" "❌ No items to download"; exit 1; }

if is_en; then echo "📊 Summary: ${#ALBUM_CONFIGS[@]} item(s), $TOTAL_SELECTED track(s) total"
else echo "📊 统计: ${#ALBUM_CONFIGS[@]} 个项目，累计 $TOTAL_SELECTED 首"; fi

LOG_DIR="${SCRIPT_DIR}/log"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/musicfeed-$(date +%Y%m%d-%H%M%S).log"

WORKER_SH=$(mktemp /tmp/musicfeed_worker_XXXXXX.sh)
chmod +x "$WORKER_SH"

cat > "$WORKER_SH" << 'WORKEREOF'
#!/bin/bash
YTDLP="__YTDLP__"
NODE_ARGS="__NODE_ARGS__"
LOG_FILE="__LOG_FILE__"
AUDIO_FORMAT="__AUDIO_FORMAT__"

if [ "$AUDIO_FORMAT" = "m4a" ]; then
    AUDIO_EXT="m4a"
    FORMAT_ARGS=(-f "ba[ext=m4a]/ba" --audio-format m4a --audio-quality 0)
else
    AUDIO_EXT="opus"
    FORMAT_ARGS=(-f ba -x --audio-format opus --audio-quality 0)
fi


cleanup_worker() {
    rm -f /tmp/existing_before_$$* /tmp/cover_$$* /tmp/cover_mv_$$* /tmp/cover_$$_* 2>/dev/null
}
trap cleanup_worker EXIT

log() { echo "$1" >> "$LOG_FILE"; }

file_size() {
    local f="$1"
    if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"; else stat -f%z "$f"; fi
}

cover_crop_center() {
    local src="$1" dst="$2"
    ffmpeg -i "$src" \
        -vf "crop=min(iw\,ih):min(iw\,ih):(iw-min(iw\,ih))/2:(ih-min(iw\,ih))/2" \
        -q:v 2 -y "$dst" 2>/dev/null
    [ -f "$dst" ] && return 0 || return 1
}

cover_compress() {
    local src="$1" dst="$2"
    ffmpeg -i "$src" -q:v 2 -y "$dst" 2>/dev/null
    [ -f "$dst" ] && return 0 || return 1
}

mv_write_id3() {
    python3 - "$@" << 'PYEOF'
import sys, os, re

def split_artists(artist_str):
    """智能拆分多艺人字符串，返回艺人列表"""
    if not artist_str:
        return ['Unknown Artist']
    
    # 先统一中文逗号为英文逗号 (中文逗号 Unicode: \uff0c)
    artist_str = artist_str.replace('\uff0c', ',')
    
    # 定义分隔符模式（按优先级排序）
    patterns = [
        r'\s+feat\.\s+',
        r'\s+ft\.\s+',
        r'\s+&\s+',
        r'\s*,\s*',  # 逗号 (已统一处理)
        r'\s+with\s+',
        r'\s+vs\.\s+'
    ]
    
    result = [artist_str]
    for pattern in patterns:
        new_result = []
        for item in result:
            parts = re.split(pattern, item, flags=re.IGNORECASE)
            new_result.extend([p.strip() for p in parts if p.strip()])
        result = new_result
    
    # 去重并保持顺序
    seen = set()
    unique = []
    for a in result:
        if a and a not in seen and a.lower() not in seen:
            seen.add(a.lower())
            unique.append(a)
    
    return unique if unique else ['Unknown Artist']

fpath = sys.argv[1]; title = sys.argv[2]; artist = sys.argv[3]
album = sys.argv[4]; album_artist = sys.argv[5]; cover_file = sys.argv[6] if len(sys.argv) > 6 else ""

# 拆分多艺人
artists_list = split_artists(artist)

if fpath.endswith('.m4a'):
    from mutagen.mp4 import MP4, MP4Cover
    audio = MP4(fpath)
    audio['\xa9nam'] = [title]
    audio['\xa9ART'] = artists_list  # 多艺人列表
    if album: audio['\xa9alb'] = [album]
    elif '\xa9alb' in audio: del audio['\xa9alb']
    if album_artist: audio['aART'] = [album_artist]
    elif 'aART' in audio: del audio['aART']
    if cover_file and os.path.exists(cover_file):
        with open(cover_file, 'rb') as img:
            audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
        print(f'  ✅ +Cover: {os.path.basename(fpath)}')
    else:
        print(f'  ✅ ID3: {os.path.basename(fpath)}')
    audio.save()
else:
    from mutagen.oggopus import OggOpus
    audio = OggOpus(fpath)
    audio['title'] = [title]
    audio['artist'] = artists_list  # 多艺人列表 (Vorbis Comments 原生支持多值)
    if album: audio['album'] = [album]
    elif 'album' in audio: del audio['album']
    if album_artist: audio['ALBUMARTIST'] = [album_artist]  # 大写 ALBUMARTIST
    elif 'ALBUMARTIST' in audio: del audio['ALBUMARTIST']
    if cover_file and os.path.exists(cover_file):
        from mutagen.flac import Picture
        import base64
        with open(cover_file, 'rb') as img:
            pic = Picture(); pic.data = img.read(); pic.type = 3; pic.mime = 'image/jpeg'
            audio['metadata_block_picture'] = [base64.b64encode(pic.write()).decode('ascii')]
        print(f'  ✅ +Cover: {os.path.basename(fpath)}')
    else:
        print(f'  ✅ ID3: {os.path.basename(fpath)}')
    audio.save()
PYEOF
}

embed_cover() {
    python3 - "$@" << 'PYEOF'
import sys, os, re, base64

def split_artists(artist_str):
    """智能拆分多艺人字符串，返回艺人列表"""
    if not artist_str:
        return ['Unknown Artist']
    artist_str = artist_str.replace('\uff0c', ',')
    patterns = [r'\s+feat\.\s+', r'\s+ft\.\s+', r'\s+&\s+', r'\s*,\s*', r'\s+with\s+', r'\s+vs\.\s+']
    result = [artist_str]
    for pattern in patterns:
        new_result = []
        for item in result:
            parts = re.split(pattern, item, flags=re.IGNORECASE)
            new_result.extend([p.strip() for p in parts if p.strip()])
        result = new_result
    seen = set()
    unique = []
    for a in result:
        if a and a not in seen and a.lower() not in seen:
            seen.add(a.lower())
            unique.append(a)
    return unique if unique else ['Unknown Artist']

fpath = sys.argv[1]; aa = sys.argv[2]; an = sys.argv[3]
hc = sys.argv[4]; em = sys.argv[5]; oa = sys.argv[6]; cf = sys.argv[7] if len(sys.argv) > 7 else ""
# v3.4: 无元数据曲目按 title 首个 " - " 拆分出的强制歌名/歌手（优先级高于文件名提取）
ft = sys.argv[8] if len(sys.argv) > 8 else ''
fa = sys.argv[9] if len(sys.argv) > 9 else ''

# 从文件名提取艺人信息（如果有）
basename = os.path.basename(fpath)
artist_from_file = None
if ' - ' in basename:
    artist_part = basename.split(' - ')[0]
    if artist_part and artist_part != 'NA':
        artists_list = split_artists(artist_part)
    else:
        artists_list = []
else:
    artists_list = []
if fa:
    artists_list = split_artists(fa)

try:
    if fpath.endswith('.m4a'):
        from mutagen.mp4 import MP4, MP4Cover
        audio = MP4(fpath)
        if aa and aa not in ('None','SKIP',''): audio['aART'] = [aa]
        elif 'aART' in audio: del audio['aART']
        # 写入多艺人标签
        if artists_list:
            audio['\xa9ART'] = artists_list
        if ft: audio['\xa9nam'] = [ft]
        if em=='true' and oa and oa!='None' and not oa.startswith('%'): audio['\xa9alb'] = [oa]
        else: audio['\xa9alb'] = [an]
        if em=='true' and 'trkn' in audio: del audio['trkn']
        if hc=='true' and cf and os.path.exists(cf):
            with open(cf,'rb') as img: audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
            print(f'  ✅ +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ✅ ID3: {os.path.basename(fpath)}')
        audio.save()
    else:
        from mutagen.oggopus import OggOpus
        from mutagen.flac import Picture
        audio = OggOpus(fpath)
        if aa and aa not in ('None','SKIP',''): audio['ALBUMARTIST'] = [aa]
        elif 'ALBUMARTIST' in audio: del audio['ALBUMARTIST']
        # 写入多艺人标签
        if artists_list:
            audio['artist'] = artists_list
        if ft: audio['title'] = [ft]
        if em=='true' and oa and oa!='None' and not oa.startswith('%'): audio['album'] = [oa]
        else: audio['album'] = [an]
        if em=='true' and 'tracknumber' in audio: del audio['tracknumber']
        if hc=='true' and cf and os.path.exists(cf):
            with open(cf,'rb') as img:
                pic=Picture(); pic.data=img.read(); pic.type=3; pic.mime='image/jpeg'
                audio['metadata_block_picture'] = [base64.b64encode(pic.write()).decode('ascii')]
            print(f'  ✅ +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ✅ ID3: {os.path.basename(fpath)}')
        audio.save()
except Exception as e:
    print(f'  ❌ Failed: {os.path.basename(fpath)} - {e}')
PYEOF
}

get_cover_url() {
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
thumbs = sorted(d.get('thumbnails',[]), key=lambda x: x.get('width',0)*x.get('height',0), reverse=True)
if thumbs: print(thumbs[0]['url'])
" "$1" 2>/dev/null
}

download_cover() {
    local json_file="$1" out_var="$2"
    local url=""
    url=$(get_cover_url "$json_file")
    if [ -n "$url" ]; then
        if ! command -v curl &>/dev/null; then
            echo "  curl not found, cannot download cover" >&2
            return 1
        fi
        local tmp="/tmp/cover_$$.jpg"
        curl -sL "$url" -o "$tmp" 2>/dev/null
        if [ -f "$tmp" ] && [ "$(file_size "$tmp" 2>/dev/null)" -gt 10240 ]; then
            eval "$out_var=$tmp"
            return 0
        fi
    fi
    return 1
}

declare -A MV_DATA
parse_mv_info() {
    local info="$1"
    if [ -z "$info" ]; then return; fi
    IFS=';' read -ra ENTRIES <<< "$info"
    for entry in "${ENTRIES[@]}"; do
        VID=$(echo "$entry" | cut -d= -f1)
        TITLE=$(echo "$entry" | cut -d= -f2)
        ARTIST=$(echo "$entry" | cut -d= -f3)
        ALBUM=$(echo "$entry" | cut -d= -f4)
        [ -n "$VID" ] && MV_DATA["$VID"]="$TITLE|$ARTIST|$ALBUM"
    done
}

# v4.3: 电台/社区列表无元数据曲目的歌名/歌手提取（与 mf_lib.sh extract_nm_info 同一实现，
# worker 是生成的独立脚本，需内嵌一份）
# 用法: extract_nm_info "原始标题" "uploader"；输出 "歌名|歌手"
extract_nm_info() {
    python3 - "$1" "$2" << 'NM_PYEOF'
import re, sys

POLL = re.compile(r'歌詞|歌词|動態|动态|MV|Official|官方|Video|Audio|Visualizer|Live|完整版|主題曲|主题曲|片尾曲|片頭曲|片头曲', re.I)
KEEP = re.compile(r'feat|ft\.|国|國|粤|粵', re.I)
BR = re.compile(r'（([^（）()]*)）|\(([^()]*)\)|『([^『』]*)』|「([^「」]*)」|【([^【】]*)】|《([^《》]*)》|\[([^\[\]]*)\]')

def inner_of(m):
    return next(g for g in m.groups() if g is not None)

def br_proc(s):
    prev = None
    while prev != s:
        prev = s
        def repl(m):
            inner = inner_of(m)
            flat = BR.sub(' ', inner)
            if POLL.search(flat):
                return ''
            if KEEP.search(flat):
                return m.group(0)
            return inner
        s = BR.sub(repl, s)
    return s

def clean(s):
    s = re.sub(r'\s*-\s*$', '', s)
    s = re.sub(r'\s{2,}', ' ', s)
    return s.strip(' -').strip()

def esc(s):
    return (s or '').replace('|', '｜')

title = sys.argv[1] or ''
up = re.sub(r'\s*-\s*Topic\s*$', '', sys.argv[2] or '').strip()
t = title.replace('–', '-').replace('—', '-')

m = re.search(r'《([^《》]*)》', t) or re.search(r'【([^【】]*)】', t) or re.search(r'\[([^\[\]]*)\]', t)
if m:
    song = br_proc(m.group(1)).strip()
    if song and not POLL.search(BR.sub(' ', song)):
        prefix = re.sub(r'^(\[[^\]]*\]\s*)+', '', t[:m.start()].strip())
        prefix = re.sub(r'[\s\-:：*|｜]+$', '', prefix).strip()
        artist = prefix if prefix and len(prefix) <= 30 else up
        print(f"{esc(song)}|{esc(artist)}")
        sys.exit(0)

t2 = br_proc(t)
segs = [s.strip() for s in t2.split(' - ') if s.strip()]
if len(segs) >= 2:
    if up:
        keep = [s for s in segs if not (s in up or up in s)]
        if keep and len(keep) < len(segs):
            print(f"{esc(clean(keep[0]))}|{esc(up)}")
            sys.exit(0)
    print(f"{esc(clean(' - '.join(segs[1:])))}|{esc(segs[0])}")
    sys.exit(0)

print(f"{esc(clean(t2))}|{esc(up)}")
NM_PYEOF
}

log "⚙️ PID: $$ | 🕒 $(date '+%Y-%m-%d %H:%M:%S')"
WORKEREOF

replace_token() {
    python3 - "$WORKER_SH" "$1" "$2" << 'PYEOF'
import sys
path, token, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as f:
    data = f.read()
data = data.replace(token, value)
with open(path, 'w', encoding='utf-8') as f:
    f.write(data)
PYEOF
}

replace_token "__YTDLP__" "$MF_YTDLP"
replace_token "__NODE_ARGS__" "$MF_NODE_ARGS"
replace_token "__LOG_FILE__" "$LOG_FILE"
replace_token "__AUDIO_FORMAT__" "$MF_AUDIO_FORMAT"

echo 'ALBUMS=(' >> "$WORKER_SH"
for config in "${ALBUM_CONFIGS[@]}"; do
    printf ' %q\n' "$config" >> "$WORKER_SH"
done
echo ')' >> "$WORKER_SH"

cat >> "$WORKER_SH" << 'LOOPEOF'
for album_entry in "${ALBUMS[@]}"; do
    ALBUM_NAME=$(echo "$album_entry" | cut -d'|' -f1)
    SELECTION=$(echo "$album_entry" | cut -d'|' -f2)
    url=$(echo "$album_entry" | cut -d'|' -f3)
    FINAL_PATH=$(echo "$album_entry" | cut -d'|' -f4)
    ALBUM_ARTIST=$(echo "$album_entry" | cut -d'|' -f5)
    ENHANCED_MODE=$(echo "$album_entry" | cut -d'|' -f6)
    TYPE=$(echo "$album_entry" | cut -d'|' -f7)

    # 统一封面临时目录清理（循环头，兼容 continue 路径）
    [ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null
    CTD=""; UNIFIED_COVER=""
    HAS_METADATA=$(echo "$album_entry" | cut -d'|' -f8)
    MV_TITLE=$(echo "$album_entry" | cut -d'|' -f9)
    MV_ARTIST=$(echo "$album_entry" | cut -d'|' -f10)
    MV_ALBUM=$(echo "$album_entry" | cut -d'|' -f11)
    MV_ALBUM_ARTIST=$(echo "$album_entry" | cut -d'|' -f12)
    BATCH_ALBUM=$(echo "$album_entry" | cut -d'|' -f13)
    NORMAL_SELECTION=$(echo "$album_entry" | cut -d'|' -f16)
    MV_VIDS=$(echo "$album_entry" | cut -d'|' -f17)
    MV_INFO=$(echo "$album_entry" | cut -d'|' -f18)
    MV_STRATEGY=$(echo "$album_entry" | cut -d'|' -f19)

    log "========================================"
    log "💿 $ALBUM_NAME | 📂 $FINAL_PATH | 📌 $TYPE"
    log "========================================"
    mkdir -p "$FINAL_PATH"

    IS_MV_SINGLE=false
    [ "$TYPE" = "single" ] && [ "$HAS_METADATA" != "True" ] && [ -n "$MV_TITLE" ] && IS_MV_SINGLE=true

    ls "$FINAL_PATH"/*.$AUDIO_EXT 2>/dev/null > /tmp/existing_before_$$.txt


    if [ "$ENHANCED_MODE" != "true" ]; then
        log "🖼️ Unified cover..."
        CTD=$(mktemp -d)
        "$YTDLP" $NODE_ARGS --no-warnings --write-thumbnail --skip-download --convert-thumbnails jpg \
            --playlist-items 1 -o "$CTD/%(id)s" "$url" >> "$LOG_FILE" 2>&1
        CS=$(find "$CTD" -name "*.jpg" -type f -exec ls -la {} \; 2>/dev/null | sort -k5 -rn | head -1 | awk '{print $NF}')
        if [ -n "$CS" ]; then
            # v3.3: 封面全程留在临时目录，最终目录不再落 cover.jpg
            if cover_compress "$CS" "$CTD/cover.jpg" 2>/dev/null && [ -f "$CTD/cover.jpg" ]; then
                UNIFIED_COVER="$CTD/cover.jpg"
                log "✅ Unified cover (compressed)"
            else
                UNIFIED_COVER="$CS"
                log "✅ Unified cover (compression failed, keeping original)"
            fi
        else
            log "⚠️ Could not fetch unified cover"
        fi
    fi

    MV_DATA=()
    parse_mv_info "$MV_INFO"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "🚚 MV single (temp)..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --write-info-json \
            "${FORMAT_ARGS[@]}" \
            -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    elif [ "$MV_STRATEGY" = "2" ]; then
        log "🚚 Default mode batch..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
            --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
            "${FORMAT_ARGS[@]}" \
            --playlist-items "$SELECTION" \
            -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    else
        if [ -n "$NORMAL_SELECTION" ]; then
            log "🚚 Normal track batch..."
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" \
                --playlist-items "$NORMAL_SELECTION" \
                -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1
        fi

        if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
            while IFS= read -r VID; do
                [ -z "$VID" ] && continue
                SINGLE_URL="https://www.youtube.com/watch?v=$VID"
                log "🚚 MV track: $VID"
                "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                    --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --write-info-json \
                    "${FORMAT_ARGS[@]}" \
                    -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$SINGLE_URL" >> "$LOG_FILE" 2>&1
            done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
        fi

        if [ -z "$NORMAL_SELECTION" ] && [ -z "$MV_VIDS" ]; then
            log "🚚 Downloading..."
            DOWNLOAD_ARGS=""
            [ "$SELECTION" != "ALL" ] && [ -n "$SELECTION" ] && DOWNLOAD_ARGS="--playlist-items $SELECTION"
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" $DOWNLOAD_ARGS \
                -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1
        fi
    fi

    log "✅ Download complete"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "🏷️ MV single post-processing..."
        for mv_f in "$FINAL_PATH"/temp_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            SAFE_ARTIST=$(echo "$MV_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
            SAFE_TITLE=$(echo "$MV_TITLE" | sed 's/[\/:*?"<>|]/-/g')
            NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
            NEW_PATH="$FINAL_PATH/$NEW_NAME"
            [ -f "$NEW_PATH" ] && NEW_PATH="$FINAL_PATH/${SAFE_ARTIST} - ${SAFE_TITLE}_$(date +%s).$AUDIO_EXT"
            mv "$mv_f" "$NEW_PATH"
            log "  📝 Renamed: $(basename "$mv_f") → $NEW_NAME"
            CF=""; JSON_FILE="${NEW_PATH%.$AUDIO_EXT}.info.json"
            [ ! -f "$JSON_FILE" ] && JSON_FILE=$(find "$FINAL_PATH" -name "temp_mv_*.info.json" 2>/dev/null | head -1)
            if [ -f "$JSON_FILE" ]; then
                if download_cover "$JSON_FILE" CF; then
                    CC="/tmp/cover_$$_compressed.jpg"
                    cover_compress "$CF" "$CC" 2>/dev/null
                    if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover compressed"; fi
                fi
                rm -f "$JSON_FILE"
            fi
            mv_write_id3 "$NEW_PATH" "$MV_TITLE" "$MV_ARTIST" "$MV_ALBUM" "" "$CF"
            [ -n "$CF" ] && rm -f "$CF"
            echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
        done
        rm -f "$FINAL_PATH"/temp_mv_* "$FINAL_PATH"/*.webm 2>/dev/null
        log "🎉 Done: $ALBUM_NAME"
        continue
    fi

    if [ "$MV_STRATEGY" = "2" ]; then
        log "🏷️ Default mode post-processing..."
        for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
            [ -f "$f" ] || continue
            [[ "$(basename "$f")" == temp_* ]] && continue
            if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
                log "  ⏭️ Skipping existing: $(basename "$f")"
                continue
            fi
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            TITLE=""; SA=""; REAL_ALBUM=""; HS=false; FORCE_TITLE=""; FORCE_ARTIST=""
            if [ -f "$JSON_FILE" ]; then
                TITLE=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                REAL_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                [ -n "$TITLE" ] && [ -n "$SA" ] && HS=true
            fi
            # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info，与 postproc_normal 同规则）
            if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != "true" ] && [ -f "$JSON_FILE" ]; then
                NM_UP=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('uploader',''))" "$JSON_FILE" 2>/dev/null)
                NM_INFO=$(extract_nm_info "$TITLE" "$NM_UP")
                FORCE_TITLE=$(printf '%s' "$NM_INFO" | cut -d'|' -f1)
                FORCE_ARTIST=$(printf '%s' "$NM_INFO" | cut -d'|' -f2)
                log "  ✂️ Extract: '$FORCE_ARTIST' / '$FORCE_TITLE'"
            fi
            CF=""
            if [ -f "$JSON_FILE" ]; then
                if download_cover "$JSON_FILE" CF; then
                    if [ "$HS" = "true" ]; then
                        CC="/tmp/cover_$$_cropped.jpg"
                        cover_crop_center "$CF" "$CC" 2>/dev/null
                        if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover cropped (metadata)"; fi
                    else
                        CC="/tmp/cover_$$_compressed.jpg"
                        cover_compress "$CF" "$CC" 2>/dev/null
                        if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover compressed (no metadata)"; fi
                    fi
                fi
                rm -f "$JSON_FILE"
            fi
            [ -n "$REAL_ALBUM" ] && FINAL_ALBUM="$REAL_ALBUM" || FINAL_ALBUM="$TITLE"
            embed_cover "$f" "" "$ALBUM_NAME" "$([ -n "$CF" ] && echo true || echo false)" "true" "$FINAL_ALBUM" "$CF" "$FORCE_TITLE" "$FORCE_ARTIST" >> "$LOG_FILE" 2>&1
            [ -n "$CF" ] && rm -f "$CF"
            # v4.3: 无元数据曲目按提取结果重命名（歌手 - 歌名），与 MV 分支同语义
            if [ "$HS" != "true" ] && [ -n "$FORCE_TITLE" ] && [ -n "$FORCE_ARTIST" ]; then
                SAFE_ARTIST=$(printf '%s' "$FORCE_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
                SAFE_TITLE=$(printf '%s' "$FORCE_TITLE" | sed 's/[\/:*?"<>|]/-/g')
                NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
                if [ "$(basename "$f")" != "$NEW_NAME" ]; then
                    if [ -e "$FINAL_PATH/$NEW_NAME" ]; then
                        # 目标名已存在 = 同名曲目已在库中：删本次新副本（对齐跳过已有语义），
                        # 否则重命名会破坏 yt-dlp 按文件名判重的幂等性
                        rm -f "$f"
                        f="$FINAL_PATH/$NEW_NAME"
                        log "  🔁 Duplicate: exists $NEW_NAME, new copy removed"
                    else
                        mv "$f" "$FINAL_PATH/$NEW_NAME"
                        f="$FINAL_PATH/$NEW_NAME"
                        log "  📝 Renamed: $NEW_NAME"
                    fi
                fi
            fi
            echo "$f" >> /tmp/existing_before_$$.txt
        done
        rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.* 2>/dev/null
        rm -f /tmp/existing_before_$$.txt
        log "🎉 Done: $ALBUM_NAME"
        continue
    fi

    if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
        log "🏷️ MV track post-processing..."
        for mv_f in "$FINAL_PATH"/temp_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            JSON_FILE="${mv_f%.$AUDIO_EXT}.info.json"
            VID=""
            [ -f "$JSON_FILE" ] && VID=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id',''))" "$JSON_FILE" 2>/dev/null)
            if [ -n "$VID" ] && [ -n "${MV_DATA[$VID]}" ]; then
                IFS='|' read -r TITLE ARTIST ALBUM <<< "${MV_DATA[$VID]}"
                # v4.3: 预览误判安全网 —— info.json 有完整 artist+album 的曲目优先走 meta
                #（预览 hasMeta 是启发式，歌手频道上传的音频版本可能漏判为 MV）
                HS_META="false"
                if [ -f "$JSON_FILE" ]; then
                    M_SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                    M_AL=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                    M_TI=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                    M_TR=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('track',''))" "$JSON_FILE" 2>/dev/null)
                    [ -n "$M_SA" ] && [ -n "$M_AL" ] && HS_META="true"
                fi
                if [ "$HS_META" = "true" ]; then
                    TITLE="${M_TR:-$M_TI}"; ARTIST="$M_SA"; ALBUM="$M_AL"
                    log "  📀 Metadata found, overriding MV manual info"
                fi
                SAFE_ARTIST=$(echo "$ARTIST" | sed 's/[\/:*?"<>|]/-/g')
                SAFE_TITLE=$(echo "$TITLE" | sed 's/[\/:*?"<>|]/-/g')
                NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
                NEW_PATH="$FINAL_PATH/$NEW_NAME"
                [ -f "$NEW_PATH" ] && NEW_PATH="$FINAL_PATH/${SAFE_ARTIST} - ${SAFE_TITLE}_$(date +%s).$AUDIO_EXT"
                mv "$mv_f" "$NEW_PATH"
                log "  📝 Renamed: $(basename "$mv_f") → $NEW_NAME"
                CF=""
                SA_META=""; HS=false
                if [ -f "$JSON_FILE" ]; then
                    SA_META="$M_SA"
                    [ -n "$TITLE" ] && [ -n "$SA_META" ] && HS=true
                fi
                if [ -f "$JSON_FILE" ]; then
                    if download_cover "$JSON_FILE" CF; then
                        if [ "$HS" = "true" ]; then
                            CC="/tmp/cover_$$_cropped.jpg"
                            cover_crop_center "$CF" "$CC" 2>/dev/null
                            if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover cropped (metadata fallback)"; fi
                        else
                            CC="/tmp/cover_$$_compressed.jpg"
                            cover_compress "$CF" "$CC" 2>/dev/null
                            if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover compressed (no metadata)"; fi
                        fi
                    fi
                fi
                FINAL_ALBUM="${ALBUM:-$TITLE}"
                mv_write_id3 "$NEW_PATH" "$TITLE" "$ARTIST" "$FINAL_ALBUM" "" "$CF"
                [ -n "$CF" ] && rm -f "$CF"
                echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
            fi
            [ -f "$JSON_FILE" ] && rm -f "$JSON_FILE"
        done
    fi

    log "🏷️ Post-processing..."
    for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == temp_* || "$(basename "$f")" == temp_mv_* ]] && continue
        if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
            log "  ⏭️ Skipping existing: $(basename "$f")"
            continue
        fi
        ORIG_ALBUM=""; CF=""; HC="false"; FORCE_TITLE=""; FORCE_ARTIST=""
        if [ "$ENHANCED_MODE" = "true" ]; then
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            if [ -f "$JSON_FILE" ]; then
                ORIG_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                HS=false
                [ -n "$ORIG_ALBUM" ] && [ -n "$SA" ] && HS=true
                log "  📀 Metadata: $HS"
                # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info）
                if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != true ]; then
                    TITLE_RAW=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                    NM_UP=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('uploader',''))" "$JSON_FILE" 2>/dev/null)
                    NM_INFO=$(extract_nm_info "$TITLE_RAW" "$NM_UP")
                    FORCE_TITLE=$(printf '%s' "$NM_INFO" | cut -d'|' -f1)
                    FORCE_ARTIST=$(printf '%s' "$NM_INFO" | cut -d'|' -f2)
                    log "  ✂️ Extract: '$FORCE_ARTIST' / '$FORCE_TITLE'"
                fi
                if download_cover "$JSON_FILE" CF; then
                    if [ "$HS" = "true" ]; then
                        CC="/tmp/cover_$$_cropped.jpg"
                        if cover_crop_center "$CF" "$CC"; then
                            rm -f "$CF"; CF="$CC"; HC="true"
                            log "  🖼️ Cover cropped (1:1)"
                        else
                            log "  ⚠️ Crop failed, using original"
                            HC="true"
                        fi
                    else
                        CC="/tmp/cover_$$_compressed.jpg"
                        if cover_compress "$CF" "$CC"; then
                            rm -f "$CF"; CF="$CC"; HC="true"
                            log "  🖼️ Cover compressed"
                        else
                            HC="true"
                        fi
                    fi
                fi
                rm -f "$JSON_FILE"
            fi
        else
            ORIG_ALBUM="$ALBUM_NAME"
            if [ -n "$UNIFIED_COVER" ] && [ -f "$UNIFIED_COVER" ] && [ "$(file_size "$UNIFIED_COVER" 2>/dev/null)" -gt 10240 ]; then
                CF="$UNIFIED_COVER"
                HC="true"
                log "  🖼️ Using unified cover"
            fi
        fi
        embed_cover "$f" "$ALBUM_ARTIST" "$ALBUM_NAME" "$HC" "$ENHANCED_MODE" "$ORIG_ALBUM" "$CF" "$FORCE_TITLE" "$FORCE_ARTIST" >> "$LOG_FILE" 2>&1
        [ -n "$CF" ] && [ "$CF" != "$UNIFIED_COVER" ] && rm -f "$CF"
        # v4.3: 无元数据曲目按提取结果重命名（歌手 - 歌名），与 MV 分支同语义
        if [ "$HS" != "true" ] && [ -n "$FORCE_TITLE" ] && [ -n "$FORCE_ARTIST" ]; then
            SAFE_ARTIST=$(printf '%s' "$FORCE_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
            SAFE_TITLE=$(printf '%s' "$FORCE_TITLE" | sed 's/[\/:*?"<>|]/-/g')
            NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
            if [ "$(basename "$f")" != "$NEW_NAME" ]; then
                if [ -e "$FINAL_PATH/$NEW_NAME" ]; then
                    # 目标名已存在 = 同名曲目已在库中：删本次新副本（对齐跳过已有语义），
                    # 否则重命名会破坏 yt-dlp 按文件名判重的幂等性
                    rm -f "$f"
                    f="$FINAL_PATH/$NEW_NAME"
                    log "  🔁 Duplicate: exists $NEW_NAME, new copy removed"
                else
                    mv "$f" "$FINAL_PATH/$NEW_NAME"
                    f="$FINAL_PATH/$NEW_NAME"
                    log "  📝 Renamed: $NEW_NAME"
                fi
            fi
        fi
    done
    rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.* 2>/dev/null
    rm -f /tmp/existing_before_$$.txt
    log "🎉 Done: $ALBUM_NAME"
done

# 最后一轮的封面临时目录清理
[ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null

rm -f "$0"
exit 0
LOOPEOF

nohup bash "$WORKER_SH" >> "$LOG_FILE" 2>&1 &
WORKER_PID=$!

echo ""
if is_en; then
    echo "📝 Log: tail -n +1 -f \"$LOG_FILE\""
    echo "🚀 Running in the background..."
else
    echo "📝 日志: tail -n +1 -f \"$LOG_FILE\""
    echo "🚀 切入后台..."
fi
echo "✅ PID: $WORKER_PID"
