# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
# env.sh: sourced by the scripts here. Override any of these in the environment.
#   WORK     scratch folder (headers, vectors, outputs)         default: $TMPDIR/nvencvt-bench
#   FFMPEG   an ffmpeg with -hwaccel videotoolbox, libvpx, libaom/libsvtav1, libx264/5 (a static macOS x86_64 build;
#            re-sign it ad hoc - `codesign -s - -f ffmpeg` - so DYLD_INSERT_LIBRARIES reaches it)
#   LIB      the libnvencvt.dylib under test                     default: $WORK/libnvencvt.dylib
#            Its path must contain "nvencvt": the library registers itself only when DYLD_INSERT_LIBRARIES names it so
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-${TMPDIR:-/tmp}/nvencvt-bench}
FFMPEG=${FFMPEG:-ffmpeg}
LIB=${LIB:-$WORK/libnvencvt.dylib}
mkdir -p "$WORK/out" "$WORK/vectors"
