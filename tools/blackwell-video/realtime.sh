#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# realtime.sh <clip> [streams] [seconds] [fps]: plays a clip in REAL TIME with AVPlayer, as a screen saver or a player does
# (pictures are dropped when the decoder cannot keep up), `streams` at once (2: a screen saver on two monitors), with
# $LIB injected and the installed libnvencvt kept out. For each stream: how many pictures were shown, the steps between
# them (in 1/fps s; even steps are a steady cadence, a mix of small and large ones is judder), how many differ from
# the software decode of the picture with that time, the decoder's CPU time, and where the pacing (nvdec_pace.h) went.
#   CLOSED=1    NullMoth's closed HEVC decoder instead of $LIB
#   any NVDEC_* setting in the environment reaches the decoder (NVDEC_NO_PACE=1, NVDEC_COPY_THREADS=n)
# The clip must be short enough to decode to a reference (8 s of 4K 240 fps is 1924 pictures):
#   ffmpeg -i aerial.mov -map 0:v:0 -c copy -t 8 $WORK/vectors/aerial-clip.mov
set -uo pipefail
source "$(dirname "$0")/env.sh"
V=${1:?clip}; N=${2:-1}; SECS=${3:-7.5}; b=$(basename "$V")
INFO=$("$FFMPEG" -hide_banner -i "$V" 2>&1 || true)     # ffmpeg exits 1 without an output: not through a pipe under pipefail
FPS=${4:-$(sed -n 's/.* \([0-9.]*\) fps.*/\1/p' <<<"$INFO" | head -1)}
bits=8; fmt=nv12; case $INFO in *yuv4[0-9][0-9]p1[02]*) bits=10; fmt=p010le ;; esac
[ -x "$WORK/avplay" ] || { xcrun swiftc -O -o "$WORK/avplay" "$HERE/avplay.swift" && codesign -s - -f "$WORK/avplay"; }
REF=$WORK/out/$b.subrow.ref
if [ ! -s "$REF" ]; then
  WH=$(grep -o -E '[0-9]{3,5}x[0-9]{3,5}' <<<"$INFO" | head -1)
  "$FFMPEG" -hide_banner -v error -i "$V" -map 0:v:0 -fps_mode passthrough -pix_fmt $fmt -f rawvideo - | python3 "$HERE/subrow_md5.py" ${WH%x*} ${WH#*x} $bits > "$REF"
fi
for i in $(seq $N); do
  ( if [ -n "${CLOSED-}" ]; then NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 /usr/bin/time -l "$WORK/avplay" "$V" $SECS $bits > "$WORK/out/rt-$i.txt" 2> "$WORK/out/rt-$i.log"
    else NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 NVENCVT_LOG=1 DYLD_INSERT_LIBRARIES=$LIB /usr/bin/time -l "$WORK/avplay" "$V" $SECS $bits > "$WORK/out/rt-$i.txt" 2> "$WORK/out/rt-$i.log"; fi ) &
done; wait
for i in $(seq $N); do
  echo "stream $i: $(python3 "$HERE/playcmp.py" "$REF" "$WORK/out/rt-$i.txt" $FPS) | $(grep -E ' real ' "$WORK/out/rt-$i.log" | awk '{printf "cpu %.1f s in %.1f s", $3+$5, $1}')"
  grep -E "per frame:" "$WORK/out/rt-$i.log" | sed 's/nvdecvt: /  /' | cut -c1-200 | tail -1
  grep -E "pace: now|pace: not" "$WORK/out/rt-$i.log" | sed 's/nvdecvt: /  /' | cut -c1-120 | head -6
done
