// BC1–BC7 blocks, already deswizzled to linear block rows, expanded to plain pixels.
// Used when the GPU cannot sample BC (MTLDevice.supportsBCTextureCompression is false:
// iPad mini 6's A15, and anything older than A17 Pro / M1). Hardware BC is unchanged.
#pragma once
#include <stddef.h>
#include <stdint.h>

// 1 when nvn_format is DXT / RGTC / BPTC (0x41–0x50). *mtl is the uncompressed
// MTLPixelFormat the pixels belong in; *bpp is bytes per decoded pixel.
int bc_soft_mtl(int nvn_format, uint32_t *mtl, int *bpp);

// src holds block rows (src_pitch bytes each, one row of 4×4 blocks). slices are
// stacked by src_pitch × block-row count. dst is tightly packed pixel rows of dst_pitch.
// Pixels past w×h inside a partial edge block are not written. Returns 0.
int bc_decode_level(int nvn_format, const void *src, size_t src_pitch,
                    void *dst, size_t dst_pitch, uint32_t w, uint32_t h, uint32_t slices);
