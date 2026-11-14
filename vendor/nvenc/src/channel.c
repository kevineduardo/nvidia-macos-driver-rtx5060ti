// channel.c: see channel.h.
#include "channel.h"
#include "nv_floor.h"
#include <time.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "class/cl0002.h"
#include "class/clc56f.h"
#include "class/clc361.h"
#include "class/clc561.h"
#include "alloc/alloc_channel.h"
#include "ctrl/ctrla06f/ctrla06fgpfifo.h"
#include "ctrl/ctrl906f.h"
#include "ctrl/ctrlc36f.h"

_Thread_local bool chan_quiet;
#define CHK(x) do { NV_STATUS s_ = (x); if (s_) { if (!chan_quiet) fprintf(stderr, "chan: %s -> 0x%x\n", #x, s_); return s_; } } while (0)

NV_STATUS chan_create(Rm *rm, Chan *c, NvU32 engineType, NvU32 objClass, void *objParams)
{
    memset(c, 0, sizeof *c); c->rm = rm; c->entries = 0x8000;
    c->usermodeMap.fd = -1;
    // doorbell page (usermode class): writing a channel's work-submit token there makes the host fetch GPPut
    c->hUsermode = rm_handle(rm);
    CHK(rm_alloc(rm, rm->subdevice, c->hUsermode, rm_class(rm, RM_CLS_USERMODE), NULL));   // Turing / Ampere / Ada: same page layout
    void *um; CHK(rm_map_cpu(rm, rm->subdevice, c->hUsermode, 4096, false, &c->usermodeMap, &um));
    c->doorbell = (volatile NvU32 *)((NvU8 *)um + NVC361_NOTIFY_CHANNEL_PENDING);

    CHK(rm_mem_alloc(rm, &c->notifier, 0x1000, 0x1000, true, true, true));     // error + work-submit-token notifiers
    CHK(rm_mem_alloc(rm, &c->userd, 0x80000, 0x10000, false, true, true));     // channel control (GPPut/GPGet), as NVK
    CHK(rm_mem_alloc(rm, &c->gpfifo, c->entries * 8, 0x1000, true, true, true));
    CHK(rm_mem_alloc(rm, &c->push, 0x10000, 0x1000, true, true, true));
    c->cur = c->segStart = c->push.cpu;
    c->end = (NvU32 *)c->push.cpu + c->push.size / 4;

    NV_CONTEXT_DMA_ALLOCATION_PARAMS cd = { .flags = DRF_DEF(OS03, _FLAGS, _MAPPING, _KERNEL) | DRF_DEF(OS03, _FLAGS, _HASH_TABLE, _DISABLE),
                                           .hMemory = c->notifier.hPhys, .offset = 0, .limit = c->notifier.size - 1 };
    c->hCtxDma = rm_handle(rm);
    CHK(rm_alloc(rm, rm->device, c->hCtxDma, NV01_CONTEXT_DMA, &cd));

    NV_CHANNEL_ALLOC_PARAMS cp = { .hObjectError = c->hCtxDma, .gpFifoOffset = c->gpfifo.gpu, .gpFifoEntries = c->entries,
                                   .hVASpace = rm->vaspace, .hUserdMemory = { c->userd.hPhys }, .userdOffset = { 0 },
                                   .engineType = engineType };
    c->hChannel = rm_handle(rm);
    CHK(rm_alloc(rm, rm->device, c->hChannel, rm_class(rm, RM_CLS_CHANNEL), &cp));   // same GPFIFO / method format since Volta
    NVA06F_CTRL_BIND_PARAMS bp = { .engineType = engineType };
    CHK(rm_ctrl(rm, c->hChannel, NVA06F_CTRL_CMD_BIND, &bp, sizeof bp));
    c->hObject = rm_handle(rm);
    CHK(rm_alloc(rm, c->hChannel, c->hObject, objClass, objParams));
    NVA06F_CTRL_GPFIFO_SCHEDULE_PARAMS sp = { .bEnable = NV_TRUE };
    CHK(rm_ctrl(rm, c->hChannel, NVA06F_CTRL_CMD_GPFIFO_SCHEDULE, &sp, sizeof sp));
    NVC36F_CTRL_GPFIFO_SET_WORK_SUBMIT_TOKEN_NOTIF_INDEX_PARAMS np = { .index = NV_CHANNELGPFIFO_NOTIFICATION_TYPE_WORK_SUBMIT_TOKEN };
    CHK(rm_ctrl(rm, c->hChannel, NVC36F_CTRL_CMD_GPFIFO_SET_WORK_SUBMIT_TOKEN_NOTIF_INDEX, &np, sizeof np));
    NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN_PARAMS tp = { 0 };
    CHK(rm_ctrl(rm, c->hChannel, NVC36F_CTRL_CMD_GPFIFO_GET_WORK_SUBMIT_TOKEN, &tp, sizeof tp));
    c->token = tp.workSubmitToken;
    return NV_OK;
}

