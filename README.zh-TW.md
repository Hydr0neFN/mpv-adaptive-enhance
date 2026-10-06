# mpv-adaptive-enhance

[English](README.md)

讓 Windows 上的 [mpv](https://mpv.io) 在**播放每部影片時，即時**選擇顯示卡實際能穩定負擔的最佳畫面：包含放大／銳化著色器、動態補幀，以及（針對串流）依照網路頻寬自動選擇 YouTube 解析度。一旦開始掉格，就會自動降低一個階層，並記住此類影片在該螢幕上的效能上限。

開發初衷是因固定的著色器設定往往無法適用所有檔案：對 1080p30 影片毫無負擔的配置，在 1080p180 影片上可能會每秒掉 50 格以上；而在網路塞車時播放 4K 串流，則只會一直卡在緩衝。

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
| `ytdl-adaptive.lua` | 依測得的頻寬選擇串流高度（2160 → 360）；當串流無法開啟時，嘗試其他 YouTube 播放客戶端。 |
| `mvfps.vpy` | 低開銷的動態補償補幀（MVTools，在 CPU 上執行），例如 30 → 90/180 fps。**預設開啟。** |
| `rife.vpy` | AI 補幀（RIFE，Vulkan 顯示卡）。畫質更佳，但負擔沉重許多。**預設關閉。** |

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
- 安裝過程中需連線網路，並具備約 300 MB 磁碟空間（供 mpv、Python、VapourSynth 與外掛程式使用）。
- 不需要系統管理員帳號，但在安裝 mpv 時 Windows 可能會跳出一次權限提示。

**僅在單一設備上測試過：** AMD Radeon RX 9070 XT、Ryzen 7 7700、2560x1440 @ 180 Hz。這套階梯機制在設計上會自動適應較慢的硬體，但尚未在 NVIDIA、Intel 顯示卡與其他螢幕面板上測試過。在未測試過的顯示卡上，播放每種新類型的影片最初幾分鐘可能會有卡頓，這是階梯機制正在學習適應；按下 `Ctrl+Shift+r` 可讓它重新學習。歡迎回報測試結果。

## 安裝方式

1. 下載此儲存庫（點擊綠色的 **Code** 按鈕 → **Download ZIP**）並解壓縮。
2. 開啟解壓縮後的資料夾，在空白處按滑鼠右鍵 → **在終端機中開啟**，並執行：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. 登出 Windows 並重新登入一次（讓 mpv 讀取更新後的 PATH 環境變數）。

安裝程式：

- 透過 `winget` 安裝 mpv（shinchiro 版本）、yt-dlp、Deno 與 Python 3.13（已安裝的項目會自動略過；mpv 可能會跳出一次 Windows 權限提示）；
- 透過 `pip` 安裝 VapourSynth 並完成註冊，以便 mpv 偵測與讀取；
- 從原作者處下載 MVTools、RIFE 外掛程式與著色器；
- 將 `mpv.conf`、`input.conf`、腳本及 `.vpy` 檔案寫入 `%APPDATA%\mpv`（若已有 `mpv.conf` / `input.conf`，會先備份至 `%APPDATA%\mpv\backup-<date>\`）；
- 若已安裝 [mpv.net](https://github.com/mpvnet-player/mpv.net)，也會一併設定；
- 在桌面建立 **Play in mpv** 捷徑。

可選參數：`-SkipRife`（不下載 RIFE）、`-NoShortcut`、`-MvtoolsDll <path>`（使用自訂建置版本）。重新執行安裝程式可直接就地更新所有組件。

## 使用方式

- **本機檔案：** 如常使用 mpv 開啟，或將檔案拖曳至 **Play in mpv**。
- **YouTube / 其他網站：** 複製連結後，連按兩下 **Play in mpv**。
- 播放新類型的影片時，前 **15–40 秒** 可能會有一兩次短暫頓挫，這是腳本在測量顯示卡能負擔的效能上限。測量結果會快取保存，下次播放類似檔案時就會直接從合適的階層開始。

### 快捷鍵

| 按鍵 | 動作 |
|---|---|
| `Tab` | 選單：影片類型、增強層級、動態補幀、RIFE、串流畫質 |
| `` ` `` | 即時狀態覆蓋層（目前階層、掉格數、渲染時間） |
| `Ctrl+i` / `Ctrl+Shift+i` | 單行狀態資訊 / 目前啟用的著色器清單 |
| `Alt+a` / `Alt+l` / `Alt+g` / `Alt+u` | 影片類型：動漫/3D、真人實拍、顆粒感 / 低位元率、切回自動 |
| `Ctrl+r` | RIFE：關閉 → 自動 → 開啟 |
| `Ctrl+s` | 關閉 / 重新開啟所有增強功能（A/B 對比） |
| `Ctrl+Shift+r` | 清除此影片來源與螢幕已學習的效能限制 |
| `Ctrl+1` / `Ctrl+2` | 串流：最佳畫質（最高 4K）/ ≤1080p30（以便執行 RIFE） |
| `Alt+0` … `Alt+6` | 手動著色器預設檔（直到按下 `Alt+u`） |
| `Ctrl+d` | 開啟/關閉 去色帶（Deband） |
| `Ctrl+p` | mpv 內建統計資訊頁面 |

### 設定選項

於 `%APPDATA%\mpv\mpv.conf` 中設定，例如 `script-opts-append=adaptive_enhance-mv=off`：

| 選項 | 可選值 | 預設值 |
|---|---|---|
| `adaptive_enhance-mv` | `auto`, `off` | `auto` |
| `adaptive_enhance-rife` | `off`, `auto`, `on` | `off` |
| `adaptive_enhance-content` | `auto`, `anime`, `live`, `grainy` | `auto` |
| `ytdl_adaptive-reload` | `yes`, `no`（播放中不切換解析度） | `yes` |
| `ytdl_adaptive-fallback_clients` | 以 `+` 連接的 YouTube 客戶端名稱 | `web_embedded+tv+mweb` |

## 疑難排解

| 狀況 | 原因 / 解決方法 |
|---|---|
| 開啟影片約 3 秒後 mpv 自動關閉，且無錯誤訊息 | VapourSynth 資料夾尚未加入 PATH。請登出並重新登入；若問題仍存在，請重新執行安裝程式。 |
| mpv.net 卡在 "vapoursynth initializing" | RIFE 外掛程式在 mpv.net 中會卡死。安裝程式已在該處預設停用 RIFE；若想使用 RIFE，請使用 `mpv.exe`（桌面捷徑即為此）。 |
| YouTube：HTTP 403 或 "no video formats" | yt-dlp 版本過舊：執行 `winget upgrade yt-dlp.yt-dlp` 更新。 |
| 播放檔案最初幾秒有卡頓 | 階梯機制調整時的正常現象（新類型的影片約需 15–40 秒）。 |
| 畫面看起來跟以前一樣 | 按下 `` ` `` 檢查：在 1:1 比例且訊源清晰的情況下，幾乎沒有增強空間。可使用 `Ctrl+s` 對比。 |
| 安裝程式："could not download mvtools.dll" | 無法連線至 Release 下載點（無網路連線、Proxy 代理伺服器問題，或儲存庫為私人狀態）。請稍後重試，或透過 [`third_party/mvtools`](third_party/mvtools) 自行編譯 DLL 並執行 `install.ps1 -MvtoolsDll <path>`。 |
| 確認 VapourSynth 是否已正確安裝設定 | 執行 `py -3.13 -m vapoursynth check-env` 每行都應顯示 "this installation"，且執行 `py -3.13 -c "import vapoursynth as vs; print(vs.core.mv, vs.core.rife)"` 應印出兩個外掛程式。 |
| 想還原舊的設定檔 | 備份檔位於 `%APPDATA%\mpv\backup-<date>\`。 |
| 顯示卡驅動程式重設（螢幕黑畫面數秒） | 測試機上曾於播放 AV1 1080p180 檔案時發生過一次，後續重試 5 次皆未再現。若重複發生，請在 `mpv.conf` 中設定 `hwdec=d3d11va-copy`。（單純的 `hwdec=d3d11va` 無法搭配 `gpu-api=vulkan` 使用；mpv 會無聲無息地退回軟體解碼。） |

## 測試數據

來自測試機（RX 9070 XT，2560x1440 @ 180 Hz）的數據。渲染開銷為 libplacebo 處理 1080p 訊源時每幀的顯示卡時間；畫質則是暫停單幀畫面與 4K 母帶縮小至 1440p 的參考畫面相比之 PSNR（dB），依序為 3D 渲染 / 2D 動漫 / 真人實拍：

| 著色器組合 | 渲染耗時 | 1080p→1440p | 720p→1440p |
|---|---|---|---|
| CfL + ArtCNN C4F16 | 4.5 ms | 32.79 / 45.63 / 46.49 | 32.31 / 42.27 / 43.85 |
| CfL + ravu-zoom-ar-r3 | 1.8 ms | 32.71 / 46.86 / 46.64 | 32.06 / 42.07 / 44.13 |
| KrigBilateral + CAS-scaled | 1.3 ms | 32.69 / 45.21 / 46.10 | 31.79 / 39.13 / 43.59 |

**請謹慎解讀這些數據。** 每種內容類型僅取單幀，參考標準採 Lanczos 縮小（此方式偏好較柔和的縮放演算法並壓低銳化分數），且 0.1–0.3 dB 的差異屬於誤差範圍。只有較大的差距才具參考價值（例如 FSR 和 NIS 分數低了 3–8 dB 因而被捨棄；ArtCNN C4F32 則因耗時為 C4F16 的兩倍而被捨棄）。嚴謹的比較應採用多幀畫面、無損訊源以及 SSIMULACRA2 / VMAF 指標。

CPU 動態補幀測試（Ryzen 7 7700，180 Hz，開啟著色器），"ok" 代表滿速運行：

| 訊源 | flow → 90 | flow → 180 | block → 90 | block → 180 |
|---|---|---|---|---|
| 1080p30 | ok | 85% | ok | ok |
| 1080p60 | ok | 65–78% | ok | ok |
| 4K30（在 1440p 補幀） | 80% | 52% | ok | 73% |
| 4K60（在 1440p 補幀） | 34% | 35% | ok | 32% |

階梯機制會自動選取在你的電腦上能滿速運行的最高階層。

## 解除安裝

安裝程式會寫入以下檔案；請將它們刪除：

- `%APPDATA%\mpv\mpv.conf`、`input.conf` 以及資料夾 `scripts-adaptive`、`vs`、`shaders`（若有備份，可從 `%APPDATA%\mpv\backup-<date>\` 還原你先前的設定檔）
- 若已安裝 mpv.net，刪除 `%APPDATA%\mpv.net\` 中相同的這兩個 `.conf` 檔案
- `%LOCALAPPDATA%\mpv-adaptive-enhance` 與桌面的 **Play in mpv** 捷徑
- 學習紀錄資料：`%APPDATA%\mpv\adaptive-cache.json` 與 `ytdl-adaptive.json`

若你在其他地方不需要使用這些軟體，可執行 `winget uninstall shinchiro.mpv` 移除程式（同理亦可移除 `yt-dlp.yt-dlp`、`DenoLand.Deno` 與 Python），並執行 `py -3.13 -m pip uninstall vapoursynth` 移除 VapourSynth。安裝程式可能也已將 Python 與 VapourSynth 資料夾加入你的使用者 PATH 環境變數中。

## 授權條款

本儲存庫本身的檔案（腳本、`.vpy`、設定檔、安裝程式、說明文件）採用 [MIT 授權條款](LICENSE)。下方列出的組件皆未包含在此儲存庫中；安裝程式會由各自的作者來源下載：

| 組件 | 作者 | 授權條款 |
|---|---|---|
| [mpv](https://mpv.io) (shinchiro build) | mpv 開發者 | GPL-2.0+ / LGPL-2.1+ |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | yt-dlp 貢獻者 | Unlicense |
| [VapourSynth](https://github.com/vapoursynth/vapoursynth) | Fredrik Mellbin | LGPL-2.1 |
| [vapoursynth-mvtools](https://github.com/dubhater/vapoursynth-mvtools) v29_2 | dubhater et al. | GPL-2.0 |
| [VapourSynth-RIFE-ncnn-Vulkan](https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan) r9_mod_v33 + rife-v4.6 model | HolyWu, styler00dollar; RIFE by hzwer | MIT |
| [KrigBilateral](https://gist.github.com/igv/a015fc885d5c22e6891820ad89555637) | igv | LGPL-3.0 |
| [adaptive-sharpen](https://gist.github.com/igv/8a77e4eb8276753b54bb94c1c50c317e) | bacondither (port: igv) | BSD-2-Clause |
| [CAS / CAS-scaled](https://gist.github.com/agyild/bbb4e58298b2f86aa24da3032a0d2ee6) | AMD (port: agyild) | MIT |
| [CfL_Prediction](https://github.com/Artoriuz/glsl-chroma-from-luma-prediction) | Artoriuz | MIT |
| [ArtCNN](https://github.com/Artoriuz/ArtCNN) | Artoriuz, Kacper Michajłow | MIT |
| [ravu-zoom-ar-r3](https://github.com/bjin/mpv-prescalers) | bjin | LGPL-3.0 |

**mvtools.dll** 附於此儲存庫的 Releases 發行版本中。它是透過 GitHub Actions ([`.github/workflows/mvtools.yml`](.github/workflows/mvtools.yml))，以原作者上游 v29_2 原始碼加上 [`third_party/mvtools`](third_party/mvtools) 中的兩個微小修正檔（僅修正建置問題：靜態連結與一個 mingw 編譯錯誤）編譯而成，因此與上游相同採用 GPL-2.0 授權。原作者上游提供的 Windows 二進位檔為 v24，現行版本的 VapourSynth 無法載入。若想自行編譯，請參閱 [`third_party/mvtools/build-mvtools.sh`](third_party/mvtools/build-mvtools.sh)。

未使用 SVP 的 svpflow 函式庫：其授權在 Windows 上需要付費的 SVP 4 Pro 授權。
