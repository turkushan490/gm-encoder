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

# ---- GPU / codec detection (list-based, like the Windows app) ----
# NOTE: must ONLY echo the codec on stdout (captured by $(...)); log via >&2.
cpu_for_family() { case "${1,,}" in av1) echo libsvtav1;; h264) echo libx264;; *) echo libx265;; esac; }
encoder_listed() { ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE "[[:space:]]${1}[[:space:]]"; }
detect_codec() {
    # auto never picks VAAPI: it can't run through dynamic-crf's search
    # (no hwupload wiring) and doesn't exist on NVIDIA. nvenc -> qsv -> CPU.
    local fam="${1:-hevc}" hw
    for hw in nvenc qsv; do
        if encoder_listed "${fam}_${hw}"; then echo "${fam}_${hw}"; return; fi
    done
    cpu_for_family "$fam"
}
RESOLVED=""; RES_FAM=""
apply_codec() {   # sets global CODEC from Codec(+Family) choice, exports it
    local want fam; want="$(cfg CODEC | tr 'A-Z' 'a-z')"; fam="$(cfg FAMILY | tr 'A-Z' 'a-z')"
    [[ -z "$fam" ]] && fam=hevc
    case "$want" in
        auto)          if [[ -z "$RESOLVED" || "$RES_FAM" != "$fam" ]]; then
                           RESOLVED="$(detect_codec "$fam")"; RES_FAM="$fam"; jlog "AUTO  -> $RESOLVED"
                       fi
                       CODEC="$RESOLVED" ;;
        nvidia|nvenc)  CODEC="${fam}_nvenc" ;;
        intel|qsv)     CODEC="${fam}_qsv" ;;
        amd|vaapi)     CODEC="${fam}_vaapi" ;;
        cpu)           CODEC="$(cpu_for_family "$fam")" ;;
        *)             CODEC="$want" ;;    # explicit encoder id (e.g. hevc_nvenc)
    esac
    export CODEC
    st_set resolved_codec str "$CODEC"
}

# ---- GPU busy check: don't start a GPU encode while the GPU is under load ----
GPU_BUSY_STATE=0
gpu_busy() {
    [[ "$(cfg GPU_BUSY_WAIT | tr 'A-Z' 'a-z')" == "true" ]] || return 1
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    local out util memu memt vpct
    out="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1)"
    [[ -z "$out" ]] && return 1
    util=$(awk -F',' '{gsub(/[^0-9]/,"",$1); print $1+0}' <<<"$out")
    memu=$(awk -F',' '{gsub(/[^0-9]/,"",$2); print $2+0}' <<<"$out")
    memt=$(awk -F',' '{gsub(/[^0-9]/,"",$3); print $3+0}' <<<"$out")
    (( memt == 0 )) && return 1
    vpct=$(( memu * 100 / memt ))
    if (( util >= $(cfg GPU_BUSY_UTIL) )) || (( vpct >= $(cfg GPU_BUSY_VRAM) )); then
        if (( GPU_BUSY_STATE == 0 )); then jlog "GPU busy (util=${util}% vram=${vpct}%) - waiting until free"; GPU_BUSY_STATE=1; fi
        st_set state str "gpu-busy"; return 0
    fi
    (( GPU_BUSY_STATE == 1 )) && { jlog "GPU free again - resuming"; GPU_BUSY_STATE=0; }
    return 1
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
    if encoder_listed "$CODEC"; then jlog "   encoder '$CODEC' available: YES"
    else jlog "   encoder '$CODEC' available: NO (check GPU passthrough)"; fi
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

    # hold off while the GPU is busy (only relevant for hardware encoders)
    if [[ "$CODEC" == *_nvenc || "$CODEC" == *_qsv || "$CODEC" == *_vaapi ]] && gpu_busy; then
        sleep "$(cfg WATCH_INTERVAL)"; continue
    fi

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
