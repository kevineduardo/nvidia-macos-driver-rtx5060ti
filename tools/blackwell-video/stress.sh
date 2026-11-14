#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# stress.sh [runs]: AVFoundation (AVAssetReader, asynchronous decompression) decodes with $LIB injected and the installed
# libnvencvt kept out (NVMTL_NVENCVT=0 for this process). A run fails when the reader stops before the end; "late" counts
# pictures chan_wait had to ring the doorbell again for. This is what found the lost submissions (see the doc).
source "$(dirname "$0")/env.sh"
[ -x "$WORK/avread" ] || { xcrun swiftc -O -o "$WORK/avread" "$HERE/avread.swift" && codesign -s - -f "$WORK/avread"; }
for t in "av1-4k-10bit-long.mp4 8" "av1-4k-10bit-long.mp4 10" "av1-4k-8bit-long.mp4 8" "vp9-1080p-long.mp4 8" "h264-4k-long.mp4 8" \
         "hevc-4k-8bit-long.mp4 8" "hevc-4k-10bit-long.mp4 10" "hevc-4k-10bit-long.mp4 8"; do
  set -- $t; ok=0; fail=0; late=0; fps=""
  for i in $(seq ${RUNS:-15}); do
    full=$(NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 DYLD_INSERT_LIBRARIES=$LIB "$WORK/avread" "$WORK/vectors/$1" $2 2>&1)
    o=$(echo "$full" | grep "out:"); late=$((late + $(echo "$full" | grep -c "semaphore .* late")))
    if echo "$o" | grep -q "status 2"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    fps="$fps $(echo "$o" | grep -o '[0-9]* fps' | cut -d' ' -f1)"
  done
  echo "$1 ($2-bit out): ok=$ok fail=$fail late=$late  fps:$fps"
done
