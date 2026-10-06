# yt-mpv.ps1 - play a video URL (YouTube or any yt-dlp site) or local video files in mpv.
# Source order: arguments (URLs or files dragged onto the shortcut) -> clipboard (URL or
# copied file path) -> input box.
# Enhancement (shaders / interpolation / stream resolution) is chosen live by
# %APPDATA%\mpv\scripts-adaptive\*.lua, identically for streams and local files.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Items)

# mpv.exe (shinchiro), not mpv.net: 2026-10-06 the VapourSynth RIFE plugin (rife-ncnn-vulkan)
# freezes mpv.net's process at "vapoursynth initializing..." every time - with hwdec on,
# off or copy-back - while the same filter runs in mpv.exe. A passthrough .vpy is fine in
# both, so it is the RIFE plugin inside mpv.net, not VapourSynth itself.
$mpv = @("$env:ProgramFiles\MPV Player\mpv.exe",
         (Get-Command mpv.exe -ErrorAction SilentlyContinue).Source,
         "$env:LOCALAPPDATA\Programs\mpv.net\mpvnet.exe") |
       Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $mpv) { throw "mpv not found - run install.ps1 first" }

function Resolve-Item([string]$s) {
    if (-not $s) { return $null }
    $s = $s.Trim().Trim('"')
    if ($s -match '^(https?://|www\.)\S+$') {
        if ($s -notmatch '^https?://') { $s = "https://$s" }
        return $s
    }
    if (Test-Path -LiteralPath $s -PathType Leaf) { return (Resolve-Path -LiteralPath $s).Path }
    return $null
}

$targets = @($Items | ForEach-Object { Resolve-Item $_ } | Where-Object { $_ })

if (-not $targets) {
    try {
        $files = Get-Clipboard -Format FileDropList -ErrorAction Stop
        if ($files) { $targets = @($files | ForEach-Object { Resolve-Item $_.FullName } | Where-Object { $_ }) }
    } catch {}
}
if (-not $targets) {
    try { $t = Resolve-Item (Get-Clipboard -Raw); if ($t) { $targets = @($t) } } catch {}
}
if (-not $targets) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $t = Resolve-Item ([Microsoft.VisualBasic.Interaction]::InputBox(
        "Paste a video URL (YouTube, Twitch, Vimeo, direct link...) or a local file path",
        "Play in mpv", ""))
    if ($t) { $targets = @($t) }
}
if (-not $targets) { exit }

# mpv never writes video to disk (cache-on-disk=no: stream data lives in RAM and is freed
# when the window closes). The only thing that accumulates is libplacebo's compiled-shader
# cache (%LOCALAPPDATA%\mpv\cache, tens of MB after heavy use). Entries
# untouched for 30 days are stale shader variants; mpv rebuilds anything it still needs.
try {
    Get-ChildItem "$env:LOCALAPPDATA\mpv\cache" -File -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
} catch {}

Start-Process -FilePath $mpv -ArgumentList ($targets | ForEach-Object { '"' + $_ + '"' })
