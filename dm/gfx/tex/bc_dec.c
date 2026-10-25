#define BCDEC_STATIC
#define BCDEC_BC4BC5_PRECISE
#define BCDEC_IMPLEMENTATION
#include "../../third_party/bcdec/bcdec.h"
#include "bc_dec.h"
#include <string.h>

int bc_soft_mtl(int f, uint32_t *mtl, int *bpp) {
    // Same numbers as nvn_fmt_mtl.c's MTLPixelFormat table.
    static const struct { uint16_t mtl; uint8_t bpp; } t[16] = {
        {70, 4}, {70, 4}, {70, 4}, {70, 4},   // DXT1 / DXT3 / DXT5
        {71, 4}, {71, 4}, {71, 4}, {71, 4},   // the sRGB ones
        {10, 1}, {12, 1},                     // RGTC1 unorm / snorm → R8
        {30, 2}, {32, 2},                     // RGTC2 → RG8
        {70, 4}, {71, 4},                     // BPTC unorm / sRGB → RGBA8
        {115, 8}, {115, 8},                   // BPTC float → RGBA16Float, alpha 1
    };
    if (f < 0x41 || f > 0x50) return 0;
    if (mtl) *mtl = t[f - 0x41].mtl;
    if (bpp) *bpp = t[f - 0x41].bpp;
    return 1;
}

static int block_bytes(int f) {
    return (f <= 0x42 || f == 0x45 || f == 0x46 || f == 0x49 || f == 0x4A) ? 8 : 16;
}

static void expand_bc6h(const uint8_t *block, int sgn, uint8_t *dst, size_t dst_pitch, uint32_t w, uint32_t h, uint32_t x0, uint32_t y0) {
    uint16_t rgb[4 * 4 * 3];
    bcdec_bc6h_half(block, rgb, 4 * 3, sgn);   // pitch is in halfs: four RGB pixels per row
    for (uint32_t py = 0; py < 4; py++) {
        if (y0 + py >= h) break;
        uint16_t *row = (uint16_t *)(dst + (size_t)(y0 + py) * dst_pitch);
        for (uint32_t px = 0; px < 4; px++) {
            if (x0 + px >= w) break;
            const uint16_t *s = rgb + py * 12 + px * 3;
            uint16_t *d = row + (x0 + px) * 4;
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 0x3C00;   // alpha = 1, as a hardware BC6H sample
        }
    }
}

static void expand_rgba(const uint8_t *block, int f, uint8_t *dst, size_t dst_pitch, uint32_t w, uint32_t h, uint32_t x0, uint32_t y0) {
    uint8_t pxb[4 * 4 * 4];
    int sgn = (f == 0x4A || f == 0x4C);
    switch (f) {
        case 0x41: case 0x42: case 0x45: case 0x46: bcdec_bc1(block, pxb, 16); break;
        case 0x43: case 0x47: bcdec_bc2(block, pxb, 16); break;
        case 0x44: case 0x48: bcdec_bc3(block, pxb, 16); break;
        case 0x49: case 0x4A: bcdec_bc4(block, pxb, 4, sgn); break;
        case 0x4B: case 0x4C: bcdec_bc5(block, pxb, 8, sgn); break;
        default: bcdec_bc7(block, pxb, 16); break;
    }
    int bpp = (f == 0x49 || f == 0x4A) ? 1 : (f == 0x4B || f == 0x4C) ? 2 : 4;
    for (uint32_t py = 0; py < 4; py++) {
        if (y0 + py >= h) break;
        uint8_t *row = dst + (size_t)(y0 + py) * dst_pitch;
        uint32_t n = 4;
        if (x0 + n > w) n = w - x0;
        memcpy(row + (size_t)x0 * bpp, pxb + py * 4 * bpp, (size_t)n * bpp);
    }
}

int bc_decode_level(int f, const void *src, size_t src_pitch, void *dst, size_t dst_pitch, uint32_t w, uint32_t h, uint32_t slices) {
    if (!w || !h || !slices) return 0;
    int bpb = block_bytes(f);
    uint32_t nbx = (w + 3) / 4, nby = (h + 3) / 4;
    size_t slice_src = src_pitch * nby, slice_dst = dst_pitch * h;
    int bc6 = (f == 0x4F || f == 0x50);
    for (uint32_t z = 0; z < slices; z++) {
        const uint8_t *s = (const uint8_t *)src + z * slice_src;
        uint8_t *d = (uint8_t *)dst + z * slice_dst;
        for (uint32_t by = 0; by < nby; by++) {
            const uint8_t *row = s + by * src_pitch;
            for (uint32_t bx = 0; bx < nbx; bx++) {
                const uint8_t *block = row + (size_t)bx * bpb;
                if (bc6) expand_bc6h(block, f == 0x4F, d, dst_pitch, w, h, bx * 4, by * 4);
                else expand_rgba(block, f, d, dst_pitch, w, h, bx * 4, by * 4);
            }
        }
    }
    return 0;
}
