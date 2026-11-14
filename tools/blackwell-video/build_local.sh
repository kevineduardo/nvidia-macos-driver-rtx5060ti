#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# build_local.sh [out.dylib]: libnvencvt.dylib from vendor/nvenc on THIS Mac, with the same flags and checks as
# build/build_nvencvt.sh (which builds on the build host). The pinned headers are fetched once into $WORK/hdr.
# NVENC_DEBUG=1 adds -g. The result is not installed; see README.md for installing it.
set -euo pipefail
source "$(dirname "$0")/env.sh"
OUT=${1:-$LIB}; H=$WORK/hdr; mkdir -p "$H"
fetch() { d=$1; u=$2; r=$3; shift 3
  [ -d "$H/$d/.git" ] || { git clone -q --filter=blob:none --no-checkout "$u" "$H/$d"; git -C "$H/$d" sparse-checkout set "$@"; }
  git -C "$H/$d" fetch -q --tags origin; git -C "$H/$d" checkout -q "$r"; }
fetch ogkm https://github.com/NVIDIA/open-gpu-kernel-modules.git 610.57.04 src/common/sdk/nvidia/inc src/nvidia/arch/nvalloc/unix/include
fetch ogd https://github.com/NVIDIA/open-gpu-doc.git 9fdf5c4062007929d9f4e6cbad9c9771fe61b880 classes/video
mkdir -p "$H/webkit-spi"
for f in CMBaseObjectSPI.h VTVideoDecoderSPI.h; do
  [ -s "$H/webkit-spi/$f" ] || curl -fsSL -o "$H/webkit-spi/$f" "https://raw.githubusercontent.com/WebKit/WebKit/3bfbc200370710495ffa440abdd31b943c83ad7a/Source/ThirdParty/libwebrtc/Source/webrtc/webkit_sdk/WebKit/$f"
done
VER="$(git -C "$ROOT" describe --tags --always --dirty)-local"
G=; [ -n "${NVENC_DEBUG:-}" ] && G=-g
cd "$ROOT/vendor/nvenc"
xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -O2 $G -Wall -fvisibility=hidden -dynamiclib -DNVENC_VERSION="\"$VER\"" \
  -o "$OUT" vt/nvencvt.c vt/nvencvt_dec.c src/*.c -I src -I "$H/webkit-spi" \
  -I "$H/ogkm/src/common/sdk/nvidia/inc" -I "$H/ogkm/src/nvidia/arch/nvalloc/unix/include" -I "$H/ogd/classes/video" \
  -Werror=unguarded-availability-new \
  -framework IOKit -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  -framework Accelerate -framework IOSurface 2>"$OUT.err" || { grep ' error:' "$OUT.err" | head -20; exit 1; }
want="_NVDecVT_CreateInstance _NVEncVT_CreateInstance _NVEncVT_Register _NVEncVT_RegisterDecoders"
have=$(nm -gU "$OUT" | awk '{print $3}' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$have" = "$want" ] || { echo "STOP: exports are [$have], want [$want]"; exit 1; }
minos=$(vtool -show-build "$OUT" | awk '/minos/{print $2; exit}'); [ "$minos" = 15.0 ] || { echo "STOP: minos $minos"; exit 1; }
echo "built $OUT ($VER), warnings: $(grep -c ': warning:' "$OUT.err" || true)"
