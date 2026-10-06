# mpv-adaptive-enhance

[繁體中文說明](README.zh-TW.md)

Makes [mpv](https://mpv.io) on Windows pick the best picture your GPU can actually sustain,
**per video, while it plays**: upscaling/sharpening shaders, motion interpolation, and (for
streams) the YouTube resolution your connection can feed. When frames start dropping it steps
down one level and remembers that limit for that kind of video on that display.

Built because a fixed shader setup is always wrong for some files: a chain that is free for a
1080p30 video can drop 50+ frames per second on a 1080p180 one, and a 4K stream over a busy
connection just sits buffering.

## What it does

```
 open a video
      |
      v
 build a ladder for this file, heaviest first:
   [RIFE + shaders] -> [MVTools interp + shaders] -> [full shaders] -> [light] -> [chroma] -> [none]
      |                 (RIFE only if you turn it on; interp targets = refresh / 1, 2, 3, 6)
      v
 start at the highest rung not already known to fail for this source + display
      |
      v
 every 2 s: dropped / delayed / mistimed frames, render time, interpolation output rate
      |
      +-- 2 bad windows in a row --> step down one rung, remember it (14 days)
      +-- otherwise              --> keep playing
```

| Part | What it chooses |
|---|---|
| `adaptive-enhance.lua` | Shader chain from the render scale (upscale / 1:1 / downscale) and content type, plus frame interpolation. |
| `ytdl-adaptive.lua` | Stream height (2160 → 360) from measured bandwidth; retries other YouTube player clients when a stream fails to open. |
| `mvfps.vpy` | Cheap motion-compensated interpolation (MVTools, runs on the CPU), e.g. 30 → 90/180 fps. **On by default.** |
| `rife.vpy` | AI frame interpolation (RIFE, Vulkan GPU). Better quality, much heavier. **Off by default.** |

Shader chains (CfL = chroma-from-luma prediction):

| Render scale | Full | Light |
|---|---|---|
| upscale ≥ 1.6x | CfL + ArtCNN C4F16 | CfL Lite + CAS-scaled |
| upscale 1.3–1.6x | CfL + ravu-zoom-ar-r3 | CfL Lite + CAS-scaled |
| 1:1 | CfL + CAS | CfL Lite + CAS |
| downscale | KrigBilateral + adaptive-sharpen | — |

## Requirements

- Windows 10/11, 64-bit, with `winget` (included in normal Windows 10/11 installs; if the
  `winget` command is missing, install "App Installer" from the Microsoft Store).
- A GPU with a current Vulkan driver.
- An internet connection during install, and about 300 MB of disk (mpv, Python,
  VapourSynth, plugins).
- No administrator account is needed, but Windows may show a permission prompt while mpv
  installs.

**Tested on one machine only:** AMD Radeon RX 9070 XT, Ryzen 7 7700, 2560x1440 at 180 Hz.
The ladder adapts to slower hardware by design, but NVIDIA and Intel GPUs and other panels have
not been tried. On an untested GPU the first minutes of each new kind of video may stutter
while the ladder learns; `Ctrl+Shift+r` makes it re-learn. Reports welcome.

## Install

1. Download this repository (green **Code** button → **Download ZIP**) and unzip it.
2. Open the unzipped folder, right-click an empty spot → **Open in Terminal**, and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. Sign out of Windows and back in once (so mpv sees the updated PATH).

The installer:

- installs mpv (shinchiro build), yt-dlp, Deno and Python 3.13 with `winget` (skips what you
  already have; mpv may show one Windows permission prompt);
- installs VapourSynth with `pip` and registers it so mpv can find it;
- downloads the MVTools and RIFE plugins and the shaders from their original authors;
- writes `mpv.conf`, `input.conf`, the scripts and the `.vpy` files to `%APPDATA%\mpv`
  (an existing `mpv.conf` / `input.conf` is first copied to `%APPDATA%\mpv\backup-<date>\`);
- if [mpv.net](https://github.com/mpvnet-player/mpv.net) is installed, configures it too;
- creates a **Play in mpv** desktop shortcut.

Options: `-SkipRife` (do not download RIFE), `-NoShortcut`, `-MvtoolsDll <path>` (use your own
build). Re-running the installer updates everything in place.

## Use

- **Local files:** open them with mpv as usual, or drop them on **Play in mpv**.
- **YouTube / other sites:** copy the link, double-click **Play in mpv**.
- The first **15–40 seconds** of a new kind of video may show a short hitch or two while the
  script measures what your GPU sustains. The result is cached, so the next similar file starts
  at the right level.

### Keys

| Key | Action |
|---|---|
| `Tab` | Menu: video type, enhancement level, motion interpolation, RIFE, stream quality |
| `` ` `` | Live stats overlay (current rung, drops, render time) |
| `Ctrl+i` / `Ctrl+Shift+i` | One-line status / active shader list |
| `Alt+a` / `Alt+l` / `Alt+g` / `Alt+u` | Video type: anime/3D, live action, grainy, back to auto |
| `Ctrl+r` | RIFE: off → auto → on |
| `Ctrl+s` | All enhancement off / back on (A/B compare) |
| `Ctrl+Shift+r` | Forget the learned limit for this source and display |
| `Ctrl+1` / `Ctrl+2` | Stream: best quality (up to 4K) / ≤1080p30 so RIFE can run |
| `Alt+0` … `Alt+6` | Manual shader presets (until `Alt+u`) |
| `Ctrl+d` | Deband on/off |
| `Ctrl+p` | mpv's own stats page |

### Options

Set in `%APPDATA%\mpv\mpv.conf`, e.g. `script-opts-append=adaptive_enhance-mv=off`:

| Option | Values | Default |
|---|---|---|
| `adaptive_enhance-mv` | `auto`, `off` | `auto` |
| `adaptive_enhance-rife` | `off`, `auto`, `on` | `off` |
| `adaptive_enhance-content` | `auto`, `anime`, `live`, `grainy` | `auto` |
| `ytdl_adaptive-reload` | `yes`, `no` (no mid-playback resolution changes) | `yes` |
| `ytdl_adaptive-fallback_clients` | YouTube clients joined with `+` | `web_embedded+tv+mweb` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| mpv closes ~3 s after opening a video, no error | The VapourSynth folder is not on PATH yet. Sign out and back in; if it persists, re-run the installer. |
| mpv.net freezes at "vapoursynth initializing" | The RIFE plugin hangs inside mpv.net. The installer keeps RIFE off there; use `mpv.exe` (the shortcut does) if you want RIFE. |
| YouTube: HTTP 403 or "no video formats" | yt-dlp is out of date: `winget upgrade yt-dlp.yt-dlp`. |
| Stutter for the first seconds of a file | Expected while the ladder settles (15–40 s for a new kind of video). |
| Picture looks the same as before | Press `` ` ``: at 1:1 scale on a sharp source there is little to improve. Compare with `Ctrl+s`. |
| Installer: "could not download mvtools.dll" | The release could not be reached (no internet, a proxy, or the repository is private). Re-run later, or build the DLL with [`third_party/mvtools`](third_party/mvtools) and run `install.ps1 -MvtoolsDll <path>`. |
| Check that VapourSynth is set up | `py -3.13 -m vapoursynth check-env` should say "this installation" on every line, and `py -3.13 -c "import vapoursynth as vs; print(vs.core.mv, vs.core.rife)"` should print two plugins. |
| Want the old config back | It is in `%APPDATA%\mpv\backup-<date>\`. |
| GPU driver reset (screen goes black for a few seconds) | Seen once on the test machine with an AV1 1080p180 file, not reproducible in 5 retries. If it recurs, set `hwdec=d3d11va-copy` in `mpv.conf`. (Plain `hwdec=d3d11va` does not work with `gpu-api=vulkan`; mpv silently falls back to software decoding.) |

## Measurements

From the test machine (RX 9070 XT, 2560x1440 at 180 Hz). Render cost is libplacebo's per-frame
GPU time for a 1080p source; quality is PSNR (dB) of one paused frame against a 1440p reference
downscaled from a 4K master, for 3D render / 2D anime / live action:

| Chain | Render | 1080p→1440p | 720p→1440p |
|---|---|---|---|
| CfL + ArtCNN C4F16 | 4.5 ms | 32.79 / 45.63 / 46.49 | 32.31 / 42.27 / 43.85 |
| CfL + ravu-zoom-ar-r3 | 1.8 ms | 32.71 / 46.86 / 46.64 | 32.06 / 42.07 / 44.13 |
| KrigBilateral + CAS-scaled | 1.3 ms | 32.69 / 45.21 / 46.10 | 31.79 / 39.13 / 43.59 |

**Read these with care.** One frame per content type, a Lanczos-downscaled reference (which
favours soft scalers and penalises sharpening), and differences of 0.1–0.3 dB are within noise.
Only the large gaps are solid (FSR and NIS scored 3–8 dB lower and were dropped; ArtCNN C4F32
was dropped for costing twice C4F16). A proper comparison would use many frames, a lossless
source and SSIMULACRA2 / VMAF.

Motion interpolation on the CPU (Ryzen 7 7700, 180 Hz, shaders on), "ok" = full speed:

| Source | flow → 90 | flow → 180 | block → 90 | block → 180 |
|---|---|---|---|---|
| 1080p30 | ok | 85% | ok | ok |
| 1080p60 | ok | 65–78% | ok | ok |
| 4K30 (interpolated at 1440p) | 80% | 52% | ok | 73% |
| 4K60 (interpolated at 1440p) | 34% | 35% | ok | 32% |

The ladder picks the highest of these that plays at full speed on your machine.

## Uninstall

The installer writes these; delete them:

- `%APPDATA%\mpv\mpv.conf`, `input.conf`, and the folders `scripts-adaptive`, `vs`, `shaders`
  (then put back your previous config from `%APPDATA%\mpv\backup-<date>\`, if there is one)
- the same two `.conf` files in `%APPDATA%\mpv.net\`, if mpv.net is installed
- `%LOCALAPPDATA%\mpv-adaptive-enhance` and the **Play in mpv** desktop shortcut
- learned data: `%APPDATA%\mpv\adaptive-cache.json` and `ytdl-adaptive.json`

Remove the programs with `winget uninstall shinchiro.mpv` (likewise `yt-dlp.yt-dlp`,
`DenoLand.Deno` and Python if you do not use them elsewhere) and VapourSynth with
`py -3.13 -m pip uninstall vapoursynth`. The installer may also have added the Python and
VapourSynth folders to your user PATH.

## Licences

This repository's own files (scripts, `.vpy`, configs, installer, docs) are under the
[MIT licence](LICENSE). Nothing below is included in this repository; the installer downloads
each component from its author:

| Component | Author | Licence |
|---|---|---|
| [mpv](https://mpv.io) (shinchiro build) | mpv developers | GPL-2.0+ / LGPL-2.1+ |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | yt-dlp contributors | Unlicense |
| [VapourSynth](https://github.com/vapoursynth/vapoursynth) | Fredrik Mellbin | LGPL-2.1 |
| [vapoursynth-mvtools](https://github.com/dubhater/vapoursynth-mvtools) v29_2 | dubhater et al. | GPL-2.0 |
| [VapourSynth-RIFE-ncnn-Vulkan](https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan) r9_mod_v33 + rife-v4.6 model | HolyWu, styler00dollar; RIFE by hzwer | MIT |
| [KrigBilateral](https://gist.github.com/igv/a015fc885d5c22e6891820ad89555637) | igv | LGPL-3.0 |
| [adaptive-sharpen](https://gist.github.com/igv/8a77e4eb8276753b54bb94c1c50c317e) | bacondither (port: igv) | BSD-2-Clause |
| [CAS / CAS-scaled](https://gist.github.com/agyild/bbb4e58298b2f86aa24da3032a0d2ee6) | AMD (port: agyild) | MIT |
| [CfL_Prediction](https://github.com/Artoriuz/glsl-chroma-from-luma-prediction) | Artoriuz | MIT |
| [ArtCNN](https://github.com/Artoriuz/ArtCNN) | Artoriuz, Kacper Michajłow | MIT |
| [ravu-zoom-ar-r3](https://github.com/bjin/mpv-prescalers) | bjin | LGPL-3.0 |

**mvtools.dll** is attached to this repository's releases. It is built by GitHub Actions
([`.github/workflows/mvtools.yml`](.github/workflows/mvtools.yml)) from the upstream v29_2 source
plus the two small patches in [`third_party/mvtools`](third_party/mvtools) (build fixes only:
static linking and one mingw compile error), so it is GPL-2.0 like upstream. Upstream's own
Windows binary is v24, which current VapourSynth cannot load. To build it yourself, see
[`third_party/mvtools/build-mvtools.sh`](third_party/mvtools/build-mvtools.sh).

SVP's svpflow libraries are not used: their licence requires a paid SVP 4 Pro licence on Windows.
