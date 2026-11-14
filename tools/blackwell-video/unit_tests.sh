#!/bin/bash
# unit_tests.sh: the plane copies, sample by sample, without a GPU: gob_untile_plane's whole-tile path for the Blackwell
# layouts and gob_untile_plane_narrow (16-bit samples to 8-bit), against gob_offset and the scalar rounding, at sizes with
# and without partial tiles (up to 8K)
set -euo pipefail
source "$(dirname "$0")/env.sh"
SRC=$ROOT/vendor/nvenc/src
for t in untile_test narrow_test; do
  xcrun clang -O2 -Wall -I"$SRC" -o "$WORK/$t" "$HERE/$t.c" "$SRC/blocklinear.c" -framework Accelerate
  "$WORK/$t"
done
