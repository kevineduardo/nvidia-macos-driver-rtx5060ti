#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 kevineduardo
"""Which temporal sub-layers the HEVC decoder decodes when it cannot keep up (vendor/nvenc/vt/nvdec_pace.h).

Apple's aerial screen savers are 4K 240 fps HEVC with five temporal sub-layers; a picture costs this decoder 8 to 15 ms
and real time gives it 4. The player dropped pictures in bursts (steps of 2 to 42 pictures between the ones shown). The
decoder now leaves out whole sub-layers, which HEVC allows and which leaves evenly spaced pictures.

The header is compiled alone and run on the sub-layer pattern of that stream and on others:
  - not in real-time playback: every picture is decoded, whatever it costs (the control for the tests that compare
    against a software decode);
  - in real time: the load the decoder is left with fits, the pictures it keeps are evenly spaced, sub-layer 0 is never
    dropped, and a faster decoder keeps more;
  - a sub-layer is joined again only at a TSA picture of the next sub-layer, an STSA picture or an IRAP: on a stream
    without them it waits for the IRAP.

usage: test_nvdec_pace.py [repo root]"""
import pathlib, platform, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
fails = 0


def check(name, ok, detail=''):
    global fails
    print(('ok   ' if ok else 'FAIL ') + name + (f' ({detail})' if detail else ''))
    fails += 0 if ok else 1


HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include "nvdec_pace.h"
// argv: realtime cost_ms fps groups maxtid, then one group of pictures in decoding order as "type:tid:pos" (pos: the
// picture's place in output order within its group); a group is `len` pictures long in stream time. An IDR comes first.
int main(int c, char **v) {
    NvPace p; nvpace_init(&p);
    const int rt = atoi(v[1]); double cost = atof(v[2]); const double fps = atof(v[3]); const int groups = atoi(v[4]), maxtid = atoi(v[5]);
    const int np = c - 6; int i = 0;
    printf("%d %d %d %d %d %.6f\n", i++, 19, 0, nvpace_take(&p, 19, 0, rt, 0, 1 / fps), p.decoding, 0.0); nvpace_measured(&p, cost);
    for (int g = 0; g < groups; g++) {
        if (g == groups / 2 && getenv("COST2")) cost = atof(getenv("COST2"));   // the decoder gets faster / slower halfway
        for (int k = 0; k < np; k++) {
            int type, tid, pos; sscanf(v[6 + k], "%d:%d:%d", &type, &tid, &pos);
            if (tid > maxtid) continue;                                          // the player holds this sub-layer back
            if (getenv("HOLD3") && g >= groups / 2 && tid == 3 && (g & 1)) continue;   // late, it holds sub-layer 3 back in every other group
            const double pts = (g * np + pos) / fps;
            const int take = nvpace_take(&p, type, tid, rt, pts, 1 / fps);
            // SHARED: another stream on the same engine does what this one does, so 60 pictures a second cost 20 ms each
            if (take) nvpace_measured(&p, getenv("SHARED") ? (p.decoding >= 2 ? 20.0 : 8.0) : cost);
            printf("%d %d %d %d %d %.6f\n", i++, type, tid, take, p.decoding, pts);
        }
    }
    return 0;
}
'''
# one group of 16 in decoding order, as in Apple's 240 fps aerials: type : TemporalId : place in output order (1..16)
AERIAL = ['1:0:16', '3:1:8', '3:2:4', '3:3:2', '2:4:1', '2:4:3', '3:3:6', '2:4:5', '2:4:7', '3:2:12', '3:3:10', '2:4:9', '2:4:11', '3:3:14', '2:4:13', '2:4:15']
NOTSA = [x.replace('3:', '1:', 1).replace('2:4', '0:4') if x[0] in '23' else x for x in AERIAL]   # the same shape, TRAIL pictures only

if platform.system() == 'Windows' or not shutil.which('clang'):
    print('skip: needs clang'); sys.exit(0)

with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    (d / 'h.c').write_text(HARNESS)
    r = subprocess.run(['clang', '-O1', '-Wall', '-Werror', '-Wno-misleading-indentation', '-I', str(root / 'vendor/nvenc/vt'), '-o', str(d / 'h'), str(d / 'h.c')],
                       capture_output=True, text=True)
    check('the header compiles on its own, without warnings', r.returncode == 0, r.stderr.strip()[-300:])
    if r.returncode:
        print(f'{fails} failed'); sys.exit(1)

    def run(rt, cost, groups, pattern, cost2=None, maxtid=7, fps=240):
        import os
        env = dict(os.environ); env.pop('COST2', None)
        if cost2 is not None: env['COST2'] = str(cost2)
        out = subprocess.run([str(d / 'h'), str(rt), str(cost), str(fps), str(groups), str(maxtid)] + pattern, capture_output=True, text=True, env=env).stdout
        return [(int(a), int(b), int(c), int(e), int(f), float(g)) for a, b, c, e, f, g in (l.split() for l in out.split('\n') if l.strip())]

    def spacing(rows):   # the distances between kept pictures in output order, in pictures of the full stream
        t = sorted(r[5] for r in rows if r[3]); return sorted({round((b - a) * 240) for a, b in zip(t, t[1:])})

    rows = run(0, 12, 60, AERIAL)
    check('control: outside real-time playback every picture is decoded, however slow the decoder', all(r[3] for r in rows))

    rows = run(1, 8, 120, AERIAL); tail = rows[len(rows) // 2:]; kept = [r for r in tail if r[3]]
    check('real time, 8 ms a picture at 240 fps: it settles on sub-layers 0..2, 60 pictures a second (0.48 of the time)',
          {r[2] for r in kept} == {0, 1, 2}, str(sorted({r[2] for r in kept})))
    check('the pictures kept are evenly spaced: every 4th', spacing(tail) == [4], str(spacing(tail)))
    check('sub-layer 0 is never dropped', all(r[3] for r in rows if r[2] == 0))
    check('it decides early: no more than 48 pictures decoded in full first', next(i for i, r in enumerate(rows) if not r[3]) <= 48)

    rows = run(1, 15, 120, AERIAL); tail = rows[len(rows) // 2:]
    check('15 ms a picture (two streams on one engine): sub-layers 0..1, every 8th picture, 30 a second',
          {r[2] for r in tail if r[3]} == {0, 1} and spacing(tail) == [8], f'{sorted({r[2] for r in tail if r[3]})} {spacing(tail)}')
    fast = [r for r in run(1, 2.5, 120, AERIAL)[960:] if r[3]]
    check('a decoder at 2.5 ms a picture keeps every sub-layer', {r[2] for r in fast} == {0, 1, 2, 3, 4})
    slow = [r for r in run(1, 60, 120, AERIAL)[960:] if r[3]]
    check('a decoder at 60 ms keeps sub-layer 0 alone', {r[2] for r in slow} == {0}, str(sorted({r[2] for r in slow})))

    # the player already holds the top sub-layer back (it drops pictures nothing depends on when it is late): the load
    # is what arrives, 120 pictures a second, not the stream's 240
    rows = run(1, 8, 120, AERIAL, maxtid=3); tail = rows[len(rows) // 2:]
    check('with the player holding sub-layer 4 back the decoder still settles on 0..2 (and not lower)',
          {r[2] for r in tail if r[3]} == {0, 1, 2} and spacing(tail) == [4], f'{sorted({r[2] for r in tail if r[3]})} {spacing(tail)}')

    # halfway the player starts holding sub-layer 3 back in every other group (sub-layer 4 it never sent). What arrives of
    # sub-layer 3 is then 30 pictures a second, the stream has 60: at 7.5 ms a picture the arrivals make 0..3 look like
    # 0.68 of the time while the stream's own rate is 0.90, which is why it left sub-layer 3 out in the first place. Going
    # up on the arrivals would overload the decoder again.
    import os
    os.environ['HOLD3'] = '1'
    rows = run(1, 7.5, 240, AERIAL, maxtid=3); half = len(rows) // 2
    del os.environ['HOLD3']
    check('a sub-layer the player holds back at times is not taken for affordable',
          all(r[4] <= 2 for r in rows[half:]) , str(sorted({r[4] for r in rows[half:]})))

    # two streams on one engine: each fits at 30 pictures a second (8 ms a picture) and overloads it at 60 (20 ms). Every
    # step up fails; they must get rarer, not come every two seconds
    os.environ['SHARED'] = '1'
    rows = run(1, 8, 1800, AERIAL)   # two minutes of the stream
    del os.environ['SHARED']
    ups = [b[5] for a, b in zip(rows, rows[1:]) if b[4] > a[4]]
    at60 = sum(1 for r in rows if r[4] >= 2) / len(rows)
    check('a step up that fails each time is tried less and less often (two streams on one engine)',
          len(ups) <= 7 and at60 < 0.12, f'{len(ups)} steps up in 120 s at {[round(u) for u in ups]} s, {at60:.0%} of the time overloaded')

    # the decoder gets faster halfway (the second monitor's stream ends): it goes up, at a TSA picture of the next sub-layer
    rows = run(1, 15, 240, AERIAL, cost2=2); half = len(rows) // 2
    end = [r for r in rows[-480:] if r[3]]
    check('faster halfway: every sub-layer is decoded again by the end', {r[2] for r in end} == {0, 1, 2, 3, 4}, str(sorted({r[2] for r in end})))
    ups = [(a, b) for a, b in zip(rows, rows[1:]) if b[4] > a[4]]
    check('and each step up happens at a TSA picture of the next sub-layer', bool(ups) and all(b[1] in (2, 3) and b[2] == a[4] + 1 for a, b in ups),
          str([(b[0], b[1], b[2], a[4]) for a, b in ups][:4]))
    first_up = ups[0][1][0] if ups else 0
    check('it does not go up at once (it waits 1.5 s of the stream)', (first_up - half) >= 240, f'{first_up - half} pictures after the change')
    rows = run(1, 2, 120, AERIAL, cost2=15); half = len(rows) // 2
    first_drop = next((r[0] for r in rows[half:] if not r[3]), None)
    check('slower halfway: it goes down within three decisions', first_drop is not None and first_drop - half <= 64, str(first_drop and first_drop - half))

    # a stream with no TSA / STSA pictures: sub-layers left out can only be joined again at an IRAP
    rows = run(1, 15, 240, NOTSA, cost2=2)
    check('without TSA pictures no sub-layer is joined again before an IRAP', all(b[4] <= a[4] for a, b in zip(rows, rows[1:])),
          str([(b[0], a[4], b[4]) for a, b in zip(rows, rows[1:]) if b[4] > a[4]][:3]))

print('all passed' if not fails else f'{fails} failed')
sys.exit(1 if fails else 0)
