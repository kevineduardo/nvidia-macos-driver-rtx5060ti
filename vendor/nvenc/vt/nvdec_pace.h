// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// nvdec_pace.h: which temporal sub-layers of an HEVC stream a decoder that cannot keep up should decode.
//
// A 4K 240 fps stream (Apple's aerial screen savers: five temporal sub-layers, half the pictures in the top one) costs
// this decoder 8-15 ms a picture; a player in real time has 4 ms. VideoToolbox sets no quality-of-service property on a
// third-party decoder, so the player dropped pictures by itself, in bursts: two pictures 1/120 s apart, then a jump of
// 1/15 s, over and over (with NullMoth's closed decoder too), on both monitors, four cores busy untiling.
//
// HEVC lets a decoder leave out every picture above a temporal sub-layer: the rest never refer to them (7.4.2.2), and
// what is left is evenly spaced (sub-layers 0..2 of that stream are 60 pictures a second). This picks that sub-layer
// from what the decoder measures: pictures per second of stream time in each sub-layer (from the presentation times of
// what it is given: the player may already be holding pictures back) times the cost of a decoded picture. It answers
// per picture, in decoding order; a picture it refuses is never given to the engine and is reported as dropped.
//   - only in real-time playback (kVTDecodeFrame_1xRealTimePlayback); transcoders and tests get every picture
//   - down at once (load over 0.85); up one sub-layer after it would have fit in 0.70 for 1.5 s of the stream
//   - a step up that has to be undone within 4 s doubles the wait before the next one (to 48 s): two streams on one
//     engine (a screen saver on two monitors) each saw room at 30 pictures a second, went to 60 together, overloaded
//     the engine, fell back, and did it again every two seconds
//   - up only where the stream allows it: at a TSA picture of the next sub-layer (then to any higher one), an STSA
//     picture (that sub-layer alone), or an IRAP
// Pure C, no VideoToolbox: tools/test_nvdec_pace.py runs it on streams' sub-layer patterns.
#pragma once
#include <stdbool.h>
#include <string.h>

enum { NVPACE_TIDS = 8, NVPACE_ALL = 7 };
enum { NVPACE_WINDOW = 16,           // input pictures per decision
       NVPACE_FIRST = 32 };          // and before the first one: with fewer the sub-layers' rates are not known

typedef struct {
    int decoding;                 // highest sub-layer being decoded now (what the references allow)
    int limit;                    // highest sub-layer the load allows (the target of `decoding`)
    unsigned seen[NVPACE_TIDS];   // input pictures per sub-layer, this window
    unsigned in_window; bool decided;
    double pts_lo, pts_hi;        // the window's presentation times (seconds); pts_hi < pts_lo: none yet
    double rate[NVPACE_TIDS];     // pictures per second of stream time per sub-layer (the peak, fading very slowly)
    double cost_ms;               // moving average of the cost of a decoded picture
    double fits_higher_s;         // stream seconds in a row in which limit + 1 would have fit
    double raise_wait_s;          // how long it must fit before a step up (1.5 s, doubled after a step up that failed)
    double since_raise_s;         // stream seconds since the last step up
    bool realtime;
    unsigned long dropped, decoded;
} NvPace;

static inline void nvpace_init(NvPace *p)
{
    memset(p, 0, sizeof *p); p->decoding = p->limit = NVPACE_ALL; p->pts_lo = 1; p->pts_hi = 0;
    p->raise_wait_s = 1.5; p->since_raise_s = 1e9;
}

// The cost of the picture just decoded: the wall time the decoder needed for it, waiting for the engine and for room
// in the output queue included.
static inline void nvpace_measured(NvPace *p, double cost_ms)
{
    if (cost_ms > 0) p->cost_ms = p->cost_ms > 0 ? p->cost_ms * 0.9 + cost_ms * 0.1 : cost_ms;
}

// the share of a second the decoder would be busy decoding sub-layers 0..tid: 1.0 is all the time there is
static inline double nvpace_load(const NvPace *p, int tid)
{
    double r = 0;
    for (int t = 0; t <= tid && t < NVPACE_TIDS; t++) r += p->rate[t];
    return r * p->cost_ms / 1000.0;
}

