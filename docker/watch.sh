#!/usr/bin/env bash
# =============================================================================
# watch.sh  -  auto watch-folder + manual (GUI) job runner, one job at a time.
# Coordinates with the web server through JSON files in $CONFIG_DIR (see lib.sh).
# =============================================================================
set -uo pipefail
source /app/lib.sh
init_state

PROCESSED="$CONFIG_DIR/processed.list"
FAILED="$CONFIG_DIR/failed.list"
IGNORE="$CONFIG_DIR/.startup_ignore"
DONE_DIR="$INPUT_DIR/done"
touch "$PROCESSED" "$FAILED" "$IGNORE" 2>/dev/null || true

# ---- GPU / codec detection (probe a real 1-frame encode) ----
probe_enc()   { ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=256x256:d=0.1 -c:v "$1" -f null - >/dev/null 2>&1; }
probe_vaapi() { ffmpeg -hide_banner -loglevel error -vaapi_device "$(cfg VAAPI_DEVICE)" -f lavfi -i color=c=black:s=256x256:d=0.1 -vf 'format=nv12,hwupload' -c:v "$1" -f null - >/dev/null 2>&1; }
cpu_for_family() { case "${1,,}" in av1) echo libsvtav1;; h264) echo libx264;; *) echo libx265;; esac; }
detect_codec() {
    local fam="${1:-hevc}"
    jlog "AUTO  probing GPU for family '$fam'..."
    if probe_enc "${fam}_nvenc"; then echo "${fam}_nvenc"; return; fi
    if probe_enc "${fam}_qsv";   then echo "${fam}_qsv";   return; fi
    if probe_vaapi "${fam}_vaapi"; then echo "${fam}_vaapi"; return; fi
    cpu_for_family "$fam"
}
RESOLVED=""; RES_FAM=""
apply_codec() {   # sets global CODEC honouring auto + FAMILY, exports it
    local want fam; want="$(cfg CODEC)"; fam="$(cfg FAMILY)"
    if [[ "${want,,}" == "auto" ]]; then
        if [[ -z "$RESOLVED" || "$RES_FAM" != "$fam" ]]; then
            RESOLVED="$(detect_codec "$fam")"; RES_FAM="$fam"; jlog "AUTO  -> $RESOLVED"
        fi
        CODEC="$RESOLVED"
    else CODEC="$want"; fi
    export CODEC
    st_set resolved_codec str "$CODEC"
}

# export effective settings so encode.sh sees GUI overrides via the environment
export_settings() {
    local k v
    for k in OPTIMIZE VMAF_TARGET TOLERANCE INITIAL_CRF MIN_CRF MAX_CRF MANUAL_CRF \
             HEIGHT REMUX OUTPUT_CONTAINER OUTPUT_SUFFIX OUTPUT_SUBDIR SOURCE_ACTION \
             KEEP_LARGER WATCH_INTERVAL FILE_STABLE_SECONDS SCAN_EXISTING \
             INPUT_EXTENSIONS WATCH_ENABLED VAAPI_DEVICE FAMILY; do
        v="$(cfg "$k")"; [[ -n "$v" ]] && export "$k=$v"
    done
}

banner() {
    jlog "==================================================================="
    jlog " GM Encoder (Docker + Web GUI) starting"
    jlog "   input=$INPUT_DIR  output=$OUTPUT_DIR  config=$CONFIG_DIR"
    jlog "   codec=$CODEC  optimize=$(cfg OPTIMIZE)  vmaf=$(cfg VMAF_TARGET)  watch_enabled=$(cfg WATCH_ENABLED)"
    jlog "   ffmpeg=$(ffmpeg -hide_banner -version 2>/dev/null | head -n1)"
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "\b${CODEC}\b" \
        && jlog "   encoder '$CODEC' available: YES" \
        || jlog "   encoder '$CODEC' available: NO (check GPU passthrough)"
    [[ "$CODEC" == *_vaapi && "$(cfg OPTIMIZE)" == "true" ]] && jlog "   WARN VAAPI+search is experimental; use OPTIMIZE=false or QSV/CPU"
    jlog "==================================================================="
}

