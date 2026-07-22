#!/usr/bin/env bash
# =============================================================================
# encode.sh  -  encode one file, reporting live progress into status.json.
#
# Usage:  encode.sh <inputfile> [outdir]
# Exit:   0 ok · 2 encoder failed · 3 discarded by size guard · 130 stopped
# Effective settings come from the environment (watch.sh exports them from
# settings.json merged over the image defaults).
# =============================================================================
set -uo pipefail
source /app/lib.sh

INPUT="${1:?usage: encode.sh <inputfile> [outdir]}"
OUT_DIR="${2:-$OUTPUT_DIR}"

base="$(basename "$INPUT")"
stem="${base%.*}"
FINAL="${OUT_DIR}/${stem}${OUTPUT_SUFFIX}.${OUTPUT_CONTAINER}"

if [[ -f "$FINAL" ]]; then jlog "SKIP  output exists: $FINAL"; exit 0; fi

tmp="$(mktemp -d "${CONFIG_DIR:-/tmp}/gm.XXXXXX")"
cleanup() { cd / 2>/dev/null; rm -rf "$tmp" 2>/dev/null; rm -f "$CURRENT_PGID" 2>/dev/null; }
trap cleanup EXIT

ln -s "$(readlink -f "$INPUT")" "$tmp/src.mkv" 2>/dev/null || cp -f "$INPUT" "$tmp/src.mkv" || { jlog "ERR staging failed"; exit 2; }
cd "$tmp"

size_in=$(stat -c %s "$INPUT" 2>/dev/null || echo 0)
dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 -- "$INPUT" 2>/dev/null | head -n1)
[[ "$dur" =~ ^[0-9.]+$ ]] || dur=0
res=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,codec_name -of csv=p=0:s=x -- "$INPUT" 2>/dev/null || echo '?')

start=$(date +%s)
st_set cur_file str "$base"
st_set cur_res  str "$res"
st_set size_in_mb num "$(awk "BEGIN{printf \"%.1f\", ${size_in}/1048576}")"
st_set started  num "$start"
st_set phase    str "Probing"
st_set step     str "reading metadata"
st_set progress num 0
jlog "FILE  $base | $res | $(awk "BEGIN{printf \"%.0f\", ${dur}}")s | $(awk "BEGIN{printf \"%.1f\", ${size_in}/1048576}") MB | codec=$CODEC"

q="${MANUAL_CRF}"; found_crf=0; found_vmaf=0

