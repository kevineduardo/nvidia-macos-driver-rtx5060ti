# Blackwell video decode: test bench

The tests that validated hardware VP9 / AV1 decode (and the libnvencvt H.264 decoder) on an RTX 50 card. What was found
and why is in [docs/BLACKWELL-VIDEO-DECODE.md](../../docs/BLACKWELL-VIDEO-DECODE.md).

## Setup

- A static **ffmpeg** for macOS x86_64 with `-hwaccel videotoolbox`, libvpx, libsvtav1, libx264 and libx265 (e.g. the
  martin-riedl.de builds). Re-sign it ad hoc (`codesign -s - -f ffmpeg`) so `DYLD_INSERT_LIBRARIES` reaches it, and point
  `FFMPEG` at it.
- `WORK` (default `$TMPDIR/nvencvt-bench`) holds the headers, the vectors and the outputs.
- `LIB` (default `$WORK/libnvencvt.dylib`) is the library under test; `build_local.sh` makes it from this tree.

The library under test is **injected** (`DYLD_INSERT_LIBRARIES`), so nothing is installed to test it. In AVFoundation runs
the installed copy is kept out of the process with `NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0`; otherwise two decoders with the
same rating are registered and VideoToolbox picks either. The injected library registers itself only when its path
contains "nvencvt" (`libx.dylib` loads and silently does nothing; VideoToolbox then uses another decoder). In zsh, put such variables on the command line itself: a `$VAR`
holding several `A=B` words is not split.

## Installing a build

`tools/install_bundle_file.sh $WORK/libnvencvt.dylib libnvencvt.dylib` (signs that file only, seals the bundle without
`--deep`, stops if anything else in it changed). Never `codesign --deep` the installed bundle: see
[docs/SHADER-CACHE-TAG.md](../../docs/SHADER-CACHE-TAG.md) for the two-minute black screen that caused.

## Running

```sh
export FFMPEG=/path/to/ffmpeg
tools/blackwell-video/validate.sh           # everything, in order
```

or one step at a time:

| script | checks | pass |
|---|---|---|
| `../test_nvencvt_blackwell.py` | the source: registration policy, method 0x4dc, setup fields, layouts, GPPut read-back, chan_wait, narrowing | `all passed` |
| `unit_tests.sh` | the Blackwell plane copies and the 16->8-bit narrowing, sample by sample, sizes up to 8K (no GPU) | every line `ok` |
| `build_local.sh [out]` | builds libnvencvt as `build/build_nvencvt.sh` does (exports, minos 15.0) on this Mac | `warnings: 0` |
| `fetch_vectors.sh` | downloads the libvpx / AV1 conformance vectors, generates the other streams | |
| `matrix.sh` | `cmp.sh` on every vector: framemd5 of the hardware decode vs FFmpeg's software decode, then HEVC (generated and 17 JCT-VC conformance streams) | `ALL BIT-EXACT`, `HEVC ALL BIT-EXACT` |
| `cmp.sh <vector> [p010le]` | one vector; the hardware run's log is `$WORK/out/<vector>.log` | `mismatched=0` |
| `psnr.sh <vector>` | per-frame PSNR, to tell garbage (a layout or setup error, ~10 dB) from a near miss | |
| `stress.sh` | AVAssetReader (asynchronous) x15 per stream: AV1 4K 8/10-bit, VP9 1080p, H.264 4K, HEVC 4K 8/10-bit | `fail=0 late=0` |
| `narrow_check.sh` | 10-bit read as 8-bit NV12 vs the software decode rounded the same way | `differing samples 0` |
| `compare_hevc.sh [runs]` | our HEVC decoder against NullMoth's closed one, same streams, ffmpeg and AVFoundation | see the doc's table |
| `swift vt_hw_check.swift` | what VideoToolbox reports as hardware in a process with a Metal device (the installed driver) | all `true` |
| `trace_closed_push.sh <hevc.mp4>` | dumps and decodes the NVDEC methods NullMoth's closed HEVC decoder sends (how 0x4dc was found) | |
| `macho_segcmp.py a b label` | the same code apart from the signature (re-signed vs rebuilt) | |

Results on an RTX 5060 Ti, macOS 26.7.2 (2026-11-14): matrix all bit-exact; stress 75/75 with no late picture;
narrowing 0 differing samples. AVFoundation throughput: AV1 4K 8-bit 138-148 fps, AV1 4K 10-bit 82 fps (P010) / 93 fps
(narrowed to NV12), VP9 4K ~140-160 fps, VP9 1080p ~700 fps, H.264 4K ~100 fps.

Expected exceptions (not Blackwell-specific; mickys/nvenc docs/tasks.md T9.03 / T9.04): AV1 under 128x128 is refused
(software decode instead); `av1-1-b8-03-sizeup` through ffmpeg differs after the size change (ffmpeg keeps its session).

---
Copyright (c) 2026 kevineduardo. Licensed under the MIT License (SPDX-License-Identifier: MIT).
