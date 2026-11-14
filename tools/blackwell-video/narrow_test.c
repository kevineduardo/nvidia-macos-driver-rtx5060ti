// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// narrow_test.c: gob_untile_plane_narrow (16-bit samples untiled and rounded to 8 bits) against the scalar rule
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "blocklinear.h"
int main(void)
{
    int fails = 0;
    const size_t sizes[][2] = { {3840, 2160}, {1920, 1080}, {130, 132}, {66, 7}, {7680, 4320} };   // in samples
    for (int L = GOB_TURING; L <= GOB_BLACKWELL16; L++) {
        if (L == GOB_BLACKWELL8) continue;
        for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
            const size_t w = sizes[i][0], h = sizes[i][1], wb = w * 2, pitch = (wb + 63) & ~(size_t)63, rows = (h + 15) & ~(size_t)15;
            uint8_t *src = malloc(pitch * rows), *dst = malloc(w * h + 64);
            for (size_t k = 0; k < pitch * rows; k++) src[k] = (uint8_t)(rand() >> 7);
            for (size_t k = 0; k < pitch * rows; k += 64 * 7) { src[k] = 0xff; src[k + 1] = 0xff; }   // saturation cases
            memset(dst, 0xAB, w * h + 64);
            gob_untile_plane_narrow(L, dst, w, src, wb, h, pitch);
            size_t bad = 0;
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) {
                const size_t o = gob_offset(L, 2 * x, y, pitch); const unsigned v = (unsigned)(src[o] | src[o + 1] << 8) + 0x80;
                bad += dst[y * w + x] != (v > 0xffff ? 0xff : v >> 8);
            }
            for (size_t k = w * h; k < w * h + 64; k++) bad += dst[k] != 0xAB;
            printf("%s layout %d %zux%zu: %zu wrong\n", bad ? "FAIL" : "ok  ", L, w, h, bad); fails += bad != 0;
            free(src); free(dst);
        }
    }
    return fails;
}
