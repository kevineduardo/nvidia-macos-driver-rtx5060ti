"""trace_closed_push.py: an lldb script. At nvd265_close (NullMoth's closed HEVC decoder) it dumps every readable,
non-executable data region of the process into $TRACE_OUT (lldb's own environment), so the push buffer the decoder wrote
can be read back with push_decode.py. Used with trace_closed_push.lldb; see README.md."""
import lldb, os
OUT = os.environ.get('TRACE_OUT', '/tmp/nvdec-trace')
def on_close(frame, bp_loc, d):
    os.makedirs(OUT, exist_ok=True)
    p = frame.GetThread().GetProcess(); err = lldb.SBError()
    regs = p.GetMemoryRegions(); n = regs.GetSize(); k = 0
    for i in range(n):
        r = lldb.SBMemoryRegionInfo(); regs.GetMemoryRegionAtIndex(i, r)
        a, e = r.GetRegionBase(), r.GetRegionEnd(); sz = e - a
        if not r.IsReadable() or r.IsExecutable() or sz == 0 or sz > (32 << 20) or a >= 0x7ff800000000: continue
        b = p.ReadMemory(a, sz, err)
        if err.Success() and b: open(f'{OUT}/r_{a:x}_{sz}.bin', 'wb').write(b); k += 1
    print('regions', n, 'dumped', k, 'to', OUT)
    return False
