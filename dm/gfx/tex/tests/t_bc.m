// CPU BC decode against this Mac's hardware decoder.
// clang -O2 -g -fobjc-arc -o t_bc t_bc.m ../bc_dec.c -framework Metal -framework Foundation && ./t_bc
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../bc_dec.h"

static uint32_t rnd_state = 1;
static uint32_t rnd(void) { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state; }

static const char *k_msl =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct V { float4 p [[position]]; };\n"
"vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); return o; }\n"
"fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
"  constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
"  return t.sample(s, in.p.xy); }\n";

static int readback(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLRenderPipelineState> ps, id<MTLTexture> tex, float *out) {
    NSUInteger w = tex.width, h = tex.height;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:d];
    id<MTLBuffer> buf = [dev newBufferWithLength:w * h * 16 options:MTLResourceStorageModeShared];
    if (!rt || !buf) return -1;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:ps]; [e setFragmentTexture:tex atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:w * 16 destinationBytesPerImage:w * h * 16];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "gpu read failed: %s\n", cb.error.localizedDescription.UTF8String); return -1; }
    memcpy(out, buf.contents, w * h * 16);
    return 0;
}

static int near(float a, float b, float tol) {
    float d = a - b; if (d < 0) d = -d;
    float s = fabsf(a) > fabsf(b) ? fabsf(a) : fabsf(b);
    return d <= tol || d <= s * 0.02f;
}

