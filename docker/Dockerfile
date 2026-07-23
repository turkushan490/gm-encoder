# =============================================================================
# GM Encoder - Docker / Unraid edition
# VMAF-targeted video encoding via dynamic-crf + ffmpeg, as a watch-folder daemon
#
# Multi-stage:
#   1. builder  - compiles dynamic-crf (Go) with the Linux quality-flag patch
#   2. runtime  - Debian slim + BtbN static ffmpeg (nvenc/qsv/vaapi/libvmaf/x265/svt-av1)
# =============================================================================

# -------- Stage 1: build dynamic-crf --------
FROM golang:1.24-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Pin via build-arg if you want reproducibility; default = upstream main
ARG DCRF_REPO=https://github.com/terranvigil/dynamic-crf.git
ARG DCRF_REF=main
RUN git clone "${DCRF_REPO}" . && git checkout "${DCRF_REF}"

# Apply Linux-specific patches (codec-aware quality flags, duration heuristic)
COPY patch-dcrf.sh /patch-dcrf.sh
RUN sed -i 's/\r$//' /patch-dcrf.sh && bash /patch-dcrf.sh /src

# Static binary, no libc dependency at runtime
RUN CGO_ENABLED=0 GOFLAGS=-mod=mod go build -o /out/dynamic-crf ./cmd/... \
    && /out/dynamic-crf --help >/dev/null 2>&1 || true


# -------- Stage 2: runtime --------
FROM debian:bookworm-slim

# BtbN static ffmpeg (GPL) bundles: libvmaf, libx264, libx265, libsvtav1,
# nvenc (ffnvcodec), vaapi and qsv (libvpl). One tarball, everything included.
# NOTE: use the n7.1 RELEASE build, not master. master needs NVENC API 13.1
# (NVIDIA driver 610+); n7.1 works with the drivers the Unraid Nvidia plugin ships.
ARG FFMPEG_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz

# non-free needed for Intel iHD (newer QSV). mesa-va-drivers covers AMD VAAPI.
# bookworm-slim ships the deb822 debian.sources (with Signed-By), so enable the
# extra components IN that file rather than adding a conflicting second source.
#
# QSV on Intel Arc / Gen12+ (e.g. av1_qsv) needs the oneVPL *GPU runtime*
# (libmfx-gen1.2) on top of the iHD VAAPI driver - without it ffmpeg's libvpl
# dispatcher cannot create an MFX session and fails with "MFX session: -9".
# libvpl2 is the dispatcher; libmfx-gen1.2 is the actual Arc runtime.
RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i 's/^Components: main/Components: main contrib non-free non-free-firmware/' \
            /etc/apt/sources.list.d/debian.sources; \
    else \
        echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" \
            >> /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils tzdata gosu \
        python3 jq procps mediainfo \
        libva2 vainfo va-driver-all mesa-va-drivers intel-media-va-driver-non-free \
        libvpl2 libmfx-gen1.2; \
    rm -rf /var/lib/apt/lists/*

# Install ffmpeg + ffprobe from the static build
RUN set -eux; \
    curl -fsSL "${FFMPEG_URL}" -o /tmp/ffmpeg.tar.xz; \
    mkdir -p /opt/ffmpeg; \
    tar -xf /tmp/ffmpeg.tar.xz -C /opt/ffmpeg --strip-components=1; \
    ln -sf /opt/ffmpeg/bin/ffmpeg  /usr/local/bin/ffmpeg; \
    ln -sf /opt/ffmpeg/bin/ffprobe /usr/local/bin/ffprobe; \
    rm /tmp/ffmpeg.tar.xz; \
    ffmpeg -hide_banner -version; \
    ffmpeg -hide_banner -filters 2>/dev/null | grep -q libvmaf && echo "libvmaf OK"

COPY --from=builder /out/dynamic-crf /usr/local/bin/dynamic-crf
COPY entrypoint.sh watch.sh encode.sh lib.sh server.py /app/
COPY webui /app/webui
RUN sed -i 's/\r$//' /app/*.sh /app/*.py \
    && chmod +x /app/*.sh /app/server.py /usr/local/bin/dynamic-crf \
    && python3 -m py_compile /app/server.py \
    && bash -n /app/watch.sh && bash -n /app/encode.sh && bash -n /app/lib.sh

# ---- Default configuration (all overridable via -e on Unraid) ----
ENV \
    # --- what/where ---
    INPUT_DIR=/input \
    OUTPUT_DIR=/output \
    CONFIG_DIR=/config \
    INPUT_EXTENSIONS="mp4,mkv,mov,avi,m4v,webm,ts,wmv,flv" \
    OUTPUT_CONTAINER=mkv \
    OUTPUT_SUFFIX="_gm" \
    OUTPUT_SUBDIR=SAME_AS_SRC \
    # --- encoder ---
    # CODEC=auto detects the GPU at startup and picks ${FAMILY}_nvenc/_qsv/_vaapi,
    # or a CPU encoder if no usable GPU is passed through.
    CODEC=auto \
    FAMILY=hevc \
    OPTIMIZE=true \
    VMAF_TARGET=93 \
    TOLERANCE=1.5 \
    INITIAL_CRF=22 \
    MIN_CRF=28 \
    MAX_CRF=18 \
    MANUAL_CRF=23 \
    HEIGHT=0 \
    REMUX=true \
    # --- hardware ---
    VAAPI_DEVICE=/dev/dri/renderD128 \
    # --- watch behaviour ---
    WATCH_ENABLED=true \
    WATCH_INTERVAL=15 \
    SCAN_EXISTING=true \
    FILE_STABLE_SECONDS=20 \
    SOURCE_ACTION=move \
    KEEP_LARGER=true \
    MIN_SHRINK_PERCENT=0 \
    # --- wait while GPU is busy (needs nvidia-smi / --runtime=nvidia) ---
    GPU_BUSY_WAIT=false \
    GPU_BUSY_UTIL=40 \
    GPU_BUSY_VRAM=50 \
    # --- web GUI ---
    GUI_PORT=4805 \
    # --- nvidia (only used when started with --runtime=nvidia) ---
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    # --- permissions / system ---
    PUID=99 \
    PGID=100 \
    UMASK=022 \
    TZ=Etc/UTC

EXPOSE 4805
VOLUME ["/input", "/output", "/config"]

ENTRYPOINT ["/app/entrypoint.sh"]