if [[ "${OPTIMIZE,,}" == "true" ]]; then
    # ---- VMAF search + final encode via dynamic-crf, with live phase bar ----
    # dynamic-crf's normal target+tolerance search (reliable). A tiny tolerance
    # (default 1.5) makes it settle just above the target = smallest file at ~that
    # quality. A wide band trips a dcrf bug that returns crf=0, so keep it narrow.
    dcrf_args=( -a optimize -i src.mkv -o out.mp4
        -targetvmaf "$(cfg VMAF_TARGET)" -tolerance "$(cfg TOLERANCE)"
        -initialcrf "$(cfg INITIAL_CRF)" -mincrf "$(cfg MIN_CRF)" -maxcrf "$(cfg MAX_CRF)"
        -codec "$CODEC" )
    [[ "${HEIGHT:-0}" -gt 0 ]] && dcrf_args+=( -h "$HEIGHT" )
    st_set phase str "Searching"; st_set step str "VMAF target $(cfg VMAF_TARGET)"
    jlog "SEARCH VMAF target $(cfg VMAF_TARGET) +/-$(cfg TOLERANCE), CRF best=$(cfg MAX_CRF)..worst=$(cfg MIN_CRF), codec=$CODEC"

    dynamic-crf "${dcrf_args[@]}" 2>&1 | {
        phase=search; iter=0; base_pct=25; span=30; enc=0; last=0; fcrf=0; fvmaf=0
        while IFS= read -r line; do
            jlog "  dcrf| $line"
            if [[ "$line" =~ crf=([0-9]+) ]];   then fcrf="${BASH_REMATCH[1]}";  echo "$fcrf"  > "$tmp/.crf";  fi
            if [[ "$line" =~ vmaf=([0-9.]+) ]]; then fvmaf="${BASH_REMATCH[1]}"; echo "$fvmaf" > "$tmp/.vmaf"; fi
            case "$line" in
                *"scene detection"*|*"detecting scenes"*)
                    phase=scene; base_pct=2; span=10
                    st_set phase str "Scene detection"; st_set step str "analysing scenes"; st_set progress num 2 ;;
                *"sampler"*|*"extracting scene"*|*"uniform samples"*|*"creating"*"sample"*)
                    if [[ "$phase" != enc ]]; then phase=sample; base_pct=12; span=13
                        st_set phase str "Sampling"; st_set step str "building sample"; st_set progress num 12; fi ;;
                *"iter"*"CRF"*"VMAF"*|*"searching"*)
                    if [[ "$phase" != enc ]]; then phase=search; iter=$((iter+1))
                        base_pct=$(( 25 + (iter*5>27?27:iter*5) )); span=5
                        st_set phase str "Searching"; st_set step str "iteration $iter"; st_set progress num "$base_pct"; fi ;;
            esac
            # final full encode detection
            if [[ "$phase" != enc && "$line" == *"ffmpeg encode"*"src.mkv"* ]]; then
                phase=enc; base_pct=55; span=40
                st_set phase str "Encoding"; st_set step str "final encode CRF=$fcrf"; st_set progress num 55
            fi
            if [[ "$line" == *"running ffmpeg vmaf"* || "$line" == *"measuring"*"vmaf"* ]]; then
                st_set phase str "Verifying"; st_set step str "measuring VMAF"; st_set progress num 95
            fi
            # ffmpeg -progress out_time during final encode -> smooth %
            if [[ "$phase" == enc && "$line" =~ ^out_time_us=([0-9]+) ]]; then
                sec=$(( BASH_REMATCH[1] / 1000000 ))
                if [[ "$(awk "BEGIN{print ($dur>0)}")" == 1 ]]; then
                    p=$(awk "BEGIN{v=55+40*$sec/$dur; if(v>94)v=94; printf \"%d\", v}")
                    if [[ "$p" -gt "$last" ]]; then last="$p"; st_set progress num "$p"
                        st_set step str "encoding ${sec}s / $(awk "BEGIN{printf \"%.0f\",$dur}")s"; fi
                fi
            fi
        done
    }
    rc=${PIPESTATUS[0]}
    found_crf=$(cat "$tmp/.crf" 2>/dev/null || echo 0);  found_crf=${found_crf:-0}
    found_vmaf=$(cat "$tmp/.vmaf" 2>/dev/null || echo 0); found_vmaf=${found_vmaf:-0}
    if [[ $rc -ne 0 || ! -f out.mp4 ]]; then
        stop_requested && { jlog "STOP  cancelled by user"; exit 130; }
        jlog "ERR  dynamic-crf failed (rc=$rc)"; exit 2
    fi
