#!/usr/bin/env bash
# =============================================================================
# watch.sh  -  poll INPUT_DIR for new media and encode it one at a time.
#
# Polling (not inotify) on purpose: Unraid shares are usually SMB/NFS/FUSE,
# which do NOT deliver reliable inotify events. Polling always works.
# =============================================================================
set -uo pipefail

LOGFILE="${CONFIG_DIR}/gm-encoder.log"
PROCESSED="${CONFIG_DIR}/processed.list"
FAILED="${CONFIG_DIR}/failed.list"
IGNORE="${CONFIG_DIR}/.startup_ignore"
DONE_DIR="${INPUT_DIR}/done"

mkdir -p "$CONFIG_DIR" "$OUTPUT_DIR"
touch "$PROCESSED" "$FAILED" "$IGNORE" 2>/dev/null || true

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') | $*"
    echo "$line"
    echo "$line" >> "$LOGFILE" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# GPU / codec auto-detection.  CODEC=auto -> probe the actual encoder with a
# tiny test frame and pick the first that really works, honouring FAMILY.
# -----------------------------------------------------------------------------
probe_enc() {   # $1 = encoder name -> 0 if a real 1-frame encode succeeds
    ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=256x256:d=0.1 \
        -c:v "$1" -f null - >/dev/null 2>&1
}
probe_vaapi() { # $1 = vaapi encoder
    ffmpeg -hide_banner -loglevel error -vaapi_device "$VAAPI_DEVICE" \
        -f lavfi -i color=c=black:s=256x256:d=0.1 \
        -vf 'format=nv12,hwupload' -c:v "$1" -f null - >/dev/null 2>&1
}
cpu_for_family() {
    case "${FAMILY,,}" in
        av1)  echo libsvtav1 ;;
        h264) echo libx264 ;;
        *)    echo libx265 ;;
    esac
}
resolve_codec() {
    [[ "${CODEC,,}" != "auto" ]] && { echo "$CODEC"; return; }
    local fam="${FAMILY,,}"; [[ -z "$fam" ]] && fam=hevc
    log "AUTO  detecting GPU for family '$fam'..." >&2
    if probe_enc "${fam}_nvenc"; then echo "${fam}_nvenc"; return; fi
    if probe_enc "${fam}_qsv";   then echo "${fam}_qsv";   return; fi
    if probe_vaapi "${fam}_vaapi"; then echo "${fam}_vaapi"; return; fi
    cpu_for_family
}

banner() {
    log "==================================================================="
    log " GM Encoder (Docker) starting"
    log "   input=$INPUT_DIR  output=$OUTPUT_DIR  config=$CONFIG_DIR"
    log "   codec=$CODEC  optimize=$OPTIMIZE  vmaf=$VMAF_TARGET+/-$TOLERANCE"
    log "   crf: init=$INITIAL_CRF min=$MIN_CRF max=$MAX_CRF  height=$HEIGHT"
    log "   source_action=$SOURCE_ACTION  keep_larger=$KEEP_LARGER  remux=$REMUX"
    log "   watch_interval=${WATCH_INTERVAL}s  stable=${FILE_STABLE_SECONDS}s  scan_existing=$SCAN_EXISTING"
    log "   ffmpeg=$(ffmpeg -hide_banner -version 2>/dev/null | head -n1)"
    log "   dynamic-crf=$(command -v dynamic-crf)"
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "\b${CODEC}\b"; then
        log "   encoder '$CODEC' available: YES"
    else
        log "   encoder '$CODEC' available: NO  (falling back may fail - check GPU passthrough)"
    fi
    log "==================================================================="
}

# build a find expression from INPUT_EXTENSIONS (comma-separated)
find_media() {
    local IFS=','
    local -a exprs=()
    local first=1
    for ext in $INPUT_EXTENSIONS; do
        ext="${ext// /}"
        [[ -z "$ext" ]] && continue
        if [[ $first -eq 1 ]]; then exprs+=( -iname "*.${ext}" ); first=0
        else exprs+=( -o -iname "*.${ext}" ); fi
    done
    find "$INPUT_DIR" -path "$DONE_DIR" -prune -o -type f \( "${exprs[@]}" \) -print 2>/dev/null | sort
}

is_partial() {
    case "${1,,}" in
        *.part|*.!qb|*.tmp|*.filepart|*.crdownload|*.uploading) return 0 ;;
        *) return 1 ;;
    esac
}

is_stable() {
    local f="$1" now mt s1 s2
    is_partial "$f" && return 1
    now=$(date +%s); mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( now - mt < FILE_STABLE_SECONDS )) && return 1
    s1=$(stat -c %s "$f" 2>/dev/null || echo 0)
    sleep 2
    s2=$(stat -c %s "$f" 2>/dev/null || echo 1)
    [[ "$s1" == "$s2" && "$s1" != "0" ]]
}

already() { grep -qxF "$1" "$2" 2>/dev/null; }

dispose_source() {
    local f="$1"
    case "${SOURCE_ACTION,,}" in
        delete) log "SRC   delete $f"; rm -f "$f" ;;
        move)   mkdir -p "$DONE_DIR"; log "SRC   move -> done/"; mv -f "$f" "$DONE_DIR/" 2>/dev/null || true ;;
        keep|*) log "SRC   keep source"; echo "$f" >> "$PROCESSED" ;;
    esac
}

process_one() {
    local f="$1"
    already "$f" "$IGNORE"  && return 0
    already "$f" "$FAILED"  && return 0
    [[ "${SOURCE_ACTION,,}" == "keep" ]] && already "$f" "$PROCESSED" && return 0

    log "-------------------------------------------------------------------"
    log "FILE  $f"
    /app/encode.sh "$f" "$(out_dir_for "$f")"
    local rc=$?
    case $rc in
        0) dispose_source "$f" ;;
        3) log "INFO output discarded by size guard; keeping original untouched"
           echo "$f" >> "$PROCESSED" ;;
        *) log "FAIL encode failed (rc=$rc); recording to failed.list (won't retry)"
           echo "$f" >> "$FAILED" ;;
    esac
}

# ---- resolve codec (auto-detect) then start ----
CODEC="$(resolve_codec)"
export CODEC
banner

if [[ "$CODEC" == *_vaapi && "${OPTIMIZE,,}" == "true" ]]; then
    log "WARN  VAAPI + VMAF-search is experimental (dynamic-crf hwupload not wired)."
    log "WARN  If the search fails, set OPTIMIZE=false or use a QSV/CPU codec."
fi

# per-file output directory (honours OUTPUT_SUBDIR / SAME_AS_SRC)
out_dir_for() {
    local f="$1" rel reldir
    rel="${f#"$INPUT_DIR"/}"
    reldir="$(dirname "$rel")"
    case "${OUTPUT_SUBDIR:-}" in
        SAME_AS_SRC) [[ "$reldir" == "." ]] && echo "$OUTPUT_DIR" || echo "$OUTPUT_DIR/$reldir" ;;
        "")          echo "$OUTPUT_DIR" ;;
        *)           echo "$OUTPUT_DIR/$OUTPUT_SUBDIR" ;;
    esac
}

first_pass=1
while true; do
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # on the very first pass, honour SCAN_EXISTING
        if [[ $first_pass -eq 1 && "${SCAN_EXISTING,,}" != "true" ]]; then
            already "$f" "$IGNORE" || echo "$f" >> "$IGNORE"   # skip pre-existing files, always
            continue
        fi
        if is_stable "$f"; then
            process_one "$f"
        fi
    done < <(find_media)
    first_pass=0
    sleep "$WATCH_INTERVAL"
done
