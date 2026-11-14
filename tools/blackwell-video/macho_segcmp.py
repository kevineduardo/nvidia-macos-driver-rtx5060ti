#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
"""macho_segcmp.py <a> <b> <label>: whether two Mach-O files have the same segments apart from __LINKEDIT (the code
signature), i.e. the same code with different signatures: tells a re-signed binary from a rebuilt one."""
import sys, struct, hashlib
def segs(path):
    d = open(path, 'rb').read()
    if struct.unpack_from('<I', d)[0] != 0xfeedfacf: return {'raw': hashlib.sha256(d).hexdigest()}
    ncmds = struct.unpack_from('<I', d, 16)[0]; p = 32; out = {}
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from('<II', d, p)
        if cmd == 0x19:
            name = d[p+8:p+24].rstrip(b'\0').decode(); fo, fs = struct.unpack_from('<QQ', d, p + 40)
            if name != '__LINKEDIT': out[name] = hashlib.sha256(d[fo:fo+fs]).hexdigest()
        p += sz
    return out
a, b = segs(sys.argv[1]), segs(sys.argv[2]); print('same-code' if a == b else 'REAL-DIFF', sys.argv[3])
