<#
.SYNOPSIS
    Installs mpv-adaptive-enhance for the current Windows user.

.DESCRIPTION
    1. winget: mpv (shinchiro build), yt-dlp, Deno (yt-dlp needs it for YouTube), Python 3.13
    2. pip: VapourSynth, registered for mpv and put on the user PATH
    3. VapourSynth plugins: MVTools (motion interpolation) and, unless -SkipRife, RIFE + model
    4. Shaders, downloaded from their upstream authors (not bundled - mixed licences)
    5. mpv.conf / input.conf / scripts / .vpy files into %APPDATA%\mpv (old files backed up)
    6. A "Play in mpv" desktop shortcut (URL from the clipboard, or drop files on it)

    Safe to re-run: it updates in place and backs up any config it replaces.
    No administrator rights needed.

.PARAMETER SkipRife
    Do not install the RIFE plugin (~5 MB) and model. RIFE is off by default anyway.

.PARAMETER MvtoolsDll
    Use a local mvtools.dll instead of downloading the release build.

.PARAMETER NoShortcut
    Do not create the desktop shortcut.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipRife,
    [string]$MvtoolsDll,
    [switch]$NoShortcut
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with the progress bar

$Repo    = 'Hydr0neFN/mpv-adaptive-enhance'
$Src     = $PSScriptRoot
# The scripts resolve everything from %APPDATA%\mpv, so this location is fixed.
$MpvDir  = Join-Path $env:APPDATA 'mpv'
$AppDir  = Join-Path $env:LOCALAPPDATA 'mpv-adaptive-enhance'

$Shaders = [ordered]@{
    'KrigBilateral.glsl'       = 'https://gist.githubusercontent.com/igv/a015fc885d5c22e6891820ad89555637/raw/KrigBilateral.glsl'
    'adaptive-sharpen.glsl'    = 'https://gist.githubusercontent.com/igv/8a77e4eb8276753b54bb94c1c50c317e/raw/adaptive-sharpen.glsl'
    'CAS.glsl'                 = 'https://gist.githubusercontent.com/agyild/bbb4e58298b2f86aa24da3032a0d2ee6/raw/CAS.glsl'
    'CAS-scaled.glsl'          = 'https://gist.githubusercontent.com/agyild/bbb4e58298b2f86aa24da3032a0d2ee6/raw/CAS-scaled.glsl'
    'CfL_Prediction.glsl'      = 'https://raw.githubusercontent.com/Artoriuz/glsl-chroma-from-luma-prediction/main/CfL_Prediction.glsl'
    'CfL_Prediction_Lite.glsl' = 'https://raw.githubusercontent.com/Artoriuz/glsl-chroma-from-luma-prediction/main/CfL_Prediction_Lite.glsl'
    'ArtCNN_C4F16.glsl'        = 'https://raw.githubusercontent.com/Artoriuz/ArtCNN/main/GLSL/ArtCNN_C4F16.glsl'
    'ArtCNN_C4F16_DN.glsl'     = 'https://raw.githubusercontent.com/Artoriuz/ArtCNN/main/GLSL/ArtCNN_C4F16_DN.glsl'
    'ravu-zoom-ar-r3.hook'     = 'https://raw.githubusercontent.com/bjin/mpv-prescalers/master/ravu-zoom-ar-r3.hook'
}
$RifeDll   = 'https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan/releases/download/r9_mod_v33/librife_windows_x86-64.dll'
$RifeModel = 'https://raw.githubusercontent.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan/master/models/rife-v4.6_ensembleFalse'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    ! $msg" -ForegroundColor Yellow }

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Invoke-Native([scriptblock]$cmd) {
    # Run a native command with stderr discarded. Under Windows PowerShell 5.1 with
    # ErrorActionPreference=Stop, "2>$null" alone still turns stderr into a terminating error.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $cmd 2>$null } finally { $ErrorActionPreference = $old }
}

function Get-File($url, $dest) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing; return }
        catch { if ($i -eq 3) { throw "download failed (check the internet connection / proxy): $url" }; Start-Sleep 2 }
    }
}

function Install-Winget($id, $name, [string]$override) {
    $listed = Invoke-Native { winget list --id $id --exact --accept-source-agreements } | Select-String -SimpleMatch $id
    if ($listed) { Ok "$name already installed"; return }
    Write-Host "    installing $name ..."
    $wargs = @('install', '--id', $id, '--exact', '--silent', '--scope', 'user',
              '--accept-package-agreements', '--accept-source-agreements')
    if ($override) { $wargs += @('--override', $override) }
    winget @wargs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # some packages have no per-user installer; retry without forcing the scope
        $wargs = $wargs | Where-Object { $_ -notin '--scope', 'user' }
        winget @wargs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "winget could not install $name ($id), exit $LASTEXITCODE" }
    }
    Ok "$name installed"
}

