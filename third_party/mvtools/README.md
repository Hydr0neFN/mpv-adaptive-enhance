# mvtools.dll build

[vapoursynth-mvtools](https://github.com/dubhater/vapoursynth-mvtools) (GPL-2.0) tag `v29_2`,
built for 64-bit Windows with MSYS2 mingw64. The release binary is produced by
[`.github/workflows/mvtools.yml`](../../.github/workflows/mvtools.yml) running
[`build-mvtools.sh`](build-mvtools.sh); you can run the same script locally.

| Patch | Why |
|---|---|
| `0001-meson-static-windows.patch` | Use VapourSynth headers from `vsinclude/` (downloaded by the script, tag R81) instead of querying a Python install; link fftw3f, libgcc and libstdc++ statically so the DLL depends only on `KERNEL32.dll` and `msvcrt.dll`; drop the Python-based install step. |
| `0002-mvdepan-std-isfinite.patch` | `isfinite` -> `std::isfinite` in `src/MVDepan.cpp` (mingw g++ compile error). |

Neither patch changes what the plugin computes. Upstream source for the exact build:
<https://github.com/dubhater/vapoursynth-mvtools/tree/v29_2> plus these two patches.