else
    # ---- manual fixed-quality encode ----
    st_set phase str "Encoding"; st_set step str "manual q=$q"
    vf=(); pre=()
    case "$CODEC" in
        *_vaapi) pre=( -vaapi_device "$VAAPI_DEVICE" )
            if [[ "${HEIGHT:-0}" -gt 0 ]]; then vf=( -vf "format=nv12,hwupload,scale_vaapi=-2:${HEIGHT}" )
            else vf=( -vf "format=nv12,hwupload" ); fi ;;
        *) [[ "${HEIGHT:-0}" -gt 0 ]] && vf=( -vf "scale=-2:${HEIGHT}:flags=lanczos" ) ;;
    esac
    case "$CODEC" in
        hevc_nvenc|h264_nvenc)  cargs=( -c:v "$CODEC" -preset p5 -tune hq -rc vbr -cq "$q" -b:v 0 -multipass fullres -spatial_aq 1 ) ;;
        av1_nvenc)              cargs=( -c:v av1_nvenc -preset p6 -rc vbr -cq "$q" -b:v 0 -multipass fullres ) ;;
        hevc_qsv|h264_qsv)      cargs=( -c:v "$CODEC" -qsv_device "$VAAPI_DEVICE" -global_quality "$q" ) ;;
        av1_qsv)                cargs=( -c:v av1_qsv -qsv_device "$VAAPI_DEVICE" -global_quality "$((q*5))" ) ;;
        hevc_vaapi|h264_vaapi)  cargs=( -c:v "$CODEC" -rc_mode CQP -qp "$q" ) ;;
        av1_vaapi)              cargs=( -c:v av1_vaapi -rc_mode CQP -qp "$((q*5))" ) ;;
        libsvtav1)              cargs=( -c:v libsvtav1 -preset 6 -crf "$q" ) ;;
        *)                      cargs=( -c:v "$CODEC" -crf "$q" ) ;;
    esac
    pix=( -pix_fmt yuv420p10le ); [[ "$CODEC" == *_vaapi ]] && pix=()

    ffmpeg -hide_banner -loglevel error -nostats -progress pipe:1 -y \
        "${pre[@]}" -i src.mkv -map 0:v:0 "${vf[@]}" "${pix[@]}" "${cargs[@]}" -an -sn out.mp4 2>&1 | {
        last=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_us=([0-9]+) ]]; then
                sec=$(( BASH_REMATCH[1] / 1000000 ))
                if [[ "$(awk "BEGIN{print ($dur>0)}")" == 1 ]]; then
                    p=$(awk "BEGIN{v=95*$sec/$dur; if(v>95)v=95; printf \"%d\", v}")
                    [[ "$p" -gt "$last" ]] && { last="$p"; st_set progress num "$p"; st_set step str "encoding ${sec}s"; }
                fi
            elif [[ "$line" != *=* ]]; then jlog "  ff  | $line"; fi
        done
    }
    rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 || ! -f out.mp4 ]]; then
        stop_requested && { jlog "STOP  cancelled by user"; exit 130; }
        jlog "ERR  ffmpeg failed (rc=$rc)"; exit 2
    fi
    found_crf="$q"
fi

# ---- post-mux ----
mkdir -p "$OUT_DIR"
st_set phase str "Muxing"; st_set step str "remux original streams"; st_set progress num 96
if [[ "${REMUX,,}" == "true" ]]; then
    if ! ffmpeg -hide_banner -loglevel error -y -fflags +genpts \
        -i out.mp4 -i "$INPUT" -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? -map_chapters 1 \
        -c copy -avoid_negative_ts make_zero -max_interleave_delta 0 -fps_mode passthrough "$FINAL"; then
        jlog "WARN remux failed, using raw encode"; mv -f out.mp4 "$FINAL"
    fi
else
    mv -f out.mp4 "$FINAL"
fi
[[ -f "$FINAL" ]] || { jlog "ERR final output missing"; exit 2; }

# ---- size guard + history ----
size_out=$(stat -c %s "$FINAL" 2>/dev/null || echo 0)
elapsed=$(( $(date +%s) - start ))
pct=$(awk "BEGIN{if($size_in>0)printf \"%d\", ${size_out}*100/${size_in}; else print 0}")
jlog "DONE  $(awk "BEGIN{printf \"%.1f\", ${size_in}/1048576}") MB -> $(awk "BEGIN{printf \"%.1f\", ${size_out}/1048576}") MB (${pct}%) in ${elapsed}s"

if [[ "$size_in" -gt 0 && "$size_out" -ge "$size_in" && "${KEEP_LARGER,,}" != "true" ]]; then
    jlog "WARN not smaller (${pct}%), KEEP_LARGER=false -> discard"; rm -f "$FINAL"
    st_set phase str "Discarded"; exit 3
fi

history_add "$(jq -n \
    --arg f "$base" --arg o "$(basename "$FINAL")" --arg c "$CODEC" \
    --argjson crf "${found_crf:-0}" --argjson vmaf "${found_vmaf:-0}" \
    --argjson si "$(awk "BEGIN{printf \"%.1f\", ${size_in}/1048576}")" \
    --argjson so "$(awk "BEGIN{printf \"%.1f\", ${size_out}/1048576}")" \
    --argjson pct "$pct" --argjson el "$elapsed" --argjson ts "$(date +%s)" \
    '{file:$f,out:$o,codec:$c,crf:$crf,vmaf:$vmaf,size_in:$si,size_out:$so,ratio:$pct,elapsed:$el,ts:$ts,ok:true}')"

st_set phase str "Completed"; st_set step str "${pct}% in ${elapsed}s"; st_set progress num 100
exit 0