find_media() {
    local IFS=','; local -a exprs=(); local first=1 ext
    for ext in $(cfg INPUT_EXTENSIONS); do
        ext="${ext// /}"; [[ -z "$ext" ]] && continue
        if [[ $first -eq 1 ]]; then exprs+=( -iname "*.${ext}" ); first=0
        else exprs+=( -o -iname "*.${ext}" ); fi
    done
    find "$INPUT_DIR" -path "$DONE_DIR" -prune -o -type f \( "${exprs[@]}" \) -print 2>/dev/null | sort
}
is_partial() { case "${1,,}" in *.part|*.!qb|*.tmp|*.filepart|*.crdownload|*.uploading) return 0;; *) return 1;; esac; }
is_stable() {
    local f="$1" now mt s1 s2 stable; stable="$(cfg FILE_STABLE_SECONDS)"
    is_partial "$f" && return 1
    now=$(date +%s); mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( now - mt < stable )) && return 1
    s1=$(stat -c %s "$f" 2>/dev/null || echo 0); sleep 2; s2=$(stat -c %s "$f" 2>/dev/null || echo 1)
    [[ "$s1" == "$s2" && "$s1" != "0" ]]
}
already() { grep -qxF "$1" "$2" 2>/dev/null; }
out_dir_for() {
    local f="$1" rel reldir sub; sub="$(cfg OUTPUT_SUBDIR)"
    rel="${f#"$INPUT_DIR"/}"; reldir="$(dirname "$rel")"
    case "$sub" in
        SAME_AS_SRC) [[ "$reldir" == "." ]] && echo "$OUTPUT_DIR" || echo "$OUTPUT_DIR/$reldir" ;;
        "")          echo "$OUTPUT_DIR" ;;
        *)           echo "$OUTPUT_DIR/$sub" ;;
    esac
}
dispose_source() {
    local f="$1"
    case "$(cfg SOURCE_ACTION | tr A-Z a-z)" in
        delete) jlog "SRC   delete"; rm -f "$f" ;;
        move)   mkdir -p "$DONE_DIR"; jlog "SRC   move -> done/"; mv -f "$f" "$DONE_DIR/" 2>/dev/null || true ;;
        keep|*) echo "$f" >> "$PROCESSED" ;;
    esac
}

run_job() {   # $1=file  $2=manual|watch
    local f="$1" src="$2"
    st_set state str "encoding"
    jlog "-------------------------------------------------------------------"
    jlog "ENCODE ($src) $f"
    /app/encode.sh "$f" "$(out_dir_for "$f")"
    local rc=$?
    if stop_requested; then
        jlog "STOP  aborted by user"; clear_stop
        echo "$f" >> "$IGNORE"; st_reset; return
    fi
    case $rc in
        0) [[ "$src" == "watch" ]] && dispose_source "$f" || jlog "SRC   manual: source kept" ;;
        3) echo "$f" >> "$PROCESSED" ;;
        130) echo "$f" >> "$IGNORE" ;;
        *) jlog "FAIL  rc=$rc"; echo "$f" >> "$FAILED" ;;
    esac
    st_reset
}

process_manual_queue() {
    local f tmp
    while ! is_paused; do
        f="$(jq -r '.[0] // empty' "$QUEUE_JSON" 2>/dev/null)"
        [[ -z "$f" ]] && break
        tmp="$(mktemp)"; jq 'del(.[0])' "$QUEUE_JSON" > "$tmp" 2>/dev/null && mv -f "$tmp" "$QUEUE_JSON" || rm -f "$tmp"
        [[ -f "$f" ]] && run_job "$f" manual || jlog "SKIP  manual file gone: $f"
    done
}
process_one() {
    local f="$1"
    already "$f" "$IGNORE" && return 0
    already "$f" "$FAILED" && return 0
    [[ "$(cfg SOURCE_ACTION | tr A-Z a-z)" == "keep" ]] && already "$f" "$PROCESSED" && return 0
    is_stable "$f" && run_job "$f" watch
}

# ---- start ----
apply_codec
banner

first_pass=1
while true; do
    export_settings
    apply_codec
    st_set watch_enabled str "$(cfg WATCH_ENABLED)"

    process_manual_queue

    if [[ "$(cfg WATCH_ENABLED | tr A-Z a-z)" == "true" ]] && ! is_paused; then
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if [[ $first_pass -eq 1 && "$(cfg SCAN_EXISTING | tr A-Z a-z)" != "true" ]]; then
                already "$f" "$IGNORE" || echo "$f" >> "$IGNORE"; continue
            fi
            is_paused && break
            process_one "$f"
        done < <(find_media)
    fi
    first_pass=0

    if is_paused; then st_set state str "paused"; else st_set state str "idle"; fi
    sleep "$(cfg WATCH_INTERVAL)"
done
