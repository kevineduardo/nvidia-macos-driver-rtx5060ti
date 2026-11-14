#!/bin/bash
# cmp.sh <vector> [nv12|p010le]: framemd5 of a hardware decode (VideoToolbox, $LIB injected into ffmpeg) against FFmpeg's
# software decode. Prints frames on each side and how many hardware frames differ (0 = bit-exact). The log of the
# hardware run (NVENCVT_LOG=1) is $WORK/out/<vector>.log; NVDEC_GOB=turing|blackwell overrides the plane layout.
source "$(dirname "$0")/env.sh"
V=$1; F=${2:-nv12}; SWF=$([ "$F" = p010le ] && echo yuv420p10le || echo yuv420p); T=$WORK/out; b=$(basename "$V")
perl -e 'alarm 120; exec @ARGV' "$FFMPEG" -hide_banner -y -v error -i "$V" -map 0:v:0 -pix_fmt $SWF -f framemd5 "$T/$b.sw" 2>/dev/null
DYLD_INSERT_LIBRARIES=$LIB NVENCVT_LOG=1 perl -e 'alarm 120; exec @ARGV' "$FFMPEG" -hide_banner -y -v error -hwaccel videotoolbox \
  -hwaccel_output_format videotoolbox_vld -i "$V" -map 0:v:0 -vf hwdownload,format=$F,format=$SWF -f framemd5 "$T/$b.hw" 2>"$T/$b.log"; rc=$?
n=$(grep -vc '^#' "$T/$b.sw"); h=$(grep -vc '^#' "$T/$b.hw" 2>/dev/null)
bad=$(diff <(grep -v '^#' "$T/$b.sw" | awk -F, '{print $NF}') <(grep -v '^#' "$T/$b.hw" | awk -F, '{print $NF}') | grep -c '^>')
printf "%-34s rc=%-3s frames sw=%-4s hw=%-4s mismatched=%s\n" "$b" $rc $n $h $bad
