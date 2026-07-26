#!/bin/bash
# ─────────────────────────────────────────────
# musicfeed V3.0.0
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/mf_config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "=================================================="
    echo " ❌ 未找到配置文件: $CONFIG_FILE"
    echo "=================================================="
    echo "📝 首次使用，请先运行配置引导脚本："
    echo " bash mf_setup.sh"
    echo ""
    exit 1
fi

source "$CONFIG_FILE"

: "${MF_LANG:=zh}"
: "${MF_BASE_DIR:=$HOME/navidrome/music}"
: "${MF_YTDLP:=yt-dlp}"
: "${MF_DEFAULT_ARTIST_DIR:=musicfeed}"
: "${MF_AUDIO_FORMAT:=opus}"
: "${MF_PLAYLIST_SLEEP_REQUESTS:=0}"
: "${MF_PLAYLIST_SLEEP_INTERVAL:=0}"
: "${MF_NODE_PATH:=}"

if [ ${#MF_HIDDEN_DIRS[@]} -eq 0 ]; then
    MF_HIDDEN_DIRS=("attachments" "@eaDir" ".DS_Store")
fi

MF_NODE_ARGS=""
if [ -n "$MF_NODE_PATH" ]; then
    MF_NODE_ARGS="--js-runtimes node:$MF_NODE_PATH"
elif command -v node &>/dev/null; then
    MF_NODE_ARGS="--js-runtimes node:$(command -v node)"
fi

CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT

is_en() { [ "$MF_LANG" = "en" ]; }

tr_text() {
    local zh="$1" en="$2"
    if is_en; then printf "%s" "$en"; else printf "%s" "$zh"; fi
}

say() {
    local zh="$1" en="$2"
    tr_text "$zh" "$en"
    printf "\n"
}

ask() {
    local zh="$1" en="$2"
    tr_text "$zh" "$en"
}

echo "=================================================="
echo " 🎵 musicfeed V3.0.0"
echo "=================================================="
say "支持: 专辑 / 播放列表 / YTM电台 / 单曲" "Supports: albums / playlists / YTM radios / singles"
echo "=================================================="

MF_MAX_LINKS_PER_RUN=10
MF_MAX_TRACKS_PER_RUN=150

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

select_artist_folder() {
    local prompt_suffix="$1"
    echo "" >&2
    if is_en; then
        echo "--- 📂 Select artist folder ${prompt_suffix}---" >&2
    else
        echo "--- 📂 请选择歌手文件夹 ${prompt_suffix}---" >&2
    fi

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

    local folders_display=()
    for i in "${!folders[@]}"; do
        if [ "$i" -eq 0 ]; then
            if is_en; then
                folders_display+=("[$((i+1))] ${folders[$i]} (default)")
            else
                folders_display+=("[$((i+1))] ${folders[$i]} （默认）")
            fi
        else
            folders_display+=("[$((i+1))] ${folders[$i]}")
        fi
    done

    display_paged_list "${folders_display[@]}" >&2

    echo "──────────" >&2
    if is_en; then
        echo "[0] Create new artist folder" >&2
    else
        echo "[0] 新建歌手文件夹" >&2; fi
    echo "--------------------" >&2
    if is_en; then
        echo -n "Select number or enter a name (Enter for default[1]): " >&2
    else
        echo -n "请选择编号或直接输入名称 (直接回车默认[1]): " >&2; fi
    read -r CHOICE

    if [ -z "$CHOICE" ]; then
        echo "${folders[0]}"
    elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -gt 0 ] && [ "$CHOICE" -le "${#folders[@]}" ]; then
        echo "${folders[$((CHOICE-1))]}"
    elif [ "$CHOICE" == "0" ]; then
        if is_en; then echo -n "Enter new artist folder name: " >&2
        else echo -n "请输入新歌手文件夹名称: " >&2; fi
        read -r NEW_DIR; echo "$NEW_DIR"
    else
        echo "$CHOICE"; fi
}

input_album_artist() {
    local default_name="$1"
    echo "" >&2
    if is_en; then
        echo "Enter album artist:" >&2
        echo " [Enter] Use default \"$default_name\"" >&2
        echo " [n] Skip (do not write album_artist)" >&2
        echo " [other] Custom input" >&2
        echo -n "Choose: " >&2
    else
        echo "请输入专辑艺术家：" >&2
        echo " [回车] 使用默认值「$default_name」" >&2
        echo " [n] 跳过（不写入 album_artist）" >&2
        echo " [其他] 自定义输入" >&2
        echo -n "请选择: " >&2
    fi
    read -r input
    if [ -z "$input" ]; then
        echo "$default_name"; if is_en; then echo "✅ Album Artist: $default_name (default)" >&2; else echo "✅ Album Artist: $default_name (默认)" >&2; fi
    elif [[ "$input" =~ ^[Nn]$ ]]; then
        echo "SKIP"; if is_en; then echo "⏭️ Skipped Album Artist" >&2; else echo "⏭️ 跳过 Album Artist" >&2; fi
    else
        local safe_input=$(echo "$input" | sed 's/|/｜/g')
        echo "$safe_input"; if is_en; then echo "✅ Album Artist: $safe_input (custom)" >&2; else echo "✅ Album Artist: $safe_input (自定义)" >&2; fi
    fi
}

extract_song_info() {
    local title="$1"
    if [[ "$title" =~ ^(.+)\ -\ (.+)$ ]]; then
        local song_artist="${BASH_REMATCH[1]}"
        local song_name="${BASH_REMATCH[2]}"
        song_name=$(echo "$song_name" | sed 's/\s*\[[^]]*\]//g' | sed 's/\s*(Official[^)]*)//g' | sed 's/\s*(Acoustic[^)]*)//g' | sed 's/\s*(Lyric[^)]*)//g' | sed 's/\s*(Live[^)]*)//g' | sed 's/\s*(Performance[^)]*)//g' | sed 's/\s*(Stripped[^)]*)//g')
        song_name=$(safe_strip "$song_name")
        song_name=$(echo "$song_name" | sed 's/|/｜/g')
        song_artist=$(echo "$song_artist" | sed 's/|/｜/g')
        echo "${song_name}|${song_artist}"; return
    fi
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

input_mv_full() {
    local default_title="$1" default_artist="$2"
    echo "" >&2
    if is_en; then
        echo "--- 🎤 Enter track info ---" >&2
        echo " [Enter]=use default" >&2
        echo -n "Title [${default_title}]: " >&2
    else
        echo "--- 🎤 输入歌曲信息 ---" >&2
        echo " [回车]=使用默认值" >&2
        echo -n "歌名 [${default_title}]: " >&2
    fi
    read -r t < /dev/tty; [ -z "$t" ] && t="$default_title"
    if is_en; then echo -n "Artist [${default_artist}]: " >&2
    else echo -n "歌手 [${default_artist}]: " >&2; fi
    read -r a < /dev/tty; [ -z "$a" ] && a="$default_artist"
    if is_en; then echo -n "Album [${t}]: " >&2
    else echo -n "专辑 [${t}]: " >&2; fi
    read -r al < /dev/tty; [ -z "$al" ] && al="$t"
    t=$(echo "$t" | sed 's/|/｜/g; s/=/＝/g')
    a=$(echo "$a" | sed 's/|/｜/g; s/=/＝/g')
    al=$(echo "$al" | sed 's/|/｜/g; s/=/＝/g')
    echo "${t}|${a}|${al}"
}

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
import json, sys
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
    has_meta = 'True' if (e.get('album') or e.get('artist')) else 'False'
    print(f"{idx}. {title}|{vid}|{has_meta}")
PYEOF
    rm -f "$tmp_json"
}

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

get_link_type() {
    local url="$1"
    [[ "$url" =~ OLAK5uy_ ]] && { echo "album"; return; }
    [[ "$url" =~ RDCLAK5uy_ ]] && { echo "ytm_radio"; return; }
    if [[ "$url" =~ playlist\?list=PL ]] || [[ "$url" =~ playlist\?list=LM ]]; then echo "playlist"; return; fi
    [[ "$url" =~ youtube\.com/playlist ]] && { echo "playlist"; return; }
    [[ "$url" =~ watch\?v= ]] || [[ "$url" =~ youtu\.be/ ]] && { echo "single"; return; }
    echo "unknown"
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

    if [ "$IS_PLAYLIST" == true ]; then
        echo ""
        if is_en; then
            echo "─── 🎬 Playlist Type ───"
            echo "[1] YouTube video playlist (MV mode)"
            echo "[2] YouTube Music user playlist (YTM radio mode)"
        else
            echo "─── 🎬 播放列表类型 ───"
            echo "[1] YouTube 视频播放列表（MV 模式）"
            echo "[2] YouTube Music 用户自建播放列表（YTM 电台模式）"
        fi
        ask "选择 [1/2]: " "Choose [1/2]: "; read -r PL_TYPE
        [ -z "$PL_TYPE" ] && PL_TYPE="1"
        if [ "$PL_TYPE" == "2" ]; then
            IS_PLAYLIST=false
            IS_YTM_RADIO=true
            TYPE="ytm_radio"
            if is_en; then echo "📌 Switched to: YTM radio/mix mode"
            else echo "📌 已切换为: YTM 电台/合集模式"; fi
        else
            if is_en; then echo "📌 Using: MV mode"
            else echo "📌 使用: MV 模式"; fi
        fi
    fi

    ARTIST_DIR=$(select_artist_folder " (《$SAFE_NAME》)")
    ARTIST_PATH="$MF_BASE_DIR/$ARTIST_DIR"; mkdir -p "$ARTIST_PATH"

    if [ "$IS_SINGLE" == true ]; then
        ask "创建子文件夹？[回车=是/n=否]: " "Create a subfolder? [Enter=yes/n=no]: "; read -r SUB_CHOICE
        [[ "$SUB_CHOICE" =~ ^[Nn]$ ]] && FINAL_PATH="$ARTIST_PATH" || { FINAL_PATH="$ARTIST_PATH/$SAFE_NAME"; mkdir -p "$FINAL_PATH"; }
    else
        FINAL_PATH="$ARTIST_PATH/$SAFE_NAME"; mkdir -p "$FINAL_PATH"
    fi

    if is_en; then echo "✅ Path: $FINAL_PATH"; else echo "✅ 路径: $FINAL_PATH"; fi

    ALBUM_ARTIST=""; ENHANCED_MODE=false
    if [ "$IS_ALBUM" == true ]; then
        AA_RESULT=$(input_album_artist "$ARTIST_DIR")
        [ "$AA_RESULT" != "SKIP" ] && ALBUM_ARTIST="$AA_RESULT"
        echo ""
        if is_en; then echo "[1] Unified cover [2] Per-track covers"; else echo "[1] 统一封面 [2] 独立封面"; fi
        ask "选择 [1/2]: " "Choose [1/2]: "; read -r MC
        [ "$MC" == "2" ] && ENHANCED_MODE=true
    elif [ "$IS_SINGLE" == true ]; then
        ENHANCED_MODE=true
    else
        ENHANCED_MODE=true
        [ "$IS_YTM_RADIO" == true ] && say "📌 YTM电台：自动使用独立封面模式" "📌 YTM radio: using per-track cover mode automatically"
    fi

    if [ "$TRACK_COUNT" -eq 1 ]; then
        SELECTION="ALL"; SELECTED_COUNT=1
    else
        echo ""
        songs_display=()
        while IFS= read -r line; do
            songs_display+=("$line")
        done <<< "$SONG_LIST"
        display_paged_list "${songs_display[@]}"
        echo ""

        if [ "$TRACK_COUNT" -gt 50 ]; then
            if is_en; then echo "💡 $TRACK_COUNT tracks total. Consider downloading in batches, e.g. 1-50, 51-100."
            else echo "💡 共 $TRACK_COUNT 首，建议分批下载（如 1-50, 51-100）"; fi
        fi

        while true; do
            ask "曲目编号 [回车=全部，支持 1,3,5 或 1-5]: " "Track numbers [Enter=all, supports 1,3,5 or 1-5]: "; read -r TI
            if [ -z "$TI" ]; then SELECTION="ALL"; SELECTED_COUNT=$TRACK_COUNT; break; fi
            P=$(parse_track_selection "$TI" "$TRACK_COUNT")
            [[ "$P" == INVALID:* ]] && { say "⚠️ 错误" "⚠️ Invalid selection"; continue; }
            SELECTION="$P"; SELECTED_COUNT=$(echo "$SELECTION" | tr ',' '\n' | wc -l); break
        done
    fi

    if is_en; then echo "✅ Will download $SELECTED_COUNT track(s)"; else echo "✅ 将下载 $SELECTED_COUNT 首"; fi

    if [ "$IS_SINGLE" == true ] && [ "$HAS_METADATA" != "True" ]; then
        echo ""
        say "⚠️ MV 单曲" "⚠️ MV single"
        SI=$(extract_song_info "$SINGLE_TITLE"); ST=$(echo "$SI" | cut -d'|' -f1); SA=$(echo "$SI" | cut -d'|' -f2)
        [ -z "$SA" ] && SA="$ARTIST_DIR"
        if is_en; then
            echo "[1] Manually enter title/artist/album (album defaults to title)"
            echo "[2] Use defaults (artist=uploader, title=title, album=title)"
        else
            echo "[1] 手动输入歌名/歌手/专辑（专辑默认=歌名）"
            echo "[2] 使用默认值（歌手=uploader，歌名=title，专辑=title）"
        fi
        ask "选择 [1/2]: " "Choose [1/2]: "; read -r MS
        [ -z "$MS" ] && MS="1"
        if [ "$MS" == "1" ]; then
            MV_STRATEGY="1"
            MV_INPUT=$(input_mv_full "$ST" "$SA")
            MV_TITLE=$(echo "$MV_INPUT" | cut -d'|' -f1)
            MV_ARTIST=$(echo "$MV_INPUT" | cut -d'|' -f2)
            MV_ALBUM=$(echo "$MV_INPUT" | cut -d'|' -f3)
        else
            MV_STRATEGY="2"
            MV_TITLE="$SINGLE_TITLE"; MV_ARTIST="$SINGLE_UPLOADER"; MV_ALBUM="$SINGLE_TITLE"
        fi
    fi

    if [ "$IS_PLAYLIST" == true ]; then
        if [ "$SELECTION" = "ALL" ]; then
            SEL_ITEMS=""
            for ((inum=1; inum<=TRACK_COUNT; inum++)); do
                SEL_ITEMS="${SEL_ITEMS}${SEL_ITEMS:+ }$inum"
            done
        else
            SEL_ITEMS=$(echo "$SELECTION" | tr ',' ' ')
        fi

        NORMAL_LIST=""; MV_LIST=""
        for inum in $SEL_ITEMS; do
            L=$(echo "$SONG_LIST_FULL" | sed -n "${inum}p")
            [ -z "$L" ] && continue
            VID=$(echo "$L" | awk -F'|' '{print $(NF-1)}')
            HAS=$(echo "$L" | awk -F'|' '{print $NF}')
            if [ "$HAS" != "True" ]; then
                MV_LIST="$MV_LIST $VID"
            else
                NORMAL_LIST="${NORMAL_LIST}${NORMAL_LIST:+,}$inum"
            fi
        done

        NORMAL_SELECTION="$NORMAL_LIST"
        MV_VIDS=$(echo "$MV_LIST" | xargs)

        if [ -n "$MV_LIST" ]; then
            echo ""
            if is_en; then
                echo "[1] Manually enter title/artist/album (album defaults to title)"
                echo "[2] Use defaults (artist=uploader, title=title, album=title)"
            else
                echo "[1] 手动输入歌名/歌手/专辑（专辑默认=歌名）"
                echo "[2] 使用默认值（歌手=uploader，歌名=title，专辑=title）"
            fi
            ask "选择 [1/2]: " "Choose [1/2]: "; read -r MS
            [ -z "$MS" ] && MS="1"
            if [ "$MS" == "1" ]; then
                MV_STRATEGY="1"
                echo ""
                if is_en; then echo "--- 🎬 Confirm each MV track ---"; else echo "--- 🎬 逐首确认 ---"; fi
                MV_INFO=""
                while IFS= read -r VID; do
                    [ -z "$VID" ] && continue
                    LINE=$(echo "$SONG_LIST_FULL" | grep -F -- "|$VID|")
                    [ -z "$LINE" ] && continue
                    INUM=$(echo "$LINE" | sed 's/^\([0-9]*\)\. .*/\1/')
                    RAW_TITLE=$(echo "$LINE" | sed 's/^[0-9]*\. //; s/|[^|]*|[^|]*$//')
                    SI=$(extract_song_info "$RAW_TITLE"); ST=$(echo "$SI" | cut -d'|' -f1); SA=$(echo "$SI" | cut -d'|' -f2)
                    [ -z "$SA" ] && SA="$ARTIST_DIR"
                    echo "" >&2
                    if is_en; then echo "━━━━ Track ${INUM}: ${RAW_TITLE:0:60}..." >&2
                    else echo "━━━━ 第 ${INUM} 首: ${RAW_TITLE:0:60}..." >&2; fi
                    NAME_INPUT=$(input_mv_full "$ST" "$SA")
                    TITLE=$(echo "$NAME_INPUT" | cut -d'|' -f1)
                    ARTIST=$(echo "$NAME_INPUT" | cut -d'|' -f2)
                    ALBUM=$(echo "$NAME_INPUT" | cut -d'|' -f3)
                    [ -n "$MV_INFO" ] && MV_INFO="${MV_INFO};"
                    MV_INFO="${MV_INFO}${VID}=${TITLE}=${ARTIST}=${ALBUM}"
                done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
            else
                MV_STRATEGY="2"
                NORMAL_SELECTION="$SELECTION"; MV_VIDS=""; MV_INFO=""
            fi
        fi

        if [ -n "$NORMAL_SELECTION" ]; then
            SELECTION="$NORMAL_SELECTION";
        else
            SELECTION="";
        fi
    fi

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

SLEEP_REQUESTS="__SLEEP_REQUESTS__"
SLEEP_INTERVAL="__SLEEP_INTERVAL__"

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
import sys, os
fpath = sys.argv[1]; title = sys.argv[2]; artist = sys.argv[3]
album = sys.argv[4]; album_artist = sys.argv[5]; cover_file = sys.argv[6] if len(sys.argv) > 6 else ""
if fpath.endswith('.m4a'):
    from mutagen.mp4 import MP4, MP4Cover
    audio = MP4(fpath)
    audio['\xa9nam'] = [title]
    audio['\xa9ART'] = [artist]
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
else:
    from mutagen.oggopus import OggOpus
    audio = OggOpus(fpath)
    audio['title'] = [title]
    audio['artist'] = [artist]
    if album: audio['album'] = [album]
    elif 'album' in audio: del audio['album']
    if album_artist: audio['album_artist'] = [album_artist]
    elif 'album_artist' in audio: del audio['album_artist']
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
import sys, os, base64
fpath = sys.argv[1]; aa = sys.argv[2]; an = sys.argv[3]
hc = sys.argv[4]; em = sys.argv[5]; oa = sys.argv[6]; cf = sys.argv[7] if len(sys.argv) > 7 else ""
try:
    if fpath.endswith('.m4a'):
        from mutagen.mp4 import MP4, MP4Cover
        audio = MP4(fpath)
        if aa and aa not in ('None','SKIP',''): audio['aART'] = [aa]
        elif 'aART' in audio: del audio['aART']
        if em=='true' and oa and oa!='None' and not oa.startswith('%'): audio['\xa9alb'] = [oa]
        else: audio['\xa9alb'] = [an]
        if em=='true' and 'trkn' in audio: del audio['trkn']
        if hc=='true' and cf and os.path.exists(cf):
            with open(cf,'rb') as img: audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
            print(f'  ✅ +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ✅ ID3: {os.path.basename(fpath)}')
    else:
        from mutagen.oggopus import OggOpus
        from mutagen.flac import Picture
        audio = OggOpus(fpath)
        if aa and aa not in ('None','SKIP',''): audio['album_artist'] = [aa]
        elif 'album_artist' in audio: del audio['album_artist']
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
replace_token "__SLEEP_REQUESTS__" "$MF_PLAYLIST_SLEEP_REQUESTS"
replace_token "__SLEEP_INTERVAL__" "$MF_PLAYLIST_SLEEP_INTERVAL"

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

    SLEEP_ARGS=""
    { [ "$TYPE" = "playlist" ] || [ "$TYPE" = "ytm_radio" ]; } && [ "$SLEEP_INTERVAL" -gt 0 ] && SLEEP_ARGS="--sleep-requests $SLEEP_REQUESTS --sleep-interval $SLEEP_INTERVAL"

    if [ "$ENHANCED_MODE" != "true" ]; then
        log "🖼️ Unified cover..."
        CTD=$(mktemp -d)
        "$YTDLP" $NODE_ARGS --no-warnings --write-thumbnail --skip-download --convert-thumbnails jpg \
            --playlist-items 1 -o "$CTD/%(id)s" "$url" >> "$LOG_FILE" 2>&1
        CS=$(find "$CTD" -name "*.jpg" -type f -exec ls -la {} \; 2>/dev/null | sort -k5 -rn | head -1 | awk '{print $NF}')
        if [ -n "$CS" ]; then
            cp "$CS" "$FINAL_PATH/cover.jpg"
            cover_compress "$FINAL_PATH/cover.jpg" "$FINAL_PATH/cover_tmp.jpg" 2>/dev/null
            if [ -f "$FINAL_PATH/cover_tmp.jpg" ]; then
                mv "$FINAL_PATH/cover_tmp.jpg" "$FINAL_PATH/cover.jpg"
                log "✅ Unified cover (compressed)"
            else
                log "✅ Unified cover (compression failed, keeping original)"
            fi
        else
            log "⚠️ Could not fetch unified cover"
        fi
        rm -rf "$CTD"
    fi

    MV_DATA=()
    parse_mv_info "$MV_INFO"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "🚚 MV single (temp)..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --write-info-json \
            "${FORMAT_ARGS[@]}" \
            -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    elif [ "$MV_STRATEGY" = "2" ]; then
        log "🚚 Default mode batch..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
            --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json $SLEEP_ARGS \
            "${FORMAT_ARGS[@]}" \
            --playlist-items "$SELECTION" \
            -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    else
        if [ -n "$NORMAL_SELECTION" ]; then
            log "🚚 Normal track batch..."
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json $SLEEP_ARGS \
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
                    --embed-metadata --no-embed-thumbnail --windows-filenames --write-info-json \
                    "${FORMAT_ARGS[@]}" \
                    -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$SINGLE_URL" >> "$LOG_FILE" 2>&1
            done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
        fi

        if [ -z "$NORMAL_SELECTION" ] && [ -z "$MV_VIDS" ]; then
            log "🚚 Downloading..."
            DOWNLOAD_ARGS=""
            [ "$SELECTION" != "ALL" ] && [ -n "$SELECTION" ] && DOWNLOAD_ARGS="--playlist-items $SELECTION"
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json $SLEEP_ARGS \
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
            TITLE=""; SA=""; REAL_ALBUM=""; HS=false
            if [ -f "$JSON_FILE" ]; then
                TITLE=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                REAL_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                [ -n "$TITLE" ] && [ -n "$SA" ] && HS=true
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
            embed_cover "$f" "" "$ALBUM_NAME" "$([ -n "$CF" ] && echo true || echo false)" "true" "$FINAL_ALBUM" "$CF" >> "$LOG_FILE" 2>&1
            [ -n "$CF" ] && rm -f "$CF"
            echo "$f" >> /tmp/existing_before_$$.txt
        done
        rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm 2>/dev/null
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
                    SA_META=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
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
        ORIG_ALBUM=""; CF=""; HC="false"
        if [ "$ENHANCED_MODE" = "true" ]; then
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            if [ -f "$JSON_FILE" ]; then
                ORIG_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                HS=false
                [ -n "$ORIG_ALBUM" ] && [ -n "$SA" ] && HS=true
                log "  📀 Metadata: $HS"
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
            if [ -f "$FINAL_PATH/cover.jpg" ] && [ "$(file_size "$FINAL_PATH/cover.jpg" 2>/dev/null)" -gt 10240 ]; then
                CF="$FINAL_PATH/cover.jpg"
                HC="true"
                log "  🖼️ Using unified cover"
            fi
        fi
        embed_cover "$f" "$ALBUM_ARTIST" "$ALBUM_NAME" "$HC" "$ENHANCED_MODE" "$ORIG_ALBUM" "$CF" >> "$LOG_FILE" 2>&1
        [ -n "$CF" ] && [ "$CF" != "$FINAL_PATH/cover.jpg" ] && rm -f "$CF"
    done
    rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm 2>/dev/null
    rm -f /tmp/existing_before_$$.txt
    log "🎉 Done: $ALBUM_NAME"
done

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
