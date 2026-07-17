#!/usr/bin/env bash
# =============================================================================
# encode.sh  -  encode a single file (VMAF-optimized or manual), then remux
#               all audio / subtitle / attachment streams from the original.
#
# Mirrors the Windows Encoder.psm1 Invoke-FileEncode pipeline:
#   symlink -> clean src.mkv (CWD trick) -> dynamic-crf optimize -> post-mux.
#
# Usage:  encode.sh /path/to/input.mkv
# Exit:   0 = ok, 2 = encoder failed, 3 = output larger and KEEP_LARGER=false
# =============================================================================
set -uo pipefail

INPUT="${1:?usage: encode.sh <inputfile> [outdir]}"
OUT_DIR="${2:-$OUTPUT_DIR}"

log() { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ---- resolve output path ----
base="$(basename "$INPUT")"
stem="${base%.*}"
FINAL="${OUT_DIR}/${stem}${OUTPUT_SUFFIX}.${OUTPUT_CONTAINER}"

if [[ -f "$FINAL" ]]; then
    log "SKIP  output already exists: $FINAL"
    exit 0
fi

# ---- temp workspace (dynamic-crf writes intermediates in CWD) ----
tmp="$(mktemp -d "${CONFIG_DIR:-/tmp}/gm.XXXXXX")"
cleanup() { cd / 2>/dev/null; rm -rf "$tmp" 2>/dev/null; }
trap cleanup EXIT

# clean, special-char-free source name in the workspace
if ! ln -s "$(readlink -f "$INPUT")" "$tmp/src.mkv" 2>/dev/null; then
    cp -f "$INPUT" "$tmp/src.mkv" || { log "ERR  cannot stage source"; exit 2; }
fi
cd "$tmp"

# ---- probe ----
size_in=$(stat -c %s "$INPUT" 2>/dev/null || echo 0)
dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 -- "$INPUT" 2>/dev/null || echo 0)
res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name \
        -of csv=p=0:s=x -- "$INPUT" 2>/dev/null || echo '?')
log "INFO  $base | ${res} | $(awk "BEGIN{printf \"%.0f\", ${dur:-0}}")s | $(awk "BEGIN{printf \"%.1f\", ${size_in}/1048576}") MB | codec=$CODEC"

start=$(date +%s)
q="${MANUAL_CRF}"

# =============================================================================
# ENCODE
# =============================================================================
if [[ "${OPTIMIZE,,}" == "true" ]]; then
    # ---- VMAF-targeted search + final encode via dynamic-crf ----
    log "SEARCH dynamic-crf optimize (codec=$CODEC target VMAF=$VMAF_TARGET +/-$TOLERANCE)"
    dcrf_args=(
        -a optimize -i src.mkv -o out.mp4
        -targetvmaf "$VMAF_TARGET" -tolerance "$TOLERANCE"
        -initialcrf "$INITIAL_CRF" -mincrf "$MIN_CRF" -maxcrf "$MAX_CRF"
        -codec "$CODEC"
    )
    [[ "${HEIGHT:-0}" -gt 0 ]] && dcrf_args+=( -h "$HEIGHT" )

    dynamic-crf "${dcrf_args[@]}" 2>&1 | while IFS= read -r line; do log "  dcrf| $line"; done
    rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 || ! -f out.mp4 ]]; then
        log "ERR  dynamic-crf failed (rc=$rc)"
        exit 2
    fi
