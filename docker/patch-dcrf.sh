#!/usr/bin/env bash
# =============================================================================
# patch-dcrf.sh  -  Linux build patches for terranvigil/dynamic-crf
#
# On Linux we do NOT need the Windows patches (mkfifo/cambi stub, C:\ path
# escaping) - those problems don't exist here. We only need:
#   1. Codec-aware quality flags   (nvenc -> -cq, qsv -> -global_quality,
#                                    vaapi -> -qp, cpu -> -crf)   [ffmpeg_encode.go]
#   2. Duration heuristic bump     (MKV duration reported in seconds)  [crf_search.go]
#
# Uses the SAME stable needle that the Windows installer patches, so it tracks
# upstream as long as that line exists.
# =============================================================================
set -euo pipefail

REPO="${1:?usage: patch-dcrf.sh <repo-dir>}"
ENC="$REPO/commands/ffmpeg_encode.go"
SEARCH="$REPO/actions/crf_search.go"

echo "[patch] repo = $REPO"

# ---------------------------------------------------------------------------
# 1. Codec-aware quality flags in commands/ffmpeg_encode.go
# ---------------------------------------------------------------------------
if [[ -f "$ENC" ]]; then
    NEEDLE='args = append(args, "-crf", strconv.Itoa(e.cfg.VideoCRF))'
    if grep -qF "$NEEDLE" "$ENC"; then
        perl -0777 -i -pe '
            my $needle = q{args = append(args, "-crf", strconv.Itoa(e.cfg.VideoCRF))};
            my $repl = <<'"'"'GO'"'"';
crfVal := strconv.Itoa(e.cfg.VideoCRF)
			// gm-encoder: codec-aware rate control (Linux hw encoders)
			switch e.cfg.VideoCodec {
			case "hevc_nvenc", "h264_nvenc", "av1_nvenc":
				args = append(args, "-rc", "vbr", "-cq", crfVal, "-b:v", "0")
			case "hevc_qsv", "h264_qsv", "av1_qsv":
				// QSV global_quality (ICQ) is a CRF-like scale (~15-40, lower=
				// better) for ALL codecs incl AV1 - NOT crf*5, which lands off
				// the scale (gq 90-110) and yields ~vmaf 52. Map crf 1:1.
				if d := os.Getenv("VAAPI_DEVICE"); d != "" {
					args = append(args, "-qsv_device", d)
				}
				args = append(args, "-global_quality", crfVal)
			case "hevc_vaapi", "h264_vaapi":
				args = append(args, "-rc_mode", "CQP", "-qp", crfVal)
			case "av1_vaapi":
				args = append(args, "-rc_mode", "CQP", "-qp", strconv.Itoa(e.cfg.VideoCRF*5))
			default:
				args = append(args, "-crf", crfVal)
			}
GO
            chomp $repl;
            s/\Q$needle\E/$repl/;
        ' "$ENC"
        echo "[patch] ffmpeg_encode.go: codec-aware quality flags applied"
    else
        echo "[patch] WARN ffmpeg_encode.go: -crf needle not found (upstream changed?) - skipping"
    fi

    # --- progress forwarding (best-effort; enables a smooth encode bar) ---
    # a) emit machine-readable progress right after -hide_banner
    if grep -q '"-hide_banner"' "$ENC" && ! grep -q '"pipe:1"' "$ENC"; then
        perl -0777 -i -pe 's/"-hide_banner",/"-hide_banner",\n\t\t"-progress", "pipe:1",\n\t\t"-stats_period", "1",/' "$ENC"
        echo "[patch] ffmpeg_encode.go: -progress pipe:1 added"
    fi
    # b) forward ffmpeg stdout (progress) + stderr so encode.sh can read it
    if grep -qF 'cmd.Stderr = &stderr' "$ENC" && ! grep -q 'cmd.Stdout = os.Stdout' "$ENC"; then
        perl -0777 -i -pe 's/cmd\.Stderr = &stderr/cmd.Stderr = io.MultiWriter(&stderr, os.Stderr)\n\tcmd.Stdout = os.Stdout/' "$ENC"
        echo "[patch] ffmpeg_encode.go: stdout/stderr forwarding added"
    fi
    # c) ensure io + os are imported (each only if missing)
    if ! grep -qE '^[[:space:]]*"io"[[:space:]]*$' "$ENC"; then
        perl -0777 -i -pe 's/(\n[ \t]*)"os\/exec"/\1"io"\1"os\/exec"/' "$ENC"
        echo "[patch] ffmpeg_encode.go: io import added"
    fi
    if ! grep -qE '^[[:space:]]*"os"[[:space:]]*$' "$ENC"; then
        perl -0777 -i -pe 's/(\n[ \t]*)"os\/exec"/\1"os"\1"os\/exec"/' "$ENC"
        echo "[patch] ffmpeg_encode.go: os import added"
    fi
else
    echo "[patch] WARN $ENC not found"
fi

# ---------------------------------------------------------------------------
# 2. Duration heuristic in actions/crf_search.go
#    Some MKV containers report duration in seconds via MediaInfo; the upstream
#    'if durationMs < 1000' normalisation then misfires. Bump to 60000.
# ---------------------------------------------------------------------------
if [[ -f "$SEARCH" ]]; then
    if grep -qF 'if durationMs < 1000 {' "$SEARCH"; then
        sed -i 's/if durationMs < 1000 {/if durationMs < 60000 { \/\/ gm-encoder: MKV-in-seconds guard/' "$SEARCH"
        echo "[patch] crf_search.go: duration threshold 1000 -> 60000"
    else
        echo "[patch] crf_search.go: duration needle not found - skipping (non-fatal)"
    fi
else
    echo "[patch] WARN $SEARCH not found"
fi

echo "[patch] done"
