#!/bin/bash
# validate.sh: everything that checked Blackwell VP9 / AV1 decode, in order. Needs FFMPEG (see env.sh) and an RTX 50 card
# for the GPU steps; the first two need neither.
#   1 static checks of the source (tools/test_nvencvt_blackwell.py) and the parsers under the sanitizer harness
#   2 unit tests of the plane copies
#   3 build of the library from this tree
#   4 vectors, then the bit-exact matrix through ffmpeg (synchronous)
#   5 AVFoundation stress (asynchronous) and the 8-bit narrowing check
set -uo pipefail
source "$(dirname "$0")/env.sh"
step() { echo; echo "== $*"; }
step "1 static checks"; python3 "$ROOT/tools/test_nvencvt_blackwell.py" | tail -1
bash "$HERE/build_local.sh" "$LIB" >/dev/null && NVDEC_HEADERS=$WORK/hdr/ogd/classes/video python3 "$ROOT/tools/test_nvenc_parsers.py" | tail -1
step "2 unit tests"; bash "$HERE/unit_tests.sh" | awk '{print} /FAIL/{f=1} END{print f ? "UNIT FAIL" : "unit ok"}' | tail -1
step "3 build"; bash "$HERE/build_local.sh" "$LIB"
command -v "$FFMPEG" >/dev/null || { echo "no ffmpeg ($FFMPEG): stopping before the GPU steps"; exit 0; }
step "4 bit-exact matrix"; bash "$HERE/fetch_vectors.sh" && bash "$HERE/matrix.sh"
step "5 AVFoundation"; bash "$HERE/stress.sh"; bash "$HERE/narrow_check.sh"