function Find-Python {
    # 3.12+ via the py launcher, else a per-user python.org install, else python.exe on PATH
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in '3.13', '3.12', '3.14') {
            $exe = Invoke-Native { & py "-$v" -c 'import sys; print(sys.executable)' }
            if ($LASTEXITCODE -eq 0 -and $exe) { return $exe.Trim() }
        }
    }
    $cands = @(Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python31[2-4]\python.exe" -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | ForEach-Object FullName)
    $cands += @(Get-Command python.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source |
                Where-Object { $_ -notmatch 'WindowsApps' })   # skip the Store alias stub
    foreach ($exe in $cands) {
        $ok = Invoke-Native { & $exe -c 'import sys; print(sys.version_info >= (3, 12))' }
        if ($ok -eq 'True') { return $exe }
    }
    return $null
}

function Add-UserPath([string[]]$dirs) {
    # Read and write the raw registry value so %VAR% entries stay unexpanded (REG_EXPAND_SZ).
    $key  = Get-Item 'HKCU:\Environment'
    $raw  = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $have = @(($raw + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')) -split ';' | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
    $add  = @($dirs | Where-Object { $have -notcontains $_.TrimEnd('\') })
    if (-not $add) { return @() }
    $new = (@($raw.TrimEnd(';')) + $add | Where-Object { $_ }) -join ';'
    Set-ItemProperty 'HKCU:\Environment' -Name Path -Value $new -Type ExpandString
    return $add
}

function Write-Utf8NoBom($path, $text) {
    # Windows PowerShell 5.1's "-Encoding utf8" adds a BOM; keep config files plain UTF-8.
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------------------
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Only 64-bit x86 Windows is supported.' }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
}
foreach ($d in 'config', 'scripts', 'vs', 'launcher') {
    if (-not (Test-Path (Join-Path $Src $d))) { throw "Run install.ps1 from the repository folder ($d\ missing)." }
}

Step 'Programs (winget)'
Install-Winget 'shinchiro.mpv'  'mpv (shinchiro build)'
Install-Winget 'yt-dlp.yt-dlp'  'yt-dlp'
Install-Winget 'DenoLand.Deno'  'Deno'
$py = Find-Python
if (-not $py) {
    Install-Winget 'Python.Python.3.13' 'Python 3.13' '/quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1'
    Update-SessionPath
    $py = Find-Python
    if (-not $py) { throw 'Python was installed but "py -3.13" does not run. Open a new terminal and re-run.' }
} else { Ok "Python found: $py" }
Update-SessionPath

Step 'VapourSynth (pip)'
& $py -m pip install --upgrade --disable-pip-version-check --quiet vapoursynth
if ($LASTEXITCODE -ne 0) { throw 'pip install vapoursynth failed' }
$vsDir     = (& $py -c 'import os, vapoursynth; print(os.path.dirname(vapoursynth.__file__))').Trim()
$pluginDir = Join-Path $vsDir 'plugins'
New-Item -ItemType Directory -Force $pluginDir | Out-Null
# mpv finds VSScript through these registry entries ...
& $py -m vapoursynth register-install        | Out-Null
& $py -m vapoursynth register-legacy-install | Out-Null
# ... but still crashes ~3 s into playback, with no error, unless the VapourSynth folder is
# also on PATH (its DLLs load their neighbours by name).
$added = Add-UserPath @((Split-Path $py), $vsDir)
if ($added) { Update-SessionPath; Ok "added to user PATH: $($added -join ', ')" }
Ok "VapourSynth at $vsDir"

Step 'VapourSynth plugins'
$mvDest = Join-Path $pluginDir 'mvtools.dll'
if ($MvtoolsDll) {
    Copy-Item $MvtoolsDll $mvDest -Force
} else {
    try {
        Get-File "https://github.com/$Repo/releases/latest/download/mvtools.dll" $mvDest
    } catch {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            # private repository / no anonymous access: use the logged-in GitHub CLI
            gh release download --repo $Repo --pattern mvtools.dll --dir $pluginDir --clobber
            if ($LASTEXITCODE -ne 0) { throw 'could not download mvtools.dll (gh release download failed)' }
        } else {
            throw ("could not download mvtools.dll from the $Repo releases. If the repository is private, " +
                   "install the GitHub CLI and run 'gh auth login', then re-run; or build it with " +
                   "third_party\mvtools and pass -MvtoolsDll <path>.")
        }
    }
}
Ok 'MVTools (motion interpolation)'
if (-not $SkipRife) {
    Get-File $RifeDll (Join-Path $pluginDir 'librife.dll')
    $m = Join-Path $pluginDir 'models\rife-v4.6_ensembleFalse'
    New-Item -ItemType Directory -Force $m | Out-Null
    foreach ($f in 'flownet.param', 'flownet.bin') { Get-File "$RifeModel/$f" (Join-Path $m $f) }
    Ok 'RIFE + rife-v4.6 model (off by default; Ctrl+r or the Tab menu to try it)'
}
$probe = & $py -c "import vapoursynth as vs; c = vs.core; print('mv' if hasattr(c, 'mv') else '-', 'rife' if hasattr(c, 'rife') else '-')"
if ($probe -notmatch '^mv') { Warn "VapourSynth did not load MVTools ($probe) - motion interpolation will be unavailable" }
elseif (-not $SkipRife -and $probe -notmatch 'rife') { Warn 'VapourSynth did not load RIFE (needs a Vulkan GPU driver)' }

Step 'Shaders'
$shDir = Join-Path $MpvDir 'shaders'
New-Item -ItemType Directory -Force $shDir | Out-Null
foreach ($k in $Shaders.Keys) { Get-File $Shaders[$k] (Join-Path $shDir $k) }
Ok "$($Shaders.Count) shaders -> $shDir"

Step 'mpv configuration'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fwd   = $MpvDir -replace '\\', '/'
function Install-Conf($dir, [string]$extra) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($n in 'mpv.conf', 'input.conf') {
        $dest = Join-Path $dir $n
        $new  = (Get-Content (Join-Path $Src "config\$n") -Raw) -replace '@MPV_DIR@', $fwd
        if ($n -eq 'mpv.conf' -and $extra) { $new += "`r`n$extra`r`n" }
        if (Test-Path $dest) {
            if ((Get-Content $dest -Raw) -eq $new) { continue }
            $bak = Join-Path $dir "backup-$stamp"
            New-Item -ItemType Directory -Force $bak | Out-Null
            Copy-Item $dest $bak
            Ok "previous $n saved to $bak"
        }
        Write-Utf8NoBom $dest $new
    }
}
Install-Conf $MpvDir
foreach ($pair in @(@('scripts', 'scripts-adaptive'), @('vs', 'vs'))) {
    $d = Join-Path $MpvDir $pair[1]
    New-Item -ItemType Directory -Force $d | Out-Null
    Copy-Item (Join-Path $Src "$($pair[0])\*") $d -Force
}
Ok "config, scripts and .vpy files -> $MpvDir"
if (Test-Path (Join-Path $env:APPDATA 'mpv.net')) {
    # mpv.net reads its own folder. The RIFE plugin freezes mpv.net, so RIFE stays off there.
    Install-Conf (Join-Path $env:APPDATA 'mpv.net') 'script-opts-append=adaptive_enhance-rife=off'
    Ok 'mpv.net found: same config written to %APPDATA%\mpv.net (RIFE disabled there)'
}

Step 'Launcher'
New-Item -ItemType Directory -Force $AppDir | Out-Null
$launcher = Join-Path $AppDir 'play-in-mpv.ps1'
Copy-Item (Join-Path $Src 'launcher\play-in-mpv.ps1') $launcher -Force
if (-not $NoShortcut) {
    $mpvExe = @((Join-Path $env:ProgramFiles 'MPV Player\mpv.exe'),
                (Get-Command mpv.exe -ErrorAction SilentlyContinue).Source) |
              Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Play in mpv.lnk'
    $sh  = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sh.TargetPath   = (Get-Command powershell.exe).Source
    $sh.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
    if ($mpvExe) { $sh.IconLocation = "$mpvExe,0" }
    $sh.Description  = 'Play a URL from the clipboard, or video files dropped on this icon, in mpv'
    $sh.Save()
    Ok "desktop shortcut: $lnk"
}

Step 'Done'
Write-Host @"
    Open any video with mpv, or copy a YouTube link and double-click "Play in mpv".
    Press Tab in the player for the menu. The first 15-40 s of a new kind of video are
    spent measuring what your GPU can sustain; the result is remembered.
    If VapourSynth was just installed, sign out and back in once so mpv sees the new PATH.
"@
