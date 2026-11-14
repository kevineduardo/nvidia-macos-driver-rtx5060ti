#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# matrix.sh: cmp.sh over every vector that must be bit-exact on Blackwell (run fetch_vectors.sh first)
source "$(dirname "$0")/env.sh"
for v in vp90-2-00-quantizer-00.webm vp90-2-02-size-130x132.webm vp90-2-08-tile-4x4.webm gen-vp9-intra.webm gen-vp9-inter.webm \
         gen-vp9-inter-er.webm gen-vp9-4k.webm vp92-2-20-10bit-yuv420.webm vp9-1080p-long.webm av1-1-b8-02-allintra.ivf \
         av1-1-b8-22-svc-L2T2.ivf gen-av1-inter.mkv av1-1-b10-00-quantizer-00.ivf gen-av1-4k-10bit.mkv av1-4k-8bit-long.mp4 \
         av1-4k-10bit-long.mp4 gen-h264-inter.mp4; do
  f=nv12; case $v in *b10*|*10bit*) f=p010le;; esac
  bash "$HERE/cmp.sh" "$WORK/vectors/$v" $f
done | awk '{print} $NF != "mismatched=0" {bad++} END {print (bad ? "SOME MISMATCH" : "ALL BIT-EXACT")}'
echo "-- HEVC (generated and JCT-VC conformance; on Blackwell libnvencvt's HEVC decoder)"
for v in "$WORK"/vectors/gen-hevc-inter.mp4 "$WORK"/vectors/hevc-*.mp4 "$WORK"/vectors/hevc-conf/*.bi[tn]; do
  case $v in *-long.mp4|*hevc-444*) continue;; esac   # long ones are for stress.sh; 4:4:4 needs a 4:4:4 client format
  bash "$HERE/cmp.sh" "$v"
done | awk '{print} $NF != "mismatched=0" {bad++} END {print (bad ? "SOME HEVC MISMATCH" : "HEVC ALL BIT-EXACT")}'
# Expected elsewhere (not Blackwell-specific, see mickys/nvenc docs/tasks.md T9.03 / T9.04): AV1 under 128x128 is refused
# (software decode instead), and av1-1-b8-03-sizeup through ffmpeg differs after the size change (ffmpeg's side).
