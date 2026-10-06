# mvfps.vpy - cheap motion-compensated frame interpolation for mpv (MVTools, CPU).
#
# Block-matching motion vectors (the same family as SVP's svpflow, which needs a paid
# SVP 4 Pro licence on Windows) instead of RIFE's neural network: far cheaper per generated
# frame, at the cost of occasional halos/warping on fast or occluded motion.
#
# Plugin: vapoursynth-mvtools v29_2, built 2026-10-07 from source with MSYS2 mingw64
# (statically linked; the only Windows binary upstream ships is v24, an API3 build that
# VapourSynth R81 refuses).
#
# adaptive-enhance.lua writes "<target fps> <mode>" to mv_target_<pid>.txt before adding the
# filter, because mpv cannot pass arguments to a .vpy. mode: "flow" (pixel-wise FlowFPS,
# better) or "block" (BlockFPS, cheaper). No file -> flow, x2.

import os
import vapoursynth as vs

core = vs.core

clip = video_in
src_fps = container_fps if container_fps and container_fps > 0 else 24.0

target, mode = src_fps * 2, "flow"
try:
    here = os.path.expandvars(r"%APPDATA%\mpv\vs")
    with open(os.path.join(here, "mv_target_%d.txt" % os.getpid())) as f:
        parts = f.read().split()
        target = float(parts[0])
        if len(parts) > 1:
            mode = parts[1]
except Exception:
    pass

clip = core.std.AssumeFPS(clip, fpsnum=int(round(src_fps * 1000)), fpsden=1000)

if target > src_fps * 1.05 and clip.width > 2560:
    # Above the panel's 1440p, motion search on full 4K is too slow for the CPU (2026-10-07:
    # BlockFPS 4K30 -> 90 played at 60% speed). The picture is shown at <= 1440p anyway, so
    # interpolate at that size; mpv's own scaler then has nothing left to downscale.
    h = round(clip.height * 2560 / clip.width / 2) * 2
    clip = core.resize.Spline36(clip, 2560, h)

if target > src_fps * 1.05:
    # 1080p and up: 16x16 blocks with half overlap; smaller sources get 8x8.
    blk = 16 if clip.width >= 1280 else 8
    sup = core.mv.Super(clip, pel=1, hpad=blk, vpad=blk, sharp=1, rfilter=2)
    bv = core.mv.Analyse(sup, isb=True, blksize=blk, overlap=blk // 2, search=3, truemotion=True)
    fv = core.mv.Analyse(sup, isb=False, blksize=blk, overlap=blk // 2, search=3, truemotion=True)
    num, den = int(round(target * 1000)), 1000
    if mode == "block":
        clip = core.mv.BlockFPS(clip, sup, bv, fv, num=num, den=den, mode=3, thscd1=400, thscd2=130)
    else:
        clip = core.mv.FlowFPS(clip, sup, bv, fv, num=num, den=den, mask=2, thscd1=400, thscd2=130)

clip.set_output()
