// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// cecopy.h: copies between GPU-mapped buffers on the copy engine, on a channel of its own.
//
// Why: a decoder whose pictures are in system memory makes NVDEC read its references and write its output across the
// bus (HEVC 4K 10-bit on an RTX 5060 Ti: 8.1 ms a picture). With the pictures in video memory the engine needs 1.9 ms,
// but the CPU cannot read video memory at any useful speed (0.7 s a picture through the BAR mapping). The copy engine
// moves the decoded picture to a staging buffer in system memory, which the CPU then reads as before.
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stdint.h>
#include "channel.h"
#include "class/clc8b5.h"   // the method layout Blackwell (0xcab5, whose header lists only what changed) shares
#include "class/clb0b5sw.h"
#include "class/clc56f.h"
#include "class/cl2080_notification.h"

typedef struct { Chan ch; RmMem sem; NvU32 seq; bool on; } CeCopy;

static inline void ce_queue(CeCopy *c, NvU64 src, NvU64 dst, size_t bytes, bool last);
// The copy engines of a card are not all usable from a channel of their own (on an RTX 5060 Ti number 0 takes the
// methods and never runs them; 4 and 7 work), so each candidate copies one page and is kept only if the page arrived.
// The one that worked is remembered for the process.
static inline int ce_open(Rm *rm, CeCopy *c)
{
    static _Atomic int known = -1;   // -1 not tried, -2 none works, else the instance
    memset(c, 0, sizeof *c);
    const NvU32 cls = rm_class(rm, RM_CLS_COPY);
    if (!cls || atomic_load(&known) == -2) return -1;
    if (rm_mem_alloc(rm, &c->sem, 0x3000, 0x1000, true, true, true)) return -1;   // semaphore page, test source, test destination
    const char *e = getenv("NVDEC_CE_INST");
    const int first = e ? atoi(e) : atomic_load(&known) >= 0 ? atomic_load(&known) : 0;
    for (int i = first; i < 10; i++) {
        NVB0B5_ALLOCATION_PARAMETERS p = { .version = NVB0B5_ALLOCATION_PARAMETERS_VERSION_1, .engineType = NV2080_ENGINE_TYPE_COPY(i) };
        chan_quiet = true;    // an instance this card does not have is not an error worth a line
        const NV_STATUS made = chan_create(rm, &c->ch, NV2080_ENGINE_TYPE_COPY(i), cls, &p);
        chan_quiet = false;
        if (made != NV_OK) { chan_destroy(&c->ch); continue; }
        chan_mthd(&c->ch, 0, NVC56F_SET_OBJECT, 1, cls);
        uint8_t *m = c->sem.cpu;
        memset(m, 0, 0x3000); for (int b = 0; b < 4096; b++) m[0x1000 + b] = (uint8_t)(b * 7 + i + 1);
        c->on = true;
        ce_queue(c, c->sem.gpu + 0x1000, c->sem.gpu + 0x2000, 4096, true);
        if (chan_submit(&c->ch) == NV_OK && chan_wait(&c->ch, (volatile const NvU32 *)c->sem.cpu, c->seq, 40) && !memcmp(m + 0x1000, m + 0x2000, 4096)) {
            chan_done(&c->ch); chan_rewind(&c->ch);
            if (getenv("NVDEC_CE_LOG")) fprintf(stderr, "ce: copy engine %d, class 0x%x\n", i, cls);
            atomic_store(&known, i); return 0;
        }
        c->on = false; chan_destroy(&c->ch);
    }
    if (!e) atomic_store(&known, -2);
    rm_mem_free(rm, &c->sem);
    return -1;
}
static inline void ce_close(Rm *rm, CeCopy *c) { if (c->on) { chan_destroy(&c->ch); rm_mem_free(rm, &c->sem); c->on = false; } }

// queue one copy of `bytes` (a multiple of 4096) from GPU address src to dst; last: release the semaphore after it
static inline void ce_queue(CeCopy *c, NvU64 src, NvU64 dst, size_t bytes, bool last)
{
    Chan *h = &c->ch;
    if (last) chan_mthd(h, 0, NVC8B5_SET_SEMAPHORE_A, 3, (NvU32)(c->sem.gpu >> 32), (NvU32)c->sem.gpu, ++c->seq);
    chan_mthd(h, 0, NVC8B5_OFFSET_IN_UPPER, 8, (NvU32)(src >> 32), (NvU32)src, (NvU32)(dst >> 32), (NvU32)dst,
              4096u, 4096u, 4096u, (NvU32)(bytes / 4096));
    chan_mthd(h, 0, NVC8B5_LAUNCH_DMA, 1,
              DRF_DEF(C8B5, _LAUNCH_DMA, _DATA_TRANSFER_TYPE, _NON_PIPELINED) | DRF_DEF(C8B5, _LAUNCH_DMA, _FLUSH_ENABLE, _TRUE) |
              (last ? DRF_DEF(C8B5, _LAUNCH_DMA, _SEMAPHORE_TYPE, _RELEASE_ONE_WORD_SEMAPHORE) : 0) |
              DRF_DEF(C8B5, _LAUNCH_DMA, _SRC_MEMORY_LAYOUT, _PITCH) | DRF_DEF(C8B5, _LAUNCH_DMA, _DST_MEMORY_LAYOUT, _PITCH) |
              DRF_NUM(C8B5, _LAUNCH_DMA, _MULTI_LINE_ENABLE, 1) |
              DRF_DEF(C8B5, _LAUNCH_DMA, _SRC_TYPE, _VIRTUAL) | DRF_DEF(C8B5, _LAUNCH_DMA, _DST_TYPE, _VIRTUAL));
}
// submit what was queued and wait for it; true when done
static inline bool ce_run(CeCopy *c)
{
    if (chan_submit(&c->ch)) return false;
    const bool ok = chan_wait(&c->ch, (volatile const NvU32 *)c->sem.cpu, c->seq, 1000);
    if (ok) { chan_done(&c->ch); chan_rewind(&c->ch); }
    else { NvU64 fa = 0; NvU32 ft = 0; char fs[32] = ""; chan_fault(&c->ch, &fa, &ft, fs);
           fprintf(stderr, "ce: not done: gpget 0x%x gpput 0x%x sem %u want %u error 0x%x fault 0x%llx type %u %s\n", chan_gpget(&c->ch), c->ch.gpPut,
                   *(volatile NvU32 *)c->sem.cpu, c->seq, chan_error(&c->ch), (unsigned long long)fa, ft, fs); }
    return ok;
}
