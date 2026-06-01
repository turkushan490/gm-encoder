# dynamic-crf — CLI Cheatsheet

Tool voor het vinden van de optimale CRF waarde door te targeten op VMAF score. Convergeert in 3–5 encodes ipv brute force.

> [!info] Setup
> Installer heeft `dynamic-crf.exe` en `run.bat` aangemaakt in de installmap. Gebruik altijd `run.bat` — die zet automatisch alle PATHs goed (ffmpeg, mediainfo, go, git).

---

## Quick start

```powershell
# Open CMD/PowerShell in de installatiemap, dan:
run.bat -a search -i video.mp4
```

Of vanuit een andere map met volledig pad:

```powershell
"C:\ai code\asa\run.bat" -a search -i "C:\path\to\video.mp4"
```

---

## Acties (`-a`)

| Actie      | Wat doet het                                                              | `-o` nodig |
| ---------- | ------------------------------------------------------------------------- | ---------- |
| `search`   | Vind optimale CRF voor target VMAF, **geen** encode                       | nee        |
| `optimize` | Zoek CRF + encode hele video + VMAF score van resultaat                   | ja         |
| `encode`   | Encode met specifieke CRF/bitrate, geef VMAF score                        | ja         |
| `inspect`  | Schrijf metadata van source als JSON naar `{file}_inspect.json`           | nee        |
| `vmaf`     | Bereken VMAF tussen source (reference) en encode (distorted)              | ja         |
| `cambi`    | Bereken CAMBI banding-artifact score (gradients, lucht, dark scenes)      | ja         |

---

## Veelgebruikte commando's

### Zoeken naar optimale CRF (geen encode)

```powershell
run.bat -a search -i video.mp4
run.bat -a search -i video.mp4 -targetvmaf 93
run.bat -a search -i video.mp4 -targetvmaf 95 -h 1080
run.bat -a search -i video.mp4 -targetvmaf 93 -h 720 -t animation
```

Output:
```
Found crf: 18, vmaf: 95.12
```

### Volledige optimize (zoek + encode + score)

```powershell
# 1080p met VMAF 93 target en bitrate cap
run.bat -a optimize -i source.mp4 -o out.mp4 -h 1080 -mb 12000 -bs 48000

# 720p anime tuned
run.bat -a optimize -i anime.mkv -o out.mp4 -h 720 -t animation -targetvmaf 95

# 4K archival met x265
run.bat -a optimize -i source.mkv -o out.mp4 -h 2160 -codec libx265 -targetvmaf 95
```

### Encode met bekende CRF

```powershell
run.bat -a encode -i source.mp4 -o out.mp4 -crf 18 -h 1080
run.bat -a encode -i source.mp4 -o out.mp4 -crf 20 -h 720 -t film
```

### VMAF score van bestaande encode

```powershell
run.bat -a vmaf -i source.mp4 -o encoded.mp4
```

### Inspect source metadata

```powershell
run.bat -a inspect -i video.mp4
# => schrijft video.mp4_inspect.json
```

### CAMBI banding check

```powershell
run.bat -a cambi -i source.mp4 -o encoded.mp4
# => CAMBI max: 12.34, mean: 0.45
```

---

## Alle flags

### Search parameters

| Flag          | Default | Wat                                                                |
| ------------- | ------- | ------------------------------------------------------------------ |
| `-targetvmaf` | `95.0`  | Target VMAF score (0–100)                                          |
| `-tolerance`  | `0.5`   | Hoe dicht bij target is goed genoeg (VMAF punten)                  |
| `-initialcrf` | `20`    | Start CRF voor zoekopdracht                                        |
| `-mincrf`     | `30`    | Laagste kwaliteit grens (hogere CRF = lager kwaliteit = kleiner)   |
| `-maxcrf`     | `15`    | Hoogste kwaliteit grens (lagere CRF = hogere kwaliteit = groter)   |

> [!warning] Naming is verwarrend
> `-mincrf 30` = minimum kwaliteit (CRF 30), `-maxcrf 15` = maximum kwaliteit (CRF 15). Lager CRF = hogere kwaliteit. Het zijn search bounds, geen kwaliteitsbounds.

### Encoding parameters

| Flag          | Alias | Default   | Wat                                                          |
| ------------- | ----- | --------- | ------------------------------------------------------------ |
| `-codec`      |       | `libx264` | Video codec (libx264, libx265, libsvtav1, libvpx-vp9)        |
| `-height`     | `-h`  |           | Output hoogte in px (aspect ratio behouden)                  |
| `-width`      | `-w`  |           | Output breedte in px (aspect ratio behouden)                 |
| `-maxbitrate` | `-mb` |           | Peak bitrate cap in kbps                                     |
| `-buffersize` | `-bs` |           | HRD buffer size in kbps (meestal 4x maxbitrate)              |
| `-tune`       | `-t`  |           | Encoder tune: `animation`, `film`, `grain`, `psnr`, `ssim`   |
| `-crf`        |       |           | CRF waarde (alleen voor `encode` actie)                      |
| `-bitrate`    |       |           | Target bitrate in kbps (alleen `encode` actie)               |
| `-minbitrate` |       |           | Minimum bitrate, forceert CBR (niet aanbevolen)              |

### I/O

