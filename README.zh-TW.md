[English](README.md) · **繁體中文**

# mpv-adaptive-enhance

在 Windows 上把 [mpv](https://mpv.io) 設定成會**在每部影片播放當下**挑出顯示卡真的撐得住的畫質：放大／銳化著色器、動態補幀，串流則依你的網路頻寬決定 YouTube 解析度。

## 重點一覽

| | |
|---|---|
| 問題 | 固定的著色器設定一定有些檔案不合用：對 1080p30 影片毫無負擔的配置，換到 1080p180 影片可能每秒掉 50+ 格；4K 串流在網路塞車時也只會一直卡在緩衝。 |
| 做了什麼 | 每部影片當場建一套階梯，由重到輕：`[RIFE + shaders]` → `[MVTools interp + shaders]` → `[full shaders]` → `[light]` → `[chroma]` → `[none]`。從這個來源和螢幕還沒失敗過的最高一階開始；開始掉格就降一階，並記住這類影片在這塊螢幕上的上限。 |
| 結果 | 測試機上，把 1080p 畫面升到 1440p，每幀 GPU 時間是 1.3–4.5 ms；1080p60 → 90 fps 的 CPU 補幀可跑滿速。 |
| 技術組成 | Windows 10/11、mpv（shinchiro 版本）、Lua 腳本、VapourSynth 搭配 MVTools 與 RIFE（Vulkan）、yt-dlp、Python 3.13。 |

## 運作方式

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

| 組件 | 選擇項目 |
|---|---|
| `adaptive-enhance.lua` | 依渲染比例（放大 / 1:1 / 縮小）與內容類型選擇著色器組合，以及補幀設定。 |
| `ytdl-adaptive.lua` | 依測得的頻寬選擇串流高度（2160 → 360）；串流開不起來時，改試其他 YouTube 播放客戶端。 |
| `mvfps.vpy` | 低開銷的動態補償補幀（MVTools，在 CPU 上執行），例如 30 → 90/180 fps。**預設開啟。** |
| `rife.vpy` | AI 補幀（RIFE，Vulkan 顯示卡）。畫質更好，負擔重得多。**預設關閉。** |

著色器組合（CfL = chroma-from-luma 色度預測）：

| 渲染比例 | Full | Light |
|---|---|---|
| 放大 ≥ 1.6x | CfL + ArtCNN C4F16 | CfL Lite + CAS-scaled |
| 放大 1.3–1.6x | CfL + ravu-zoom-ar-r3 | CfL Lite + CAS-scaled |
| 1:1 | CfL + CAS | CfL Lite + CAS |
| 縮小 | KrigBilateral + adaptive-sharpen | — |

## 系統需求

- 64 位元 Windows 10/11，需有 `winget`（一般 Windows 10/11 安裝均已內建；若找不到 `winget` 指令，請至 Microsoft Store 安裝 "App Installer"）。
- 具備最新 Vulkan 驅動程式的顯示卡。
- 安裝過程需要網路連線，並備妥約 300 MB 磁碟空間（供 mpv、Python、VapourSynth 與外掛程式使用）。
- 不需要系統管理員帳號，但安裝 mpv 時 Windows 可能會跳出一次權限提示。

**只在同一台機器上測過：** AMD Radeon RX 9070 XT、Ryzen 7 7700、2560x1440、180 Hz。這套階梯設計上會配合較慢的硬體，但 NVIDIA、Intel 顯示卡與其他螢幕面板都還沒試過。在沒測過的顯示卡上，每種新類型的影片前幾分鐘可能會卡頓，因為階梯還在學；按 `Ctrl+Shift+r` 可以讓它重學。歡迎回報結果。

## 安裝方式

1. 下載這個儲存庫（點綠色 **Code** 按鈕 → **Download ZIP**）並解壓縮。
2. 開啟解壓後的資料夾，在空白處按右鍵 → **在終端機中開啟**，然後執行：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. 登出 Windows 再重新登入一次（讓 mpv 讀到更新後的 PATH）。

安裝程式會：

- 用 `winget` 安裝 mpv（shinchiro 版本）、yt-dlp、Deno 與 Python 3.13（已裝的會略過；mpv 可能會跳一次 Windows 權限提示）；
- 用 `pip` 安裝 VapourSynth 並完成註冊，讓 mpv 找得到；
- 從原作者那裡下載 MVTools、RIFE 外掛與著色器；
- 把 `mpv.conf`、`input.conf`、腳本與 `.vpy` 檔寫進 `%APPDATA%\mpv`（原有的 `mpv.conf` / `input.conf` 會先複製到 `%APPDATA%\mpv\backup-<date>\`）；
- 如果有裝 [mpv.net](https://github.com/mpvnet-player/mpv.net)，一併設定好；
- 在桌面建立 **Play in mpv** 捷徑。

可選參數：`-SkipRife`（不下載 RIFE）、`-NoShortcut`、`-MvtoolsDll <path>`（用你自己編的版本）。重新執行安裝程式就會原地更新全部內容。

## 使用方式

- **本機檔案：** 照平常方式用 mpv 開啟，或把檔案拖到 **Play in mpv** 上。
- **YouTube / 其他網站：** 複製連結後，連按兩下 **Play in mpv**。
- 每種新類型的影片，前 **15–40 秒**可能會頓一兩下，這是腳本在量你的顯示卡撐得住多少。量到的結果會快取，下次播類似的檔案就直接從對的階層開始。

### 快捷鍵

| 按鍵 | 動作 |
|---|---|
| `Tab` | 選單：影片類型、增強層級、動態補幀、RIFE、串流畫質 |
| `` ` `` | 即時狀態覆蓋層（目前階層、掉格數、渲染時間） |
| `Ctrl+i` / `Ctrl+Shift+i` | 單行狀態 / 目前啟用的著色器清單 |
| `Alt+a` / `Alt+l` / `Alt+g` / `Alt+u` | 影片類型：動漫/3D、真人實拍、顆粒感 / 低位元率、切回自動 |
| `Ctrl+r` | RIFE：關 → 自動 → 開 |
| `Ctrl+s` | 全部增強關掉 / 再開（A/B 對比） |
| `Ctrl+Shift+r` | 清掉這個來源與螢幕已學到的上限 |
| `Ctrl+1` / `Ctrl+2` | 串流：最佳畫質（最高 4K）/ ≤1080p30（讓 RIFE 跑得動） |
| `Alt+0` … `Alt+6` | 手動著色器預設組（按 `Alt+u` 前的臨時選擇） |
| `Ctrl+d` | Deband 開/關 |
| `Ctrl+p` | mpv 自己的統計頁面 |

### 設定選項

在 `%APPDATA%\mpv\mpv.conf` 裡設定，例如 `script-opts-append=adaptive_enhance-mv=off`：

| 選項 | 可選值 | 預設值 |
|---|---|---|
| `adaptive_enhance-mv` | `auto`, `off` | `auto` |
| `adaptive_enhance-rife` | `off`, `auto`, `on` | `off` |
| `adaptive_enhance-content` | `auto`, `anime`, `live`, `grainy` | `auto` |
| `adaptive_enhance-resync_seek` | `no`, `yes`（播放中換階層後 1.5 秒，發出一次長度為零的精確跳轉；給只在跳轉時重新同步的裝置播放器控制的 mpv 用） | `no` |
| `adaptive_enhance-skip_top` | 整數 `0`, `1`, `2`, ...（階梯中最重的前 N 階不用；最後一階一定保留） | `0` |
| `ytdl_adaptive-reload` | `yes`, `no`（播放中不換解析度） | `yes` |
| `ytdl_adaptive-fallback_clients` | 用 `+` 串起來的 YouTube 客戶端名稱 | `web_embedded+tv+mweb` |

## 疑難排解

| 狀況 | 原因 / 解法 |
|---|---|
| 開影片約 3 秒後 mpv 就關掉，沒有錯誤訊息 | VapourSynth 資料夾還沒進 PATH。登出再登入；若還是一樣，重跑安裝程式。 |
| mpv.net 卡在 "vapoursynth initializing" | RIFE 外掛在 mpv.net 裡會卡死。安裝程式在 mpv.net 下預設關掉 RIFE；想用 RIFE 請改用 `mpv.exe`（桌面捷徑用的就是它）。 |
| 由其他程式控制的 mpv（例如 funscript／裝置播放器）跟裝置不同步 | 只在那個 mpv 執行個體關掉補幀：在它的 `mpv.conf` 加上 `script-opts-append=adaptive_enhance-mv=off` 與 `script-opts-append=adaptive_enhance-rife=off`。再加 `script-opts-append=adaptive_enhance-resync_seek=yes`，讓每次降階後用一次跳轉重新同步。著色器不影響時間軸，可以留著。 |
| YouTube：HTTP 403 或 "no video formats" | yt-dlp 太舊：執行 `winget upgrade yt-dlp.yt-dlp`。 |
| 檔案剛開始播的幾秒會頓 | 階梯還在調整，屬正常（新類型的影片約 15–40 秒）。 |
| 畫面看起來跟以前一樣 | 按 `` ` `` 看：1:1 比例又碰上乾淨的訊源時，本來就沒多少可加強的。用 `Ctrl+s` 對照。 |
| 安裝程式："could not download mvtools.dll" | 連不到 Release（沒網路、有 Proxy，或儲存庫是私人狀態）。稍後再試，或照 [`third_party/mvtools`](third_party/mvtools) 自己編 DLL，再跑 `install.ps1 -MvtoolsDll <path>`。 |
| 想確認 VapourSynth 有沒有裝好 | `py -3.13 -m vapoursynth check-env` 每行都該顯示 "this installation"，而 `py -3.13 -c "import vapoursynth as vs; print(vs.core.mv, vs.core.rife)"` 該印出兩個外掛。 |
| 想換回原本的設定 | 備份在 `%APPDATA%\mpv\backup-<date>\`。 |
| 顯示卡驅動重設（畫面黑掉幾秒） | 測試機上用 AV1 1080p180 檔案遇過一次，重試 5 次都沒再現。若再發生，在 `mpv.conf` 設 `hwdec=d3d11va-copy`。（單純的 `hwdec=d3d11va` 配 `gpu-api=vulkan` 不能用；mpv 會默默退回軟體解碼。） |

## 測試數據

以下數據來自測試機（RX 9070 XT，2560x1440、180 Hz）。渲染開銷是 libplacebo 處理 1080p 訊源時每幀的 GPU 時間；畫質是暫停單幀與 4K 母帶縮到 1440p 的參考畫面相較的 PSNR（dB），依序為 3D 渲染 / 2D 動漫 / 真人實拍：

| 著色器組合 | 渲染 | 1080p→1440p | 720p→1440p |
|---|---|---|---|
| CfL + ArtCNN C4F16 | 4.5 ms | 32.79 / 45.63 / 46.49 | 32.31 / 42.27 / 43.85 |
| CfL + ravu-zoom-ar-r3 | 1.8 ms | 32.71 / 46.86 / 46.64 | 32.06 / 42.07 / 44.13 |
| KrigBilateral + CAS-scaled | 1.3 ms | 32.69 / 45.21 / 46.10 | 31.79 / 39.13 / 43.59 |

**這些數字要看得很小心。** 每種內容只取一幀，參考畫面用 Lanczos 縮小（偏好柔和的縮放、壓低銳化的分數），而 0.1–0.3 dB 的差距在誤差範圍內。只有差距大的才站得住腳（FSR 與 NIS 低了 3–8 dB，所以沒採用；ArtCNN C4F32 的耗時是 C4F16 的兩倍，也沒採用）。要認真比較，得用多幀、無損訊源，再搭配 SSIMULACRA2 / VMAF。

CPU 動態補幀（Ryzen 7 7700、180 Hz、著色器開著），"ok" 代表滿速：

| 訊源 | flow → 90 | flow → 180 | block → 90 | block → 180 |
|---|---|---|---|---|
| 1080p30 | ok | 85% | ok | ok |
| 1080p60 | ok | 65–78% | ok | ok |
| 4K30（在 1440p 補幀） | 80% | 52% | ok | 73% |
| 4K60（在 1440p 補幀） | 34% | 35% | ok | 32% |

階梯會挑上面這些裡面，你的機器跑得滿速的最高一階。

## 解除安裝

安裝程式寫入的東西，請刪掉：

- `%APPDATA%\mpv\mpv.conf`、`input.conf`，以及 `scripts-adaptive`、`vs`、`shaders` 三個資料夾（再把 `%APPDATA%\mpv\backup-<date>\` 裡原本的設定放回去，如果有的話）
- 有裝 mpv.net 的話，`%APPDATA%\mpv.net\` 裡同樣那兩個 `.conf` 檔
- `%LOCALAPPDATA%\mpv-adaptive-enhance` 與桌面的 **Play in mpv** 捷徑
- 學到的資料：`%APPDATA%\mpv\adaptive-cache.json` 與 `ytdl-adaptive.json`

程式用 `winget uninstall shinchiro.mpv` 移除（`yt-dlp.yt-dlp`、`DenoLand.Deno` 與 Python 同理，別處用得到就留著），VapourSynth 用 `py -3.13 -m pip uninstall vapoursynth` 移除。安裝程式可能也把 Python 與 VapourSynth 的資料夾加進了你的使用者 PATH。

## 專案結構

| 路徑 | 內容 |
|---|---|
| `install.ps1` | 安裝程式（見「安裝方式」）。 |
| `config/` | `mpv.conf`、`input.conf`。 |
| `scripts/` | `adaptive-enhance.lua`、`ytdl-adaptive.lua`、`tests/test_learning.lua`。 |
| `vs/` | `mvfps.vpy`、`rife.vpy`。 |
| `launcher/` | `play-in-mpv.ps1`，也就是 **Play in mpv** 捷徑的目標。 |
| `third_party/mvtools/` | MVTools 建置用的修正檔與 `build-mvtools.sh`（見「授權條款」）。 |

## 授權條款

本儲存庫自己的檔案（腳本、`.vpy`、設定、安裝程式、說明文件）採用 [MIT 授權條款](LICENSE)。下面列出的元件都不包含在這個儲存庫裡；安裝程式會分別向各自的作者下載：

| 組件 | 作者 | 授權條款 |
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

**mvtools.dll** 附在本儲存庫的 Releases 裡。它由 GitHub Actions（[`.github/workflows/mvtools.yml`](.github/workflows/mvtools.yml)）以上游 v29_2 原始碼加上 [`third_party/mvtools`](third_party/mvtools) 裡的兩個小修正檔編出來（只修建置問題：靜態連結和一個 mingw 編譯錯誤），所以跟上游一樣是 GPL-2.0。上游自己的 Windows 二進位檔是 v24，現在的 VapourSynth 載不進去。想自己編，請看 [`third_party/mvtools/build-mvtools.sh`](third_party/mvtools/build-mvtools.sh)。

沒有使用 SVP 的 svpflow 函式庫：它們的授權在 Windows 上要另外買 SVP 4 Pro。
