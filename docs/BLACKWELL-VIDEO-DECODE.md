# Hardware VP9 and AV1 decode on Blackwell (RTX 50)

State on 2026-11-14, RTX 5060 Ti (GB206, NVDEC class `0xcfb0`), macOS 26.7.2, NullMoth 3.0 plus this branch.

| codec | decoder on Blackwell | state |
|---|---|---|
| H.264 | libnvencvt (rating 1100, above the built-in `libnvdec_h264` at 1000) | bit-exact |
| HEVC 8/10-bit, 4:4:4 | libnvencvt (rating 1100, above the built-in closed `libnvdec_hevc`) | bit-exact, incl. 17 JCT-VC conformance streams |
| VP9 8/10-bit | libnvencvt | bit-exact, incl. 4x4 tiles, error resilient, 4K |
| AV1 8/10-bit | libnvencvt | bit-exact, incl. SVC, 4K 10-bit |

libnvencvt registers on Blackwell only where the plugin loads it: `NVMTL_NVENCVT=1` in
`/Library/GPUBundles/nvmtl/nvrm610.conf` (the plugin's automatic choice is Ada and Ampere only). Tests and how to run
them: [tools/blackwell-video](../tools/blackwell-video/README.md).

## What Blackwell needs beyond Ada's NVDEC

No public header lists the methods of class `0xcfb0` (`clcfb0.h` in open-gpu-kernel-modules names the class alone). Ada's
(`clc9b0.h`) work, with these additions (`vendor/nvenc/src/nvdec_blackwell.h`):

1. **Method `0x4dc`**: the address (>> 8) of a buffer the engine uses for inter pictures, `ceil(width / 128) + 1` units
   of 16 KB. Without it every picture that predicts from a reference (VP9, AV1, HEVC; not H.264) ends in a channel error
   (notifier `0xffff`) while intra pictures decode bit-exact.
2. **Picture setup fields** (as NVIDIA's driver fills them for CFB0):
   - the decoded planes' GOB kinds, `luma | chroma << 2` (8-bit samples 9, 16-bit 2), and a surface format code
     (0 / 3 / 6 for 8 / 10 / 12-bit). With them the engine writes the **Blackwell plane layouts** (blocklinear.h:
     Blackwell8Bit / Blackwell16Bit; Mesa NIL's names); without them it writes the Turing layout, intra pictures still
     come out right, and inter prediction (tiles, 10-bit) reads wrong samples.
     VP9: `reserved5` = kinds, `reserved1[2]` = format code. AV1: `reserved_stat` = kinds | code << 4.
     HEVC: `reserved6` = kinds, `reserved7` = format code + chroma format (4:2:0 0, 4:4:4 2).
   - a word after the structure with the 0x4dc units: VP9 at `+0x108`, AV1 at `+0x244`, HEVC at `+0x11c`.
   - AV1: `reserved12` (`+0x54`) = `0xffff`; HEVC: `0xffff` at `+0x120`.
   With these kinds HEVC also writes the Blackwell layouts by element size (the AROS driver, which fills the kinds
   otherwise, reads HEVC in the 32-bit order; with ours that order is wrong on every picture).

H.264 needs none of it: its pictures come out in the Blackwell layout with Ada's setup.

### Where the facts come from

- The methods NullMoth's closed HEVC decoder sends on this card, read from its push buffer
  (`tools/blackwell-video/trace_closed_push.sh`): every Ada method plus `0x4dc`, pointing past its intra-top area, in a
  filter buffer its verbose log describes (`NVD265_VERBOSE=1`: "... intra 2534400 4dc 2599936").
- The same method, sizes and setup values in three independent projects that traced NVIDIA's driver on CFB0: the AROS
  nvgfx driver (`workbench/hidds/nvgfx/nvgfx_decode_{vp9,av1,hevc}.c`, `NVDEC_BLK_UNITS`), cagedbird043/nvrm
  (`src/video/av1/desc.rs`: "Without it every inter frame reports error_status 0xd") and tinygrad (`ops_nv.py`, HEVC).
  Only the values were taken, no code.

## Two channel problems Blackwell exposed

Both are in `vendor/nvenc/src/channel.c` and affect every decoder there.

1. **The push buffer was never reused.** `chan_rewind` started over when GPGet reached GPPut, but Blackwell's channel class
   (`c96f`) reports no GPGet: VP9 and AV1 (which, unlike `dec.c`, did not call `chan_done`) filled the 64 KB after about
   200 pictures and stopped. They now call `chan_done` after each completion, and the buffer wraps once half used rather
   than after every picture, as NullMoth's own decoders advance through theirs (0x200 per picture).
2. **Lost submissions.** Under AVFoundation's asynchronous decoding a picture now and then never ran: the semaphore stayed
   at the previous picture's value for 5 s more, no channel error. Ringing the doorbell again made it run at once, so the
   host had read the old GPPut: USERD is video memory behind a write-combined BAR mapping, and the fence does not make
   that posted write arrive before the doorbell's. Reading GPPut back before the doorbell: 0 lost pictures in 9600 (7
   without). `chan_wait` also rings the doorbell again for a picture 50 ms late, logging it ("semaphore N late"); in the
   tests it never had to.

## 10-bit streams for 8-bit clients

A client that asks for 8-bit NV12 from a 10-bit VP9 / AV1 stream (AVAssetReader, transcoders) got 10-bit buffers that
VideoToolbox then converted, 63 ms per 4K picture (16 fps). The picture is now narrowed while it is untiled
(`gob_untile_plane_narrow`, `(v + 0x80) >> 8` saturating), the client gets its own format and VideoToolbox converts
nothing: 93 fps, identical to the software decode rounded the same way. `NVDEC_NONARROW=1` restores the old path.

## Our HEVC decoder against NullMoth's closed one

Both bit-exact on the same 23 streams (6 generated, 17 JCT-VC conformance). Throughput (`tools/blackwell-video/compare_hevc.sh`,
5 runs each, fps):

| path | stream | ours | closed |
|---|---|---|---|
| ffmpeg (IINA, mpv: OpenGL-compatible buffers) | 4K 8-bit | ~48 | ~15 |
| ffmpeg | 1080p | ~127 | ~64 |
| ffmpeg | 4K 10-bit | ~26 | ~27 |
| AVFoundation | 4K 8-bit | ~120-130 | ~146 |
| AVFoundation | 4K 10-bit (P010) | ~72 | ~73 |
| AVFoundation | 4K 10-bit read as NV12 | ~80 | ~15 |
| AVFoundation | 1080p | ~490 | ~455 |
| AVFoundation | 4:4:4 640x360 | ~67 | ~68 |

The closed decoder hands out buffers with fixed attributes, which VideoToolbox copies when the client asks for others
(ffmpeg's OpenGL-compatible ones; 8-bit for 10-bit); ours makes them to the client's attributes. Its engine is faster per
picture at 4K 8-bit (3.5 ms against ~6 ms; not explained: not the surfaces' memory, which in video memory made our CPU
copy 100 ms, and not the buffers it sets that we do not). Neither failed in 20 AVFoundation runs (the closed one once in
an earlier set of 10). Ours is rated above it on Blackwell.

## Real-time playback of streams the decoder cannot keep up with

Apple's aerial screen savers are HEVC Main 10, 3840x2160, **240 fps**, five temporal sub-layers (per 16 pictures: 1, 1,
2, 4, 8). A picture costs the engine 8 ms and the copy out 10 ms; real time gives 4 ms, and the screen saver plays one
stream per monitor. With NullMoth's closed decoder and with ours the result was judder: the player dropped pictures by
itself, showing two pictures 1/120 s apart and then jumping 1/15 s, over and over, and `WallpaperAerialsExtension`
used 3.6 cores. Nothing was decoded wrong: every picture shown matched the software decode.

What was found, with `tools/blackwell-video/realtime.sh` (AVPlayer in real time, each picture shown compared with the
software decode of the picture with that time):

- VideoToolbox sets **no quality-of-service property** on a third-party decoder (it asks once for
  `SuggestedQualityOfServiceTiers` and nothing else). Frames come with `kVTDecodeFrame_1xRealTimePlayback` in
  playback and without it in preroll, AVAssetReader and ffmpeg. So the decoder paces itself (`vt/nvdec_pace.h`):
  in real time it measures the cost of a picture against the stream's pictures per second in each sub-layer and leaves
  out the sub-layers it cannot afford, which HEVC allows and which leaves evenly spaced pictures. Down at once; up after
  1.5 s of room, at a TSA / STSA picture or an IRAP only; a step up that fails doubles the wait before the next (two
  streams on one engine otherwise went up together and fell back every two seconds). `NVDEC_NO_PACE=1` turns it off.
- The client's pixel format comes as a **list** (even of one): the decoder took a list for "not my format", used the
  session's pool and VideoToolbox converted every picture. It now finds its format in the list.
- `kVTDecodeFrame_DoNotOutputFrame` pictures are decoded and not copied out.
- **The copy out used every core**: one block per 16-row band on a concurrent queue. The copy is bound by memory: one
  4K 10-bit luma plane took 2.1 ms on one thread (2.1 ms of CPU) and 2.2 ms on all of them (22 ms of CPU). Now two
  threads, one each when more than one session decodes in the process (`NVDEC_COPY_THREADS`).
- Sleeping instead of spinning while the engine works was tried and is worse here: `nanosleep` on that thread comes
  back milliseconds late (8 ms pictures took 11 to 21).

| real time, aerial clip | pictures shown / s | steps between pictures (1/240 s) | CPU |
|---|---|---|---|
| closed decoder, 1 stream | 27 | half 2, half 16 | 3.3 cores |
| ours before, 1 stream | 28 | half 2, half 16 | 3.6 cores |
| ours now, 1 stream | 62 | 4 (397 of 425) | 1 to 1.5 cores |
| closed decoder, 2 streams | 26 + 27 | half 2, half 16 | 3.4 cores each |
| ours now, 2 streams | ~30 + ~30 | 8 (about 9 in 10), some 16 | 1 core each |

Two 4K streams cannot both run at 60 pictures a second on this card: 120 pictures of 8 ms are all of the one NVDEC
engine's time. Open: the 16-steps left with two streams, and the first seconds, before the pace settles.

### Two sessions in one process

`realtime.sh` runs one process per stream; the screen saver runs both players in one. With two players in one process
(`tools/blackwell-video/avplay2.swift`) about one start in three ended in software decoding (seven cores busy, 10
pictures a second): `startSession: HEVC 0x0 (coded 0x0), 0-bit, chroma -1 - NOT SUPPORTED`. The H.264 and HEVC parsers
kept their bit reader in a `static` (8 KB, to stay off the stack), so two sessions parsing at once read each other's
bytes: a parameter set at session start, or a slice header later (`hevcdec: slice header parse failed`). The readers,
the AV1 tile list and film-grain scratch, and the other function statics are now `_Thread_local`
(`tools/test_nvencvt_blackwell.py` refuses a new shared one). 12 starts of two players in a row, none failed.

Tried and not kept: non-temporal stores in the copy out (pictures shown +3%, CPU -5% with two streams, inside the run
to run spread). The spin in `chan_wait` now pauses between reads (`_mm_pause`), which leaves the engine wait's
timing as it was.

### Pictures in video memory, read out through the copy engine (HEVC)

The decoders allocated their pictures in system memory, so that the CPU could read them. NVDEC then reads every
reference block and writes every output block across the bus. Measured on 4K HEVC (`NVENCVT_LOG=1`, "per frame"):

| pictures in | engine, 10-bit | copy out, 10-bit | total | engine, 8-bit | total, 8-bit |
|---|---|---|---|---|---|
| system memory (`NVDEC_VIDMEM=0`) | 8.5 ms | 5.0 ms | 13.8 ms | 5.0 ms | 7.9 ms |
| video memory, read through the BAR mapping | 1.9 ms | 697 ms | 700 ms | | |
| video memory + copy engine (default on Blackwell) | 1.5 ms | 8.4 ms (3.5 copy engine + the untile) | 10.2 ms | 1.5 ms | 6.0 ms |

The CPU cannot read video memory (no mapping cache mode changes that), so `src/cecopy.h` opens a channel on a copy
engine and copies each finished picture to a staging buffer in system memory, which is untiled as before. Bit-exact
(matrix and JCT-VC streams). Not every copy engine instance runs methods from a channel of its own: on the RTX 5060 Ti
instance 0 accepts them and never completes, 4 and 7 work; `ce_open` copies one page on each candidate and keeps the
first that delivers it. Bit 1 of `NVDEC_VIDMEM` puts the engine's filter, co-located and intra buffers in video memory
too (1.8 -> 1.5 ms). Without a copy engine, or without the video memory (17 pictures: about 600 MB for 4K 10-bit),
everything is allocated as before. H.264, VP9 and AV1 still keep their pictures in system memory.

In real time the gain is the engine's: two 4K 240 fps streams (two processes) went from 31 + 31 pictures a second with
a third of the steps doubled to about 50 + 50, nearly all steps of 4; in one process both hold sub-layers 0..2. With
the engine this cheap the pacing went up to 120 pictures a second, which the player could not show (44 a second,
uneven): the pacing now stops at 60 (`max_fps`).

## Performance (AVFoundation, RTX 5060 Ti)

| stream | fps | per picture inside the decoder |
|---|---|---|
| AV1 4K 8-bit | 138-148 | engine ~5.7 ms, copy ~3.4 ms |
| AV1 4K 10-bit (P010) | ~82 | engine ~8 ms, copy ~7.8 ms |
| AV1 4K 10-bit read as NV12 | ~93 | |
| VP9 4K / 1080p | ~140-160 / ~700 | |
| H.264 4K | ~100 | |
| HEVC 4K 8-bit / 10-bit (P010) / 10-bit as NV12 | ~120-130 / ~72 / ~80 | engine ~6 ms, copy ~3.5-4 ms (8-bit) |

The copy (untiling into the client's buffer on the CPU) is the other half of the time; the Blackwell layouts got a
whole-tile path (5.2 -> 3.4 ms at 4K 8-bit).

## How the problems were found (for the next card)

- Turn the codec on, inject the library into ffmpeg (`cmp.sh`) and compare framemd5 with the software decode. Intra
  frames right and inter frames failing pointed at a missing buffer; garbage at ~10 dB (`psnr.sh`) pointed at the layout.
- `NVDEC_GOB=turing|blackwell` overrides the untiling; trying both told which layout the engine wrote.
- Bisect missing buffers by pointing candidate methods at spare buffers from an environment mask, then confirm with a
  reference that works (the closed decoder's push buffer, `trace_closed_push.sh`).
- Synchronous ffmpeg runs never showed the lost submissions; the asynchronous AVFoundation stress (`stress.sh`) did.
  On a timeout, print the semaphore's value and keep waiting: "previous value, never arrives" is a lost submission,
  "arrives late" is a slow engine.

## Open

- Our HEVC engine time at 4K 8-bit (~6 ms against the closed decoder's 3.5 ms).
- MPEG-1/2/4 decode on Blackwell: not tried (`NVENCVT_BLACKWELL_ALL_DEC=1` registers them).
- The plugin's automatic libnvencvt choice could include Blackwell (`nvmtl_nvencvt_selected` in plugin/NVMTLDevice.m);
  that needs a plugin rebuild. Until then `NVMTL_NVENCVT=1` in nvrm610.conf.
- AV1 / VP9 encode on Blackwell (no encoder setup for NVENC class `0xcfb7`).

---
Copyright (c) 2026 kevineduardo. Licensed under the MIT License (SPDX-License-Identifier: MIT).
