#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
"""narrow_compare.py <ref.yuv420p10le> <hw.nv12> <WxH>: the hardware decoder's 8-bit NV12 against the 10-bit reference
rounded to 8 bits ((v + 2) >> 2, at most 255). Every 7th luma sample and every chroma sample of every frame."""
import sys, array
ref, hw, wh = sys.argv[1], sys.argv[2], sys.argv[3]; W, H = map(int, wh.split('x'))
cw, ch = (W + 1) // 2, (H + 1) // 2
r = array.array('H'); r.frombytes(open(ref, 'rb').read()); h = open(hw, 'rb').read()
fy, fc = W * H, cw * ch; nf = len(r) // (fy + 2 * fc); hb = W * H + ((W + 1) & ~1) * ch
assert len(h) == nf * hb, (len(h), nf * hb)
rnd = lambda v: min(255, (v + 2) >> 2)
diff = maxd = 0
for f in range(nf):
    ro, ho = f * (fy + 2 * fc), f * hb
    Y = r[ro:ro + fy]; hy = h[ho:ho + fy]
    for i in range(0, fy, 7):
        d = abs(rnd(Y[i]) - hy[i]); diff += d != 0; maxd = max(maxd, d)
    U = r[ro + fy:ro + fy + fc]; V = r[ro + fy + fc:ro + fy + 2 * fc]; uv = h[ho + fy:ho + hb]
    for y in range(ch):
        for x in range(cw):
            for k, P in ((0, U), (1, V)):
                d = abs(rnd(P[y * cw + x]) - uv[y * ((W + 1) & ~1) + 2 * x + k]); diff += d != 0; maxd = max(maxd, d)
print(f"  {nf} frames vs software 10-bit rounded to 8: differing samples {diff}, max difference {maxd}")
sys.exit(1 if diff else 0)
