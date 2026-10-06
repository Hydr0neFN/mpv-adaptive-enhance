#!/usr/bin/env bash
# Build a self-contained mvtools.dll (vapoursynth-mvtools v29_2) for 64-bit Windows.
#
# Run in an MSYS2 MINGW64 shell with:
#   pacman -S --needed git mingw-w64-x86_64-gcc mingw-w64-x86_64-meson \
#     mingw-w64-x86_64-ninja mingw-w64-x86_64-nasm mingw-w64-x86_64-pkgconf mingw-w64-x86_64-fftw
#
# Why build at all: upstream's only Windows binary is v24 (VapourSynth API 3), which
# VapourSynth R7x+ refuses to load. The two patches in patches/ make the build use
# downloaded VapourSynth headers instead of a Python install, link fftw3f/libgcc/libstdc++
# statically (the DLL then imports only KERNEL32 and msvcrt), and fix one std::isfinite
# compile error under mingw.
#
# Usage: ./build-mvtools.sh [output-dir]      (default: ./out)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "${1:-$HERE/out}")
MVTOOLS_TAG=v29_2
VS_TAG=R81

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch "$MVTOOLS_TAG" \
    https://github.com/dubhater/vapoursynth-mvtools.git "$WORK/mvtools"
cd "$WORK/mvtools"
git apply "$HERE"/patches/*.patch

mkdir vsinclude
for h in VapourSynth4.h VSHelper4.h VSConstants4.h; do
    curl -fsSL "https://raw.githubusercontent.com/vapoursynth/vapoursynth/$VS_TAG/include/$h" -o "vsinclude/$h"
done

meson setup build --buildtype=release
ninja -C build

mkdir -p "$OUT"
cp build/mvtools.dll "$OUT/"
echo "Built $OUT/mvtools.dll; imports:"
objdump -p "$OUT/mvtools.dll" | grep 'DLL Name'