void chan_destroy(Chan *c)
{
    Rm *rm = c->rm; if (!rm) return;
    if (c->hChannel) rm_free(rm, rm->device, c->hChannel);
    if (c->hCtxDma) rm_free(rm, rm->device, c->hCtxDma);
    rm_mem_free(rm, &c->push); rm_mem_free(rm, &c->gpfifo); rm_mem_free(rm, &c->userd); rm_mem_free(rm, &c->notifier);
    if (c->usermodeMap.conn) rm_unmap_cpu(rm, &c->usermodeMap);
    if (c->hUsermode) rm_free(rm, rm->subdevice, c->hUsermode);
    memset(c, 0, sizeof *c);
}

void chan_mthd(Chan *c, int subch, NvU32 mthd, int count, ...)
{
    // The push buffer is reused only once the host has fetched it. A channel that stops fetching (a fault, a lost
    // GPU) must not make the next pictures write past the mapping: drop the method and fail the submission.
    if (count < 0 || c->overflow || (size_t)(c->end - c->cur) < (size_t)count + 1) { c->overflow = true; return; }
    *c->cur++ = DRF_NUM(C56F, _DMA, _SEC_OP, NVC56F_DMA_SEC_OP_INC_METHOD) | DRF_NUM(C56F, _DMA, _METHOD_COUNT, count) |
                DRF_NUM(C56F, _DMA, _METHOD_SUBCHANNEL, subch) | DRF_NUM(C56F, _DMA, _METHOD_ADDRESS, mthd >> 2);
    va_list ap; va_start(ap, count);
    for (int i = 0; i < count; i++) *c->cur++ = va_arg(ap, NvU32);
    va_end(ap);
}

