#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
"""push_decode.py <dump dir> <clc9b0.h>: finds the region of a trace dump holding the most NVDEC EXECUTE headers and prints
its method stream (INC / IMMD headers), naming the methods clc9b0.h names; a method without a name ("?") is one the public
header leaves out (0x4dc on Blackwell)."""
import sys, struct, glob, re
names = {}
for m in re.finditer(r'#define (NVC9B0_[A-Z0-9_]+)\s+\(0x0000([0-9A-F]{4})\)', open(sys.argv[2]).read()):
    a = int(m.group(2), 16)
    if a >= 0x100 and not m.group(1).endswith(('_ENABLE', '_DISABLE')): names.setdefault(a, m.group(1))
best = None
for f in glob.glob(sys.argv[1] + '/r_*.bin'):
    d = open(f, 'rb').read()
    if len(d) % 4: continue
    A = struct.unpack('<%dI' % (len(d) // 4), d)
    ex = sum(1 for v in A if (v & 0xfff) == 0xC0 and (v >> 29) in (1, 4) and ((v >> 16) & 0x1fff) <= 1)
    if ex and (best is None or ex > best[0]): best = (ex, f, A)
if not best: sys.exit('no NVDEC method stream found')
print(best[1], best[0], 'EXECUTE headers')
A = best[2]; i = 0; shown = 0
while i < len(A) and shown < 80:
    v = A[i]
    if v == 0: i += 1; continue
    op, m, sc, cnt = v >> 29, (v & 0xfff) << 2, (v >> 13) & 7, (v >> 16) & 0x1fff
    if op in (1, 3, 5):
        print(f'{i*4:#7x} sc{sc} {m:#06x} {names.get(m, "?"):42s}', ' '.join(f'{x:#x}' for x in A[i+1:i+1+min(cnt, 3)])); i += 1 + cnt
    elif op == 4: print(f'{i*4:#7x} sc{sc} {m:#06x} {names.get(m, "?"):42s} imm {cnt:#x}'); i += 1
    else: i += 1
    shown += 1
