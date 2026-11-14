#!/bin/bash
# fetch_vectors.sh: the libvpx / AV1 conformance vectors and the generated streams the other scripts use, into $WORK/vectors
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$WORK/vectors"
V=https://storage.googleapis.com/downloads.webmproject.org/test_data/libvpx
A=https://storage.googleapis.com/aom-test-data
for f in vp90-2-00-quantizer-00.webm vp90-2-02-size-130x132.webm vp90-2-08-tile-4x4.webm vp92-2-20-10bit-yuv420.webm; do [ -s $f ] || curl -fsSL -o $f $V/$f; done
for f in av1-1-b8-01-size-16x16.ivf av1-1-b8-01-size-66x66.ivf av1-1-b8-02-allintra.ivf av1-1-b8-03-sizeup.mkv av1-1-b10-00-quantizer-00.ivf av1-1-b8-22-svc-L2T2.ivf; do [ -s $f ] || curl -fsSL -o $f $A/$f; done
g() { out=$1; shift; [ -s "$out" ] || "$FFMPEG" -hide_banner -v error -y "$@" "$out"; }
src() { echo "-f lavfi -i testsrc2=size=$1:rate=${2:-30}"; }
g gen-vp9-intra.webm    $(src 640x360) -frames:v 30 -c:v libvpx-vp9 -g 1 -b:v 2M -deadline realtime -cpu-used 8
g gen-vp9-inter.webm    $(src 640x360) -frames:v 30 -c:v libvpx-vp9 -g 300 -b:v 2M -deadline realtime -cpu-used 8
g gen-vp9-inter-er.webm $(src 640x360) -frames:v 30 -c:v libvpx-vp9 -g 300 -error-resilient 1 -b:v 2M -deadline realtime -cpu-used 8
g gen-vp9-4k.webm       $(src 3840x2160) -frames:v 20 -c:v libvpx-vp9 -g 300 -b:v 20M -deadline realtime -cpu-used 8 -row-mt 1 -tile-columns 2
g vp9-1080p-long.webm   $(src 1920x1080 60) -frames:v 400 -c:v libvpx-vp9 -g 600 -b:v 8M -deadline realtime -cpu-used 8 -row-mt 1 -tile-columns 2
g gen-av1-inter.mkv     $(src 1280x720) -frames:v 60 -c:v libsvtav1 -preset 10 -g 120
g gen-av1-4k-10bit.mkv  $(src 3840x2160) -frames:v 30 -pix_fmt yuv420p10le -c:v libsvtav1 -preset 12 -g 120
g av1-4k-8bit-long.mp4  $(src 3840x2160 60) -frames:v 240 -c:v libsvtav1 -preset 12 -g 240
g av1-4k-10bit-long.mp4 $(src 3840x2160 60) -frames:v 240 -pix_fmt yuv420p10le -c:v libsvtav1 -preset 12 -g 240
g gen-h264-inter.mp4    $(src 640x360) -frames:v 30 -c:v libx264 -g 300 -bf 0 -pix_fmt yuv420p
g h264-4k-long.mp4      $(src 3840x2160 60) -frames:v 240 -c:v libx264 -preset ultrafast -bf 0 -pix_fmt yuv420p
g gen-hevc-inter.mp4    $(src 640x360) -frames:v 30 -c:v libx265 -x265-params log-level=error:bframes=0 -tag:v hvc1 -pix_fmt yuv420p
# AVFoundation reads MP4, not WebM / IVF
for f in gen-vp9-4k vp9-1080p-long; do g $f.mp4 -i $f.webm -c copy; done
g vp9-10bit.mp4 -i vp92-2-20-10bit-yuv420.webm -c copy
g av1-4k-10bit.mp4 -i gen-av1-4k-10bit.mkv -c copy
ls -1 | wc -l | xargs echo "vectors in $WORK/vectors:"
