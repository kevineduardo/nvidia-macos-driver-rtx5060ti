#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# narrow_check.sh: a 10-bit stream read as 8-bit NV12 through AVFoundation ($LIB injected) against FFmpeg's 10-bit software
# decode rounded the same way ((v + 2) >> 2, at most 255). Must print 0 differing samples.
source "$(dirname "$0")/env.sh"
[ -x "$WORK/avread" ] || { xcrun swiftc -O -o "$WORK/avread" "$HERE/avread.swift" && codesign -s - -f "$WORK/avread"; }
for f in av1-4k-10bit.mp4 vp9-10bit.mp4 hevc-10bit-bframes.mp4; do
  NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 DYLD_INSERT_LIBRARIES=$LIB "$WORK/avread" "$WORK/vectors/$f" 8 "$WORK/out/$f.nv12" 2>&1 | grep "out:"
  "$FFMPEG" -hide_banner -v error -y -i "$WORK/vectors/$f" -pix_fmt yuv420p10le -f rawvideo "$WORK/out/$f.p10"
  WH=$("$FFMPEG" -hide_banner -i "$WORK/vectors/$f" 2>&1 | grep -o -E '[0-9]{2,5}x[0-9]{2,5}' | head -1)
  python3 -I "$HERE/narrow_compare.py" "$WORK/out/$f.p10" "$WORK/out/$f.nv12" $WH
done
