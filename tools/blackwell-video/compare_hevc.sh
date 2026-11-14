#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# compare_hevc.sh [runs]: libnvencvt's HEVC decoder ($LIB, NVENCVT_BLACKWELL_ALL_DEC=1) against NullMoth's closed one
# (libnvdec_hevc through closed_hevc_shim / the plugin) under the same conditions: ffmpeg (synchronous; it asks for
# OpenGL-compatible buffers), AVFoundation (asynchronous) at 4K 8-bit, 10-bit as P010 and as NV12, 1080p, 4:4:4, and how
# many of the runs finish. Prints fps per run.
source "$(dirname "$0")/env.sh"
RUNS=${1:-5}
[ -x "$WORK/avread" ] || { xcrun swiftc -O -o "$WORK/avread" "$HERE/avread.swift" && codesign -s - -f "$WORK/avread"; }
[ -f "$WORK/libshim.dylib" ] || { xcrun clang -arch x86_64 -dynamiclib -o "$WORK/libshim.dylib" "$HERE/closed_hevc_shim.c" -framework CoreFoundation && codesign -s - -f "$WORK/libshim.dylib"; }
ff() {   # ff <inject> <vector>: ffmpeg hardware decode to memory, fps
  local s=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())')
  local n=$(DYLD_INSERT_LIBRARIES=$1 NVENCVT_BLACKWELL_ALL_DEC=1 "$FFMPEG" -hide_banner -v error -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld \
    -i "$2" -vf hwdownload,format=$3 -f framemd5 - 2>/dev/null | grep -vc '^#')
  python3 -c "import time;print(f'{$n/(time.time()-$s):.0f}')"
}
av() {   # av <ours|closed> <vector> <8|10>: AVAssetReader; prints fps or FAIL
  local o
  if [ $1 = ours ]; then o=$(NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 NVENCVT_BLACKWELL_ALL_DEC=1 DYLD_INSERT_LIBRARIES=$LIB "$WORK/avread" "$2" $3 2>&1 | grep "out:")
  else o=$(NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 "$WORK/avread" "$2" $3 2>&1 | grep "out:"); fi
  echo "$o" | grep -q "status 2" && echo "$o" | grep -o '[0-9]* fps' | cut -d' ' -f1 || echo FAIL
}
V=$WORK/vectors
for t in "hevc-4k-8bit-long.mp4 nv12" "hevc-4k-10bit-long.mp4 p010le" "hevc-1080p-mandel.mp4 nv12"; do set -- $t
  a=""; b=""; for i in $(seq $RUNS); do a="$a $(ff $LIB $V/$1 $2)"; b="$b $(ff $WORK/libshim.dylib $V/$1 $2)"; done
  printf "ffmpeg       %-26s ours:%s | closed:%s\n" "$1" "$a" "$b"
done
for t in "hevc-4k-8bit-long.mp4 8" "hevc-4k-10bit-long.mp4 10" "hevc-4k-10bit-long.mp4 8" "hevc-1080p-mandel.mp4 8" "hevc-444.mp4 8"; do set -- $t
  a=""; b=""; for i in $(seq $RUNS); do a="$a $(av ours $V/$1 $2)"; b="$b $(av closed $V/$1 $2)"; done
  printf "AVFoundation %-26s %2s-bit out  ours:%s | closed:%s\n" "$1" "$2" "$a" "$b"
done
