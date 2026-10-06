# rife.vpy - realtime frame interpolation for mpv (RIFE, ncnn/Vulkan)
#
# Measured 2026-08-29 on an RX 9070 XT. Steady-state delayed frames per second of
# playback (first 5s excluded), 15s clips, FSRCNNX + KrigBilateral + deband active:
#
#   source 1080p, x2 (24->48)        0.0/s   <- the only clean configuration
#   source 1080p, x3 (24->72)       12.4/s
#   source 1080p, x4 (24->96)       16.0/s
#   source 1080p, x2 (60->120)      16.0/s
#   source 1440p, x2 (24->48)       15.9/s
#   source 1440p downscaled to      15.4/s   <- downscaling first does NOT help
#     1080p inside this script, x2
#
# The last row is the important one: the RIFE workload there is identical to the
# clean 1080p row, yet it stutters. The cost is not RIFE - it is mpv's VapourSynth
# bridge round-tripping every frame through system memory at SOURCE resolution
# before this script can touch it. Resizing here happens after that copy, so it
# cannot buy anything back.
#
# 2026-10-05: the hard size/fps gate that used to live here was removed. Whether a
# source can be interpolated is now decided live by scripts-adaptive/adaptive-enhance.lua,
# which adds this filter, measures drops / output rate, removes it again if the
# machine cannot keep up, and remembers that per source+display combination.
# That replaces fixed limits that were measured on the old 1080p144 panel.

import vapoursynth as vs

core = vs.core

# install.ps1 puts the model next to the plugin: <site-packages>/vapoursynth/plugins/models/
import os
MODEL = os.path.join(os.path.dirname(vs.__file__), "plugins", "models", "rife-v4.6_ensembleFalse")
GPU_THREAD  = 2      # was 4 (fastest); lowered 2026-10-06 after a GPU watchdog reset during a RIFE seek storm

clip = video_in
src_fps = container_fps if container_fps and container_fps > 0 else 24.0

# Target fps (2026-10-07): adaptive-enhance.lua picks a target aligned to the refresh
# rate (180/90/60/30 on a 180 Hz panel) and writes it to rife_target_<pid>.txt next to this
# script, because mpv cannot pass arguments to a .vpy. Missing file -> plain x2.
import os
target = None
try:
    here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else \
        os.path.expandvars(r"%APPDATA%\mpv\vs")
    with open(os.path.join(here, "rife_target_%d.txt" % os.getpid())) as f:
        target = float(f.read().strip())
except Exception:
    target = None

if True:
    num = int(round(src_fps * 1000))
    clip = core.std.AssumeFPS(clip, fpsnum=num, fpsden=1000)
    clip = core.resize.Bicubic(clip, format=vs.RGBS, matrix_in_s="709")
    if target and target > src_fps * 1.05:
        clip = core.rife.RIFE(clip, model_path=MODEL,
                              fps_num=int(round(target * 1000)), fps_den=1000,
                              gpu_id=0, gpu_thread=GPU_THREAD, sc=False)
    else:
        clip = core.rife.RIFE(clip, model_path=MODEL,
                              factor_num=2, factor_den=1,
                              gpu_id=0, gpu_thread=GPU_THREAD, sc=False)
    # 4:4:4 out - re-subsampling to 4:2:0 would discard chroma that
    # KrigBilateral downstream cannot reconstruct a second time.
    clip = core.resize.Bicubic(clip, format=vs.YUV444P10, matrix_s="709")

clip.set_output()
