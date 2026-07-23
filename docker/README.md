# GM Encoder — Docker / Unraid edition

A watch-folder **and** web-GUI version of GM Encoder for servers. Drop a video into
the input share (or pick it in the browser) → it finds the optimal CRF for your VMAF
target → encodes → remuxes all original audio/subtitle/attachment/chapter streams →
writes to the output share.

**Web control panel** at `http://<server-ip>:4805` — live progress bar, CPU/GPU
meters, current queue, recent completed, a full settings editor (applies live, no
restart) and manual "encode this file now" + Pause/Stop. The watch-folder keeps
running alongside it.

> **Why a separate build?** The Windows app is a WPF GUI and cannot run in a Linux
> container. This edition reuses the *engine* — [`dynamic-crf`](https://github.com/terranvigil/dynamic-crf)
> + `ffmpeg`/`libvmaf` — with a watch-folder daemon instead of a window. The
> Windows-only patches (mkfifo/cambi, `C:\` path escaping) aren't needed on Linux;
> only the codec-aware quality-flag patch and the MKV duration guard are applied.

---

## What's in the box

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage: builds `dynamic-crf` (Go), runtime = Debian + BtbN static ffmpeg (nvenc/qsv/vaapi/libvmaf/x265/svt-av1) + python3/jq |
| `patch-dcrf.sh` | Linux source patches for `dynamic-crf` (codec flags, duration, progress forwarding) |
| `watch.sh` | Poll loop (SMB/NFS-safe) — runs auto + manual jobs, one at a time |
| `encode.sh` | Single-file encode + live progress + post-mux + size guard |
| `lib.sh` | Shared JSON state contract (settings/status/queue/runtime) |
| `server.py` | Web control panel (stdlib http server, no pip deps) |
| `webui/index.html` | Dashboard UI (settings, live progress, queue, manual encode, pause/stop) |
| `entrypoint.sh` | PUID/PGID, `/dev/dri` access, launches web server + watch loop |
| `../templates/gm-encoder.xml` | Unraid template (import to get all fields pre-filled) |
| `docker-compose.yml` | Local / non-Unraid testing |

## Web control panel

Open `http://<server-ip>:4805`:

- **Now encoding** — current file, phase (scene detect → sample → search → encode →
  mux), a smooth progress bar, plus **CPU** and **GPU** meters.
- **Input files** — browse `/input`, click **Encode** to run one manually now.
- **Manual queue** — pending manual jobs (+ Clear).
- **Settings** — every option as a form; **Save** applies to the next job with no
  container restart (stored in `/config/settings.json`, overrides the template env).
- **Pause** (finish current, hold new) / **Resume** / **Stop current** (kills the encode).
- **Recent completed** — codec, CRF, VMAF, size ratio, time.
- Toggle **Auto watch-folder** off if you want GUI-only (manual) operation.

---

## Quick start (any Docker host)

```bash
cd docker
docker compose up -d --build      # builds locally, starts the watcher
# drop a file:
cp ~/movie.mkv ./input/
docker compose logs -f            # watch it work
# result appears in ./output/movie_gm.mkv
```

---

## Unraid setup

First **publish the image** once so Unraid can pull it (see
[Publishing the image](#publishing-the-image)). Then add it one of three ways.

### A. Get it into Community Applications (the "Apps" tab)

Unraid can't read a **private** GitHub repo, so make `gm-encoder` **public** first
(GitHub → repo → Settings → General → Change visibility). Then:

**A1 — Add your template repo (shows under "User templates"):**
1. **Docker** tab → **Add Container**.
2. Scroll to **Template repositories** at the bottom.
3. Paste `https://github.com/turkushan490/gm-encoder` on a new line → **Save**.
4. Now the **Template** dropdown at the top has **GM-Encoder** under your repo. Pick it,
   set your shares, **Apply**. (Unraid reads `templates/gm-encoder.xml` automatically.)

**A2 — Drop the file on the flash drive (no repo needed):**
1. From a PC: open `\\TOWER\flash\config\plugins\dockerMan\templates-user\`
   (or on the server: `/boot/config/plugins/dockerMan/templates-user/`).
2. Copy `templates/gm-encoder.xml` there, rename it `my-GM-Encoder.xml`.
3. **Docker → Add Container → Template → User templates → GM-Encoder**.

**A3 — List it in the public Apps search (optional):** to make it findable by everyone
in the **Apps** tab, submit the template to the CA feed — see the forum guide
[How To Publish Docker Templates to Community Applications](https://forums.unraid.net/topic/101424-how-to-publish-docker-templates-to-community-applications-on-unraid/).
For personal use you don't need this; A1/A2 are enough.

> The template's **dropdowns** (Codec, Family, Optimize, After-success, container, …)
> come from `Default="a|b|c"` values — Unraid renders those as selectors automatically.

### B. Add Container manually

**Docker → Add Container**, then:

| Field | Value |
|---|---|
| Repository | `ghcr.io/turkushan490/gm-encoder:latest` |
| Network Type | `None` (no ports needed) |
| Path: `/input` | e.g. `/mnt/user/media/encode_in` |
| Path: `/output` | e.g. `/mnt/user/media/encode_out` |
| Path: `/config` | `/mnt/user/appdata/gm-encoder` |
| Variable: `CODEC` | see the GPU section below |
| Variable: `PUID` / `PGID` | `99` / `100` (Unraid default) |
| Variable: `TZ` | `Europe/Amsterdam` |

Then add the GPU bits for your server ↓

---

## GPU setup — two things to set

There are **two independent choices**:

1. **The `CODEC` dropdown** = which encoder to use. Leave it on **`auto`** and the
   container probes the GPU you passed in and picks `${FAMILY}_nvenc / _qsv / _vaapi`
   (or a CPU encoder if none works). Or pick an explicit codec.
2. **Extra Parameters** = which GPU the container can actually *see*. The dropdown
   can't do this — Docker needs the device/runtime flag.

Pair them like this:

| Your server GPU | Extra Parameters | Codec dropdown |
|---|---|---|
| **NVIDIA** (your box) | `--runtime=nvidia --device /dev/dri:/dev/dri/` | `auto` (→ `hevc_nvenc`) or pick `hevc_nvenc` / `av1_nvenc` |
| **Intel iGPU (QSV)** | `--device /dev/dri:/dev/dri/` | `auto` (→ `hevc_qsv`) or `hevc_qsv` |
| **AMD / Intel (VAAPI)** | `--device /dev/dri:/dev/dri/` | `hevc_vaapi` (see caveat) |
| **CPU only** | *(empty)* | `libx265` / `libsvtav1` |

### NVIDIA (your setup) — the exact fields

This mirrors your `zocker160/handbrake-nvenc` container, so it's the proven path:

- Requires the **Nvidia-Driver** plugin (Community Apps) — you already have it.
- **Extra Parameters:** `--runtime=nvidia --device /dev/dri:/dev/dri/`  ← already the template default
- **`NVIDIA_VISIBLE_DEVICES`:** your GPU UUID (e.g. `GPU-143db18f-03da-3cc6-70f8-6582715983f0`) or `all`
- **`NVIDIA_DRIVER_CAPABILITIES`:** `all`
- **Codec:** `auto` (picks `hevc_nvenc`) — or `av1_nvenc` (RTX 40-series+).

To verify it's really using the GPU after start:
`docker exec gm-encoder ffmpeg -hide_banner -f lavfi -i color=black:s=256x256:d=1 -c:v hevc_nvenc -f null -`
— exit 0 = NVENC works.

### ⚠️ AMD VAAPI caveat

Fixed-quality (`OPTIMIZE=false`) works. The VMAF **search** (`OPTIMIZE=true`) through
`dynamic-crf` still needs the hwupload filter wired into the Go tool — that's stage 2.
Since your server is NVIDIA this won't affect you; VAAPI users should run
`OPTIMIZE=false` for now (or use CPU for search).

---

## Configuration (all env vars)

| Variable | Default | Notes |
|---|---|---|
| `CODEC` | `auto` | `auto` detects GPU; or an explicit encoder id (see GPU section) |
| `FAMILY` | `hevc` | which family `auto` targets: `hevc` / `av1` / `h264` |
| `OUTPUT_SUBDIR` | `SAME_AS_SRC` | mirror input tree · empty = flat · or a fixed folder |
| `OPTIMIZE` | `true` | `true`=VMAF search, `false`=fixed `MANUAL_CRF` |
| `VMAF_TARGET` | `93` | 95 archival · 93 high · 90 smaller |
| `TOLERANCE` | `1.5` | ± band around target |
| `INITIAL_CRF` / `MIN_CRF` / `MAX_CRF` | `22`/`28`/`18` | search bounds (min=worst, max=best) |
| `MANUAL_CRF` | `23` | used when `OPTIMIZE=false` |
| `HEIGHT` | `0` | `0`=source, else downscale (e.g. `1080`) |
| `REMUX` | `true` | keep all original audio/subs/attachments/chapters |
| `OUTPUT_CONTAINER` | `mkv` | `mkv` or `mp4` |
| `OUTPUT_SUFFIX` | `_gm` | filename suffix |
| `SOURCE_ACTION` | `move` | `keep` · `move`→`input/done` · `delete` |
| `KEEP_LARGER` | `true` | `false`=discard result if not smaller |
| `MIN_SHRINK_PERCENT` | `0` | e.g. `10` = discard unless ≥10% smaller |
| `WATCH_INTERVAL` | `15` | poll seconds |
| `FILE_STABLE_SECONDS` | `20` | wait after last write (avoids partial copies) |
| `SCAN_EXISTING` | `true` | process files already present at start |
| `INPUT_EXTENSIONS` | `mp4,mkv,mov,avi,m4v,webm,ts,wmv,flv` | watched types |
| `VAAPI_DEVICE` | `/dev/dri/renderD128` | for `*_vaapi` only |
| `PUID`/`PGID`/`UMASK`/`TZ` | `99`/`100`/`022`/`Etc/UTC` | Unraid file ownership |

**State files** (in `/config`): `gm-encoder.log`, `processed.list`, `failed.list`.
A failed file is recorded so it won't retry forever — delete its line from
`failed.list` to try again.

---

## Publishing the image

The included GitHub Action (`.github/workflows/docker-image.yml`) builds and pushes
to **GHCR** on every push to `main` (or tag). After the first run, make the package
public: GitHub → your profile → Packages → `gm-encoder` → Package settings → Change
visibility → Public. Then Unraid can pull `ghcr.io/turkushan490/gm-encoder:latest`
with no login.

Prefer to build on the box instead? `docker build -t gm-encoder ./docker` on any
machine with Docker, then push to your own registry.

---

## Intel Arc / QSV / VAAPI — pass /dev/dri as a DEVICE, not a Path

The image bundles the Intel **oneVPL GPU runtime** (`libmfx-gen`) so `*_qsv`
(incl. `av1_qsv`) works on Arc / Gen12+, and the iHD + mesa VAAPI drivers for
`*_vaapi`. The startup log prints `QSV runtime OK` when the runtime is found.

The #1 cause of `Error creating a MFX session: -9`, `No VA display found`, or
`Device creation failed: -22` is mapping `/dev/dri` as an Unraid **Path/volume**.
That makes the device *visible* but Docker does **not** grant device access
(`docker inspect ... .HostConfig.Devices` shows `[]`).

**Fix:** remove any `/dev/dri` Path mapping and instead add to **Extra Parameters**:

```
--device=/dev/dri
```

Then set the driver if needed: **Variable** `LIBVA_DRIVER_NAME` = `iHD` (Intel Arc /
recent iGPU) or `radeonsi` (AMD). The container auto-detects the render node
(e.g. Arc is usually `renderD129`, not `renderD128`) — check the startup log for
`GPU device OK: /dev/dri/renderDxxx`. If you instead see
`GPU node ... is visible but NOT usable`, you're still on a Path mapping.

## Troubleshooting

- **`encoder 'hevc_qsv' available: NO`** in the log → GPU not passed through. Check
  `--device=/dev/dri` (QSV/VAAPI) or the Nvidia runtime (NVENC).
- **Output owned by root** → set `PUID=99 PGID=100`.
- **File encoded while still copying** → raise `FILE_STABLE_SECONDS`.
- **Verify hardware inside the container:**
  `docker exec gm-encoder vainfo` (QSV/VAAPI) or
  `docker exec gm-encoder ffmpeg -hide_banner -encoders | grep -E 'nvenc|qsv|vaapi'`.