int main(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev || ![dev supportsBCTextureCompression]) { fprintf(stderr, "need a GPU with BC\n"); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_msl) options:nil error:&err];
    id<MTLFunction> vs = [lib newFunctionWithName:@"vs"], fs = [lib newFunctionWithName:@"fs"];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = vs; pd.fragmentFunction = fs; pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) { fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }

    struct { int nvn; MTLPixelFormat bc, plain; int bpb; const char *name; int ch; } F[] = {
        {0x42, MTLPixelFormatBC1_RGBA, MTLPixelFormatRGBA8Unorm, 8, "BC1", 4},
        {0x46, MTLPixelFormatBC1_RGBA_sRGB, MTLPixelFormatRGBA8Unorm_sRGB, 8, "BC1s", 4},
        {0x43, MTLPixelFormatBC2_RGBA, MTLPixelFormatRGBA8Unorm, 16, "BC2", 4},
        {0x44, MTLPixelFormatBC3_RGBA, MTLPixelFormatRGBA8Unorm, 16, "BC3", 4},
        {0x48, MTLPixelFormatBC3_RGBA_sRGB, MTLPixelFormatRGBA8Unorm_sRGB, 16, "BC3s", 4},
        {0x49, MTLPixelFormatBC4_RUnorm, MTLPixelFormatR8Unorm, 8, "BC4", 1},
        {0x4A, MTLPixelFormatBC4_RSnorm, MTLPixelFormatR8Snorm, 8, "BC4s", 1},
        {0x4B, MTLPixelFormatBC5_RGUnorm, MTLPixelFormatRG8Unorm, 16, "BC5", 2},
        {0x4C, MTLPixelFormatBC5_RGSnorm, MTLPixelFormatRG8Snorm, 16, "BC5s", 2},
        {0x4D, MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatRGBA8Unorm, 16, "BC7", 4},
        {0x4E, MTLPixelFormatBC7_RGBAUnorm_sRGB, MTLPixelFormatRGBA8Unorm_sRGB, 16, "BC7s", 4},
        {0x4F, MTLPixelFormatBC6H_RGBFloat, MTLPixelFormatRGBA16Float, 16, "BC6s", 3},
        {0x50, MTLPixelFormatBC6H_RGBUfloat, MTLPixelFormatRGBA16Float, 16, "BC6u", 3},
    };
    int failed = 0;
    const uint32_t W = 8, H = 8;
    for (unsigned fi = 0; fi < sizeof F / sizeof *F; fi++) {
        rnd_state = 0xC0FFEEu + fi * 17;
        size_t pitch = 2 * F[fi].bpb, blocks = pitch * 2;
        uint8_t *src = calloc(1, blocks);
        for (size_t i = 0; i < blocks; i++) src[i] = (uint8_t)rnd();
        if (F[fi].nvn == 0x4D || F[fi].nvn == 0x4E) src[0] |= 1;   // a legal BC7 mode bit
        uint32_t mtl = 0; int bpp = 0;
        if (!bc_soft_mtl(F[fi].nvn, &mtl, &bpp) || (int)F[fi].plain != (int)mtl) {
            printf("%s: format map %u vs %lu\n", F[fi].name, mtl, (unsigned long)F[fi].plain); failed++; free(src); continue;
        }
        uint8_t *dec = calloc(1, (size_t)W * bpp * H);
        if (bc_decode_level(F[fi].nvn, src, pitch, dec, (size_t)W * bpp, W, H, 1)) {
            printf("%s: decode failed\n", F[fi].name); failed++; free(src); free(dec); continue;
        }
        MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[fi].bc width:W height:H mipmapped:NO];
        bd.usage = MTLTextureUsageShaderRead; bd.storageMode = MTLStorageModeShared;
        MTLTextureDescriptor *pdsc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[fi].plain width:W height:H mipmapped:NO];
        pdsc.usage = MTLTextureUsageShaderRead; pdsc.storageMode = MTLStorageModeShared;
        id<MTLTexture> bt = [dev newTextureWithDescriptor:bd], pt = [dev newTextureWithDescriptor:pdsc];
        if (!bt || !pt) { printf("%s: texture create failed\n", F[fi].name); failed++; free(src); free(dec); continue; }
        [bt replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:src bytesPerRow:pitch];
        [pt replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:dec bytesPerRow:(NSUInteger)W * bpp];
        float *hb = malloc(W * H * 16), *hp = malloc(W * H * 16);
        if (readback(dev, q, ps, bt, hb) || readback(dev, q, ps, pt, hp)) { printf("%s: readback failed\n", F[fi].name); failed++; }
        else {
            int bad = 0, shown = 0; float worst = 0; int worst_codes = 0;
            int snorm = (F[fi].nvn == 0x4A || F[fi].nvn == 0x4C);
            for (uint32_t i = 0; i < W * H; i++) for (int c = 0; c < F[fi].ch; c++) {
                float a = hb[i * 4 + c], b = hp[i * 4 + c];
                float d = a - b; if (d < 0) d = -d; if (d > worst) worst = d;
                int scale = snorm ? 127 : 255;
                int ca0 = (int)lroundf(a * scale), cb0 = (int)lroundf(b * scale), cd0 = ca0 - cb0; if (cd0 < 0) cd0 = -cd0; if (cd0 > worst_codes) worst_codes = cd0;
                float tol = (F[fi].nvn == 0x4F || F[fi].nvn == 0x50) ? 0.05f : snorm ? 1.5f / 127.f : 2.f / 255.f;
                if (!near(a, b, tol)) {
                    bad++;
                    int ca = (int)lroundf(a * (snorm ? 127.f : 255.f)), cb = (int)lroundf(b * (snorm ? 127.f : 255.f));
                    int cd = ca - cb; if (cd < 0) cd = -cd; if (cd > worst_codes) worst_codes = cd;
                    if (shown < 4) { printf("  pix %u ch %d hw %.5f cpu %.5f codes %d %d\n", i, c, a, b, ca, cb); shown++; }
                }
            }
            uint8_t *edge = calloc(1, 5u * bpp * 3u);
            int er = bc_decode_level(F[fi].nvn, src, pitch, edge, 5u * bpp, 5, 3, 1);
            int ebad = er;
            if (!er) {
                MTLTextureDescriptor *ed = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:F[fi].plain width:5 height:3 mipmapped:NO];
                ed.usage = MTLTextureUsageShaderRead; ed.storageMode = MTLStorageModeShared;
                id<MTLTexture> et = [dev newTextureWithDescriptor:ed];
                [et replaceRegion:MTLRegionMake2D(0, 0, 5, 3) mipmapLevel:0 withBytes:edge bytesPerRow:5u * bpp];
                float *he = malloc(5 * 3 * 16);
                if (!et || readback(dev, q, ps, et, he)) ebad = 1;
                else for (uint32_t y = 0; y < 3; y++) for (uint32_t x = 0; x < 5; x++) for (int c = 0; c < F[fi].ch; c++) {
                    float a = hb[(y * W + x) * 4 + c], b = he[(y * 5 + x) * 4 + c];
                    float tol = (F[fi].nvn == 0x4F || F[fi].nvn == 0x50) ? 0.05f : (F[fi].nvn == 0x4A || F[fi].nvn == 0x4C) ? 1.5f / 127.f : 2.f / 255.f;
                    if (!near(a, b, tol)) ebad++;
                }
                free(he);
            }
            printf("%s: %s  worst %.5f  codes %d  edge %s\n", F[fi].name, bad ? "MISMATCH" : "ok", worst, worst_codes, ebad ? "MISMATCH" : "ok");
            if (bad || ebad) failed++;
            free(edge);
        }
        free(hb); free(hp); free(src); free(dec);
    }
    printf("%s\n", failed ? "FAILED" : "all BC formats match the hardware decoder");
    return failed ? 1 : 0;
}
