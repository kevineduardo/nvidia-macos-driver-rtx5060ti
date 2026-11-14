#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# test.sh <real ffmpeg> <vectors dir>: shows the problem and the fix with the installed driver's libnvencvt, from this
# folder (nothing needs to be installed). For each stream: plain ffmpeg -hwaccel videotoolbox, then the same command
# through the ffmpeg wrapper; reports whether libnvencvt's decoder ran (NVENCVT_LOG "instance") and whether every frame
# matches FFmpeg's software decode. A plain run with 0 frames is the problem itself: no hardware frames came out (the
# session fell back to software, or for AV1 failed). Vectors: tools/blackwell-video/fetch_vectors.sh ($WORK/vectors).
set -uo pipefail
FF=${1:?the real ffmpeg}; V=${2:?vectors dir}; HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/real" "$T/wrap"; ln -s "$FF" "$T/real/ffmpeg"; ln -s "$HERE/shim" "$T/wrap/ffmpeg"
fails=0
run() {   # run <label> <PATH> <vector>
  local f=$3 fmt=nv12 info; info=$("$FF" -hide_banner -i "$f" 2>&1 || true)
  case $info in *yuv4[0-9][0-9]p1[02]*) fmt=p010le ;; esac
  local swf=$([ $fmt = p010le ] && echo yuv420p10le || echo yuv420p)
  "$FF" -nostdin -y -hide_banner -v error -i "$f" -map 0:v:0 -pix_fmt $swf -f framemd5 "$T/sw" 2>/dev/null
  PATH=$2 NVENC_RUN=$HERE/nvenc-run NVENCVT_LOG=1 ffmpeg -nostdin -y -hide_banner -v error -hwaccel videotoolbox \
    -hwaccel_output_format videotoolbox_vld -i "$f" -map 0:v:0 -vf hwdownload,format=$fmt,format=$swf -f framemd5 "$T/hw" 2>"$T/log"
  local inst=$(grep -c 'nvdecvt: instance' "$T/log") n=$(grep -vc '^#' "$T/sw") h=$(grep -vc '^#' "$T/hw")
  local bad=$(diff <(grep -v '^#' "$T/sw" | awk -F, '{print $NF}') <(grep -v '^#' "$T/hw" | awk -F, '{print $NF}') | grep -c '^[<>]')
  printf "%-8s %-28s our decoder: %-3s frames %s/%s  differing lines %s\n" "$1" "$(basename "$f")" \
    "$([ "$inst" -gt 0 ] && echo yes || echo no)" "$h" "$n" "$bad"
  [ "$1" = wrapped ] && { [ "$inst" -gt 0 ] && [ "$h" = "$n" ] && [ "$bad" = 0 ] || fails=$((fails+1)); }
}
for f in "$V/gen-av1-inter.mkv" "$V/gen-vp9-inter.webm" "$V/hevc-8bit-bframes.mp4" "$V/hevc-10bit-bframes.mp4" "$V/gen-h264-inter.mp4"; do
  [ -f "$f" ] || { echo "missing $f"; continue; }
  run plain "$T/real:/usr/bin:/bin" "$f"
  run wrapped "$T/wrap:$T/real:/usr/bin:/bin" "$f"
done
"$HERE/nvenc-run" --check "$FF" | sed 's/^/check: /'
[ $fails = 0 ] && echo "PASS: every wrapped run used libnvencvt and matched the software decode" || { echo "FAIL: $fails"; exit 1; }
