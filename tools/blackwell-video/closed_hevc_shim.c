// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// closed_hevc_shim.c: registers NullMoth's closed HEVC decoder in a process it is injected into (rating 2000), so its push buffer can be traced (trace_closed_push.sh)
#include <dlfcn.h>
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
__attribute__((constructor)) static void init(void)
{
    void *h = dlopen("/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvdec_hevc.dylib", RTLD_NOW);
    void *fac = h ? dlsym(h, "NVDecHEVC_CreateInstance") : NULL;
    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW);
    typedef int (*RegFn)(uint32_t, CFDictionaryRef, void *);
    RegFn reg = vt ? (RegFn)dlsym(vt, "VTRegisterVideoDecoderWithInfo") : NULL;
    if (!fac || !reg) { fprintf(stderr, "shim: missing %p %p\n", fac, reg); return; }
    int r = 2000; CFNumberRef nr = CFNumberCreate(NULL, kCFNumberIntType, &r);
    const void *k[] = { CFSTR("CMClassImplementationID"), CFSTR("CMClassImplementationName"), CFSTR("VTRating"), CFSTR("VTIsHardwareAccelerated") };
    const void *v[] = { CFSTR("trace.hevc.nvdec"), CFSTR("trace HEVC"), nr, kCFBooleanTrue };
    CFDictionaryRef info = CFDictionaryCreate(NULL, k, v, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    fprintf(stderr, "shim: register -> %d\n", reg('hvc1', info, fac));
}