else
    # ---- manual fixed-quality encode (plain ffmpeg) ----
    log "ENCODE manual q=$q codec=$CODEC"
    vf=()
    pre=()   # args before -i (device init)
    case "$CODEC" in
        *_vaapi)
            pre=( -vaapi_device "$VAAPI_DEVICE" )
            if [[ "${HEIGHT:-0}" -gt 0 ]]; then
                vf=( -vf "format=nv12,hwupload,scale_vaapi=-2:${HEIGHT}" )
            else
                vf=( -vf "format=nv12,hwupload" )
            fi
            ;;
        *)
            [[ "${HEIGHT:-0}" -gt 0 ]] && vf=( -vf "scale=-2:${HEIGHT}:flags=lanczos" )
            ;;
    esac

    case "$CODEC" in
        hevc_nvenc|h264_nvenc)  cargs=( -c:v "$CODEC" -preset p5 -tune hq -rc vbr -cq "$q" -b:v 0 -multipass fullres -spatial_aq 1 ) ;;
        av1_nvenc)              cargs=( -c:v av1_nvenc -preset p6 -rc vbr -cq "$q" -b:v 0 -multipass fullres ) ;;
        hevc_qsv|h264_qsv)      cargs=( -c:v "$CODEC" -global_quality "$q" ) ;;
        av1_qsv)                cargs=( -c:v av1_qsv -global_quality "$((q*5))" ) ;;
        hevc_vaapi|h264_vaapi)  cargs=( -c:v "$CODEC" -rc_mode CQP -qp "$q" ) ;;
        av1_vaapi)              cargs=( -c:v av1_vaapi -rc_mode CQP -qp "$((q*5))" ) ;;
        libsvtav1)              cargs=( -c:v libsvtav1 -preset 6 -crf "$q" ) ;;
        *)                      cargs=( -c:v "$CODEC" -crf "$q" ) ;;
    esac

    pix=( -pix_fmt yuv420p10le )
    [[ "$CODEC" == *_vaapi ]] && pix=()   # vaapi picks its own format via hwupload

    ffmpeg -hide_banner -loglevel error -stats -y \
        "${pre[@]}" -i src.mkv \
        -map 0:v:0 "${vf[@]}" "${pix[@]}" "${cargs[@]}" \
        -an -sn \
        out.mp4 2>&1 | while IFS= read -r line; do log "  ff  | $line"; done
    rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 || ! -f out.mp4 ]]; then
        log "ERR  ffmpeg encode failed (rc=$rc)"
        exit 2
    fi
fi

# =============================================================================
# POST-MUX  (video from out.mp4 + all other streams from the original)
# =============================================================================
mkdir -p "$OUT_DIR"
if [[ "${REMUX,,}" == "true" ]]; then
    log "MUX   remux audio/subs/attachments/chapters from source"
    if ffmpeg -hide_banner -loglevel error -y -fflags +genpts \
        -i out.mp4 -i "$INPUT" \
        -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? -map_chapters 1 \
        -c copy -avoid_negative_ts make_zero -max_interleave_delta 0 \
        -fps_mode passthrough "$FINAL"; then
        :
    else
        log "WARN remux failed, using raw encode as output"
        mv -f out.mp4 "$FINAL"
    fi
else
    mv -f out.mp4 "$FINAL"
fi

[[ -f "$FINAL" ]] || { log "ERR  final output not created"; exit 2; }

# =============================================================================
# SIZE GUARD
# =============================================================================
size_out=$(stat -c %s "$FINAL" 2>/dev/null || echo 0)
elapsed=$(( $(date +%s) - start ))
pct="?"
[[ "$size_in" -gt 0 ]] && pct=$(awk "BEGIN{printf \"%.0f\", ${size_out}*100/${size_in}}")
log "DONE  $(awk "BEGIN{printf \"%.1f\", ${size_in}/1048576}") MB -> $(awk "BEGIN{printf \"%.1f\", ${size_out}/1048576}") MB (${pct}%) in ${elapsed}s"

if [[ "$size_in" -gt 0 && "$size_out" -ge "$size_in" && "${KEEP_LARGER,,}" != "true" ]]; then
    log "WARN output not smaller (${pct}%) and KEEP_LARGER=false -> discarding"
    rm -f "$FINAL"
    exit 3
fi
if [[ "${MIN_SHRINK_PERCENT:-0}" -gt 0 && "$pct" != "?" ]]; then
    if [[ "$pct" -gt $(( 100 - MIN_SHRINK_PERCENT )) ]]; then
        log "WARN shrink ${pct}% below MIN_SHRINK_PERCENT=${MIN_SHRINK_PERCENT}% -> discarding"
        rm -f "$FINAL"
        exit 3
    fi
fi

exit 0
