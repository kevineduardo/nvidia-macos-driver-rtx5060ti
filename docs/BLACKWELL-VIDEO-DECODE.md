# Hardware VP9 and AV1 decode on Blackwell (RTX 50)

State on 2026-11-14, RTX 5060 Ti (GB206, NVDEC class `0xcfb0`), macOS 26.7.2, NullMoth 3.0 plus this branch.

| codec | decoder on Blackwell | state |
|---|---|---|
| H.264 | libnvencvt (rating 1100, above the built-in `libnvdec_h264` at 1000) | bit-exact |
| HEVC | built-in `libnvdec_hevc` (closed) | bit-exact; libnvencvt's HEVC stays off here (see "Open") |
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
   - a word after the structure with the 0x4dc units: VP9 at `+0x108`, AV1 at `+0x244`.
   - AV1: `reserved12` (`+0x54`) = `0xffff`.

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

## Performance (AVFoundation, RTX 5060 Ti)

| stream | fps | per picture inside the decoder |
|---|---|---|
| AV1 4K 8-bit | 138-148 | engine ~5.7 ms, copy ~3.4 ms |
| AV1 4K 10-bit (P010) | ~82 | engine ~8 ms, copy ~7.8 ms |
| AV1 4K 10-bit read as NV12 | ~93 | |
| VP9 4K / 1080p | ~140-160 / ~700 | |
| H.264 4K | ~100 | |

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

- libnvencvt's own HEVC decoder lacks the setup fields above for HEVC (AROS: `reserved6` = kinds, `reserved7` =
  3 x depth code + chroma format, `+0x11c` = units, `+0x120` = `0xffff`); its inter pictures fail on Blackwell, so HEVC
  stays on the built-in decoder. `NVENCVT_BLACKWELL_ALL_DEC=1` registers it for that work.
- The plugin's automatic libnvencvt choice could include Blackwell (`nvmtl_nvencvt_selected` in plugin/NVMTLDevice.m);
  that needs a plugin rebuild. Until then `NVMTL_NVENCVT=1` in nvrm610.conf.
- AV1 / VP9 encode on Blackwell (no encoder setup for NVENC class `0xcfb7`).