NV_STATUS chan_submit(Chan *c)
{
    NvU64 va = c->push.gpu + (NvU64)((NvU8 *)c->segStart - (NvU8 *)c->push.cpu);
    NvU32 dwords = (NvU32)(c->cur - c->segStart);
    if (c->overflow) { fprintf(stderr, "chan: push buffer full (the channel stopped fetching): not submitted\n"); return NV_ERR_INSUFFICIENT_RESOURCES; }
    if (!dwords) return NV_OK;
    c->settled = false;
    NvU32 *e = (NvU32 *)c->gpfifo.cpu + 2 * c->gpPut;
    e[0] = DRF_NUM(C56F, _GP_ENTRY0, _GET, (NvU32)va >> 2);
    e[1] = DRF_NUM(C56F, _GP_ENTRY1, _GET_HI, (NvU32)(va >> 32)) | DRF_NUM(C56F, _GP_ENTRY1, _LENGTH, dwords);
    c->gpPut = (c->gpPut + 1) % c->entries;
    c->segStart = c->cur;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    ((volatile AmpereAControlGPFifo *)c->userd.cpu)->GPPut = c->gpPut;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    // read GPPut back before the doorbell: USERD is video memory behind a write-combined BAR mapping, and the fence does
    // not make the posted write arrive first. On an RTX 5060 Ti the host now and then fetched the old GPPut and the
    // picture was never run (7 of 9600 4K AV1 pictures under AVFoundation; 0 of 9600 with the read)
    (void)((volatile AmpereAControlGPFifo *)c->userd.cpu)->GPPut;
    *c->doorbell = c->token;
    return NV_OK;
}

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#define NV_CPU_PAUSE() _mm_pause()
#else
#define NV_CPU_PAUSE() ((void)0)
#endif
bool chan_wait(Chan *c, volatile const NvU32 *sem, NvU32 val, double timeout_ms)
{
    // Spin until the semaphore holds val. A picture still not done after 50 ms (4K takes under 20) gets the doorbell
    // rung again, which only makes the host read GPPut once more: a safety net for a submission it did not see.
    // Sleeping instead of spinning was tried and is worse here: nanosleep on this thread comes back milliseconds late
    // (0.1 ms sleeps added 2.6 ms a picture; one sleep of 70% of the usual wait made 8 ms pictures take 15 to 21).
    struct timespec t; NV_CLOCK_GETTIME(CLOCK_MONOTONIC, &t);
    const double t0 = t.tv_sec * 1e3 + t.tv_nsec / 1e6; double kick = t0 + 50, now = t0; unsigned kicks = 0;
    while (*sem != val && now - t0 < timeout_ms) {
        NV_CPU_PAUSE();   // the spin costs a core either way; this leaves the core's other thread its share and saves power
        NV_CLOCK_GETTIME(CLOCK_MONOTONIC, &t); now = t.tv_sec * 1e3 + t.tv_nsec / 1e6;
        if (now > kick) { *c->doorbell = c->token; kick += 50; kicks++; }
    }
    if (kicks) fprintf(stderr, "chan: semaphore %u late: doorbell rung %u more time(s), %s after %.0f ms\n", val, kicks, *sem == val ? "done" : "not done", now - t0);
    return *sem == val;
}

bool chan_rewind(Chan *c)
{
    // the push buffer is linear: start over once the channel has fetched everything (GPGet == GPPut), and only once
    // it is half used, so it is a ring that wraps now and then. Starting over after every picture (on Blackwell, where
    // chan_done stands in for GPGet) lost a picture now and then under AVFoundation: no completion and no channel
    // error, as if the engine had run the previous picture's methods from the same address (AV1 4K, about 1 in 1000);
    // NullMoth's own decoders also advance through their push buffer picture by picture.
    if (c->cur != c->segStart || chan_push_used(c) < c->push.size / 2 || (!c->settled && chan_gpget(c) != c->gpPut)) return false;
    c->cur = c->segStart = c->push.cpu;
    return true;
}

void chan_done(Chan *c) { c->settled = true; }

NvU32 chan_gpget(Chan *c) { return ((volatile AmpereAControlGPFifo *)c->userd.cpu)->GPGet; }
NvU32 chan_error(Chan *c) { return ((volatile NvNotification *)c->notifier.cpu)[0].status; }

NV_STATUS chan_fault(Chan *c, NvU64 *addr, NvU32 *type, char str[32])
{
    NV906F_CTRL_GET_MMU_FAULT_INFO_PARAMS p = { 0 };
    NV_STATUS st = rm_ctrl(c->rm, c->hChannel, NV906F_CTRL_CMD_GET_MMU_FAULT_INFO, &p, sizeof p);
    *addr = ((NvU64)p.addrHi << 32) | p.addrLo; *type = p.faultType;
    memcpy(str, p.faultString, 32); str[31] = 0;
    return st;
}

size_t chan_push_used(Chan *c) { return (size_t)((NvU8 *)c->cur - (NvU8 *)c->push.cpu); }