| Flag      | Alias | Wat                                          |
| --------- | ----- | -------------------------------------------- |
| `-action` | `-a`  | Actie (verplicht)                            |
| `-input`  | `-i`  | Pad naar source video (verplicht)            |
| `-output` | `-o`  | Pad naar output file (`.mp4`, voor meeste)   |

---

## VMAF targets

| Score | Betekenis                                                            | Gebruik                          |
| ----- | -------------------------------------------------------------------- | -------------------------------- |
| 95    | Near-transparent — kijkers zien geen verschil met source             | Top ABR rung, archival, master   |
| 93    | Hoge kwaliteit — artifacts alleen bij close inspection               | **Default**, meeste content      |
| 90    | Goede kwaliteit — minor artifacts in complexe scenes                 | Bandwidth-zuinig                 |
| 85    | Acceptabel — duidelijke compressie zichtbaar                         | Mobile / heel klein              |

---

## Tune opties (`-t`)

| Tune        | Wanneer gebruiken                                          |
| ----------- | ---------------------------------------------------------- |
| `animation` | Anime, cartoons, getekende content (vlakke kleuren)        |
| `film`      | Live action met natuurlijke grain                          |
| `grain`     | Films met veel grain — behoud grain texture                |
| `psnr`      | Optimaliseren voor PSNR metric                             |
| `ssim`      | Optimaliseren voor SSIM metric                             |

---

## Workflow voorbeelden

### Voorbeeld 1: Anime serie naar 1080p

```powershell
run.bat -a optimize -i "S01E01.mkv" -o "S01E01_1080p.mp4" -h 1080 -t animation -targetvmaf 95
```

### Voorbeeld 2: Live action film, bandwidth limited

```powershell
run.bat -a optimize -i film.mkv -o film_compressed.mp4 -h 1080 -t film -targetvmaf 90 -mb 5000 -bs 20000
```

### Voorbeeld 3: 4K archival met HEVC

```powershell
run.bat -a optimize -i master.mov -o archive.mp4 -h 2160 -codec libx265 -targetvmaf 95
```

### Voorbeeld 4: Batch verwerken (PowerShell loop)

```powershell
Get-ChildItem *.mkv | ForEach-Object {
    $out = $_.BaseName + "_optimized.mp4"
    .\run.bat -a optimize -i $_.FullName -o $out -h 1080 -targetvmaf 93
}
```

### Voorbeeld 5: Eerst alleen zoeken, dan beslissen

```powershell
# Stap 1: vind CRF
run.bat -a search -i video.mp4 -h 1080 -targetvmaf 93
# => Found crf: 19

# Stap 2: encode met die CRF
run.bat -a encode -i video.mp4 -o output.mp4 -crf 19 -h 1080
```

---

## Troubleshooting

### `libvmaf NIET gevonden`

FFmpeg build heeft libvmaf nodig. De installer downloadt de gyan.dev "full" build die dit heeft. Check:

```powershell
.\bin\ffmpeg\bin\ffmpeg.exe -filters | findstr libvmaf
```

### `git clone mislukt`

Internetverbinding of GitHub bereikbaar? Check:

```powershell
.\bin\git\bin\git.exe --version
```

### Build mislukt

Check of Go correct werkt:

```powershell
.\bin\go\bin\go.exe version
```

### Output is veel groter dan verwacht

Je VMAF target is te hoog. Probeer 93 ipv 95 — visueel bijna geen verschil maar veel kleinere files.

### Output is te lelijk

VMAF target te laag, of je content heeft veel grain/complexity. Probeer `-t grain` of `-t film`, en target VMAF 95.

---

## Hoe de search werkt

```
       source.mp4
           |
    duration >= 60s?
     /            \
   nee            ja
    |              |
  hele video    detect scenes
  als ref       extract 15 samples
                concat naar sample.mp4
    \            /
     reference clip
           |
     score CRF min en max
     (vmaf bounds bepalen)
           |
     hybrid bisection loop:
       1. bisect range (70%)
       2. interpolate (30%)
       3. blend + clamp
       4. encode at CRF
       5. VMAF score
       6. binnen tolerance?
          ja -> klaar
          nee -> narrow range
           |
       gekozen CRF
```

Voor video's > 60 sec wordt niet de hele video gescoord maar 15 representatieve scenes (2–10 sec elk). Dat scheelt enorm in tijd zonder veel accuracy verlies.

---

## Bestandsstructuur na installatie

```
C:\ai code\asa\
├── install-dynamic-crf.bat    (installer)
├── run.bat                    (gebruik DEZE om dynamic-crf te runnen)
├── dynamic-crf.exe            (de gecompileerde binary)
├── install.log                (installer log)
└── bin\
    ├── 7zip\
    ├── ffmpeg\
    │   └── bin\ffmpeg.exe
    ├── git\
    ├── go\
    └── mediainfo\
```

---

## Links

- [GitHub repo](https://github.com/terranvigil/dynamic-crf)
- [VMAF (Netflix)](https://github.com/Netflix/vmaf)
- [Werner Robitza's CRF guide](https://slhck.info/video/2017/02/24/crf-guide.html)
- [Netflix Dynamic Optimizer](https://netflixtechblog.com/dynamic-optimizer-a-perceptual-video-encoding-optimization-framework-e19f1e3a277f)
- [Jan Ozer: Optimal Encoding Ladder with VMAF](https://streaminglearningcenter.com/encoding/optimal_encoding_ladder_vmaf.html)
