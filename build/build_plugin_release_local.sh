#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# build_plugin_release_local.sh <git-rev> <out-dir>: the release NVMTLDriver from plugin/ at <git-rev>, built on THIS Mac
# with build_plugin_release.sh's compile line (that script builds on the build host over ssh). Needs the Xcode command
# line tools and the Vulkan headers of Mesa at nvk/MESA_BASE, fetched once into $NVMTL_BUILD_ROOT/mesa-include
# (default ~/nvmtl-build).
# It reproduces the shipped binary: commit e2feb6b built this way has the LC_UUID of the plugin installed from it
# (8AE4C48A-B067-3F9C-A618-73A698064803; command line tools 26.5, ld-1267). Check that on your tools before trusting a
# build of your own change: an equal UUID for an unchanged commit means any difference is your change.
# Install the result with tools/install_bundle_file.sh <out-dir>/NVMTLDriver NVMTLDriver.
set -euo pipefail
REV=${1:?git revision}; OUT=${2:?output directory}
HERE=$(cd "$(dirname "$0")/.." && pwd); ROOT=${NVMTL_BUILD_ROOT:-$HOME/nvmtl-build}
INC=$ROOT/mesa-include
if [ ! -d "$INC/include/vulkan" ]; then
  mkdir -p "$ROOT"
  git clone -q --filter=blob:none --no-checkout https://gitlab.freedesktop.org/mesa/mesa.git "$INC"
  git -C "$INC" sparse-checkout set include; git -C "$INC" checkout -q "$(cat "$HERE/nvk/MESA_BASE")"
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git -C "$HERE" archive "$REV" plugin | tar x -C "$TMP"
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
( cd "$TMP/plugin" && xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 \
    -Wno-protocol -Wno-incomplete-implementation -Werror=unguarded-availability-new \
    -I"$INC/include" -o "$OUT/NVMTLDriver" NVMTLDevice.m nvmtl_dlss.c dlss/elfhost.c dlss/lnxlibc.c \
    -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation -framework MetalFX -liconv 2>"$OUT/build.err" ) \
  || { grep ' error:' "$OUT/build.err" | head -20; exit 1; }
bash "$HERE/build/warn_ceiling.sh" plugin "$(grep -c ': warning:' "$OUT/build.err" || true)" "$OUT/build.err" || exit 4
minos=$(vtool -show-build "$OUT/NVMTLDriver" | awk '/minos/{print $2; exit}')
[ "$minos" = 15.0 ] || { echo "STOP: minos $minos, not 15.0"; exit 1; }
echo "NVMTLDriver $(git -C "$HERE" rev-parse --short "$REV") uuid $(otool -l "$OUT/NVMTLDriver" | awk '/uuid/{print $2; exit}') sha $(shasum -a 256 "$OUT/NVMTLDriver" | cut -c1-8) minos $minos warnings $(grep -c ': warning:' "$OUT/build.err" || true)"
