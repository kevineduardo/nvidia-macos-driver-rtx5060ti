#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
"""playcmp.py <ref from subrow_md5.py> <avplay output> [fps]: each picture a real-time playback showed against the software decode of the
picture with that presentation time. Prints how many were shown, how many are wrong, and the first wrong ones."""
import sys
ref = {}   # reference: "frame-index md5" lines (subrow_md5.py), pictures 1/FPS apart from time 0
FPS = float(sys.argv[3]) if len(sys.argv) > 3 else 240.0
for l in open(sys.argv[1]):
    f = l.split()
    if len(f) == 2: ref[int(f[0])] = f[1]
shown = wrong = unknown = 0; bad = []; times = []
for l in open(sys.argv[2]):
    p = l.split()
    if len(p) != 2: continue
    try: t = float(p[0])
    except ValueError: continue
    shown += 1; k = round(t * FPS); times.append(t)
    if k not in ref: unknown += 1
    elif ref[k] != p[1]: wrong += 1; bad.append(t)
gaps = [round((b - a) * FPS) for a, b in zip(times, times[1:])]
import collections
hist = collections.Counter(gaps)
span = (times[-1] - times[0]) if len(times) > 1 else 0
print(f"shown {shown} ({shown / span if span else 0:.0f}/s), wrong {wrong}, outside the reference {unknown}; steps between pictures (in 1/{FPS:.0f} s, step: count): "
      f"{dict(sorted(hist.items()))}; first wrong at {[round(x, 3) for x in bad[:6]]}")
