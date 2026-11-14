// untile_test.c: gob_untile_plane (whole-tile fast path) against gob_offset, sample by sample, both Blackwell layouts
// untile_test.c: gob_untile_plane (fast path) against gob_offset, sample by sample, for both Blackwell layouts
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "blocklinear.h"
int main(void)
{
    int fails = 0;
    const size_t sizes[][2] = { {3840, 2160}, {1920, 1080}, {130, 132}, {7680, 33}, {64, 16}, {100, 7}, {7680, 4320} };
    for (int L = GOB_BLACKWELL8; L <= GOB_BLACKWELL16; L++)
        for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
            const size_t w = sizes[i][0], h = sizes[i][1], pitch = (w + 63) & ~(size_t)63, rows = (h + 15) & ~(size_t)15;
            uint8_t *src = malloc(pitch * rows), *dst = malloc(w * h + 64);
            for (size_t k = 0; k < pitch * rows; k++) src[k] = (uint8_t)(rand() >> 7);
            memset(dst, 0xAB, w * h + 64);
            gob_untile_plane(L, dst, w, src, w, h, pitch);
            size_t bad = 0;
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) bad += dst[y * w + x] != src[gob_offset(L, x, y, pitch)];
            for (size_t k = w * h; k < w * h + 64; k++) bad += dst[k] != 0xAB;   // nothing written past the picture
            printf("%s layout %d %zux%zu: %zu wrong\n", bad ? "FAIL" : "ok  ", L, w, h, bad); fails += bad != 0;
            free(src); free(dst);
        }
    return fails;
}
