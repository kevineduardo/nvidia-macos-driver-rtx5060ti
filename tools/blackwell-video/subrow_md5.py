#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
"""subrow_md5.py <W> <H> <8|10> < rawvideo (nv12 / p010le) > "frame md5" lines: the MD5 of every 16th row of each plane of
each picture, as avplay prints for the pictures a real-time playback shows. Feed it
  ffmpeg -i clip -pix_fmt p010le -f rawvideo - | subrow_md5.py 3840 2160 10"""
import sys, hashlib
W, H, bps = int(sys.argv[1]), int(sys.argv[2]), 2 if sys.argv[3] == '10' else 1
ch = (H + 1) // 2; row = W * bps; crow = ((W + 1) & ~1) * bps; size = row * H + crow * ch
i = 0
while True:
    b = sys.stdin.buffer.read(size)
    if len(b) < size: break
    h = hashlib.md5(); m = memoryview(b)
    for y in range(0, H, 16): h.update(m[y * row:(y + 1) * row])
    for y in range(0, ch, 16): h.update(m[row * H + y * crow:row * H + (y + 1) * crow])
    print(i, h.hexdigest()); i += 1
