#!/bin/bash
# trace_closed_push.sh <hevc.mp4>: runs ffmpeg under lldb with NullMoth's closed HEVC decoder registered (closed_hevc_shim)
# and dumps the process's data regions at nvd265_close; then push_decode.py finds and prints the NVDEC method stream.
# This is how method 0x4dc was found. FFMPEG must carry com.apple.security.get-task-allow (re-sign it with an entitlements
# plist holding that key) for lldb to attach.
set -euo pipefail
source "$(dirname "$0")/env.sh"
IN=${1:?an HEVC mp4 (fetch_vectors.sh makes gen-hevc-inter.mp4)}; OUTD=$WORK/trace; rm -rf "$OUTD"; mkdir -p "$OUTD"
xcrun clang -arch x86_64 -dynamiclib -o "$WORK/libshim.dylib" "$HERE/closed_hevc_shim.c" -framework CoreFoundation
codesign -s - -f "$WORK/libshim.dylib" >/dev/null 2>&1
TRACE_OUT=$OUTD perl -e 'alarm 280; exec @ARGV' xcrun lldb --batch \
  -o "command script import $HERE/trace_closed_push.py" \
  -o "settings set target.env-vars DYLD_INSERT_LIBRARIES=$WORK/libshim.dylib" \
  -o "breakpoint set -n nvd265_close -s libnvdec_hevc.dylib" -o "breakpoint command add -F trace_closed_push.on_close 1" \
  -o "process launch -o /dev/null -e /dev/null -- -hide_banner -y -v error -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld -i $IN -frames:v 3 -vf hwdownload,format=nv12 -f null -" \
  "$FFMPEG" | grep -E "regions|error" || true
python3 -I "$HERE/push_decode.py" "$OUTD" "$WORK/hdr/ogd/classes/video/clc9b0.h"