// one window of input is in: its rates, then the sub-layer the load allows
static inline void nvpace_decide(NvPace *p, double dur_s)
{
    // the stream time the window covers: first to last presentation time, plus one picture's (a window of n pictures
    // n - 1 intervals apart covers n intervals)
    const double span = p->pts_hi >= p->pts_lo ? p->pts_hi - p->pts_lo + (dur_s > 0 ? dur_s : 0) : 0;
    if (span <= 0 || p->cost_ms <= 0) { if (!p->realtime) p->limit = NVPACE_ALL; return; }
    int top = 0;
    for (int t = 0; t < NVPACE_TIDS; t++) {
        // The highest rate seen, fading very slowly (by half in about 700 decisions, a minute of a 240 fps stream): a
        // stream's structure does not change, but a player that is late holds pictures back by itself, and what arrives
        // then says less than what the stream has. Taking the arrivals at face value made a held-back sub-layer look
        // affordable, and the decoder went up into a load it could not carry.
        const double r = p->seen[t] / span, faded = p->rate[t] * 0.999, avg = p->decided ? p->rate[t] * 0.5 + r * 0.5 : r;
        p->rate[t] = avg > faded ? avg : faded;
        if (p->rate[t] > 0.5) top = t;      // a sub-layer the player still sends (more than a picture in two seconds)
    }
    if (!p->realtime) { p->limit = NVPACE_ALL; p->fits_higher_s = 0; return; }
    const int was = p->limit > top ? top : p->limit;
    int cur = was;
    p->since_raise_s += span;
    while (cur > 0 && nvpace_load(p, cur) > 0.85) cur--;                      // down at once, as far as needed
    if (cur < was) {
        if (p->since_raise_s < 4.0) p->raise_wait_s = p->raise_wait_s * 2 < 48 ? p->raise_wait_s * 2 : 48;   // the step up did not hold
        p->limit = cur; p->fits_higher_s = 0; return;
    }
    if (p->since_raise_s > 60 && p->raise_wait_s > 1.5) p->raise_wait_s = 1.5;   // the last step up held for a minute
    if (cur < top && nvpace_load(p, cur + 1) <= 0.70) {                       // up one, after it fits for long enough
        p->fits_higher_s += span;
        if (p->fits_higher_s >= p->raise_wait_s) { cur++; p->fits_higher_s = 0; p->since_raise_s = 0; }
    } else p->fits_higher_s = 0;
    p->limit = cur >= top ? NVPACE_ALL : cur;
}

// nal_type: the HEVC nal_unit_type of the picture's first slice (TSA 2/3, STSA 4/5, IRAP 16..23); tid: its TemporalId;
// pts_s / dur_s: its presentation time and duration in seconds (dur_s 0 when unknown).
// Returns true to decode the picture, false to drop it (it must then not reach the decoder at all).
static inline bool nvpace_take(NvPace *p, int nal_type, int tid, bool realtime, double pts_s, double dur_s)
{
    if (tid < 0) tid = 0;
    if (tid >= NVPACE_TIDS) tid = NVPACE_TIDS - 1;
    if (realtime != p->realtime) { p->realtime = realtime; p->fits_higher_s = 0; if (!realtime) p->limit = NVPACE_ALL; }
    p->seen[tid]++;
    if (p->pts_hi < p->pts_lo) p->pts_lo = p->pts_hi = pts_s;
    else { if (pts_s < p->pts_lo) p->pts_lo = pts_s; if (pts_s > p->pts_hi) p->pts_hi = pts_s; }
    if (++p->in_window >= (unsigned)(p->decided ? NVPACE_WINDOW : NVPACE_FIRST)) {
        nvpace_decide(p, dur_s);
        p->in_window = 0; p->decided = true; memset(p->seen, 0, sizeof p->seen); p->pts_lo = 1; p->pts_hi = 0;
    }
    const bool irap = nal_type >= 16 && nal_type <= 23, tsa = nal_type == 2 || nal_type == 3, stsa = nal_type == 4 || nal_type == 5;
    if (p->limit < p->decoding) p->decoding = p->limit;                 // down: nothing above is needed by what stays
    else if (p->limit > p->decoding) {                                   // up: only where the stream says it is safe
        if (irap) p->decoding = p->limit;
        else if (tsa && tid == p->decoding + 1) p->decoding = p->limit;  // from here every higher sub-layer may be joined
        else if (stsa && tid == p->decoding + 1) p->decoding = tid;      // this sub-layer alone
    }
    const bool take = tid <= p->decoding;
    if (take) p->decoded++; else p->dropped++;
    return take;
}
