#!/bin/bash
# psnr.sh <vector> [nv12|p010le]: per-frame luma PSNR of the hardware decode against the software one: min / average and
# the frames under 99 dB. For telling a layout or setup error (garbage, ~10 dB) from a small one.
source "$(dirname "$0")/env.sh"
V=$1; F=${2:-nv12}; SWF=$([ "$F" = p010le ] && echo yuv420p10le || echo yuv420p); b=$(basename "$V"); O=$WORK/out
"$FFMPEG" -hide_banner -y -v error -i "$V" -map 0:v:0 -pix_fmt $SWF -f rawvideo "$O/$b.sw.yuv"
DYLD_INSERT_LIBRARIES=$LIB perl -e 'alarm 120; exec @ARGV' "$FFMPEG" -hide_banner -y -v error -hwaccel videotoolbox -hwaccel_output_format videotoolbox_vld \
  -i "$V" -map 0:v:0 -vf hwdownload,format=$F,format=$SWF -f rawvideo "$O/$b.hw.yuv" 2>/dev/null
WH=$("$FFMPEG" -hide_banner -i "$V" 2>&1 | grep -o -E '[0-9]{2,5}x[0-9]{2,5}' | head -1)
"$FFMPEG" -hide_banner -v error -s $WH -pix_fmt $SWF -f rawvideo -i "$O/$b.hw.yuv" -s $WH -pix_fmt $SWF -f rawvideo -i "$O/$b.sw.yuv" \
  -lavfi "psnr=stats_file=$O/$b.psnr" -f null -
awk -v b="$b" '{for(i=1;i<=NF;i++) if($i ~ /^psnr_y:/){split($i,a,":"); v=a[2]; if(v=="inf")v=99; n++; s+=v; if(min==""||v<min)min=v; if(v<99) bad=bad" "n-1":"int(v)}}
  END{printf "%-30s frames %d  minY %.1f avgY %.1f  [%s]\n", b, n, min, s/n, substr(bad,1,120)}' "$O/$b.psnr"
