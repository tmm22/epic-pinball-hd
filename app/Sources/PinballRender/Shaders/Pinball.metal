// Epic Pinball remake - Metal shaders.
//
// Compiled at runtime from source (MTLDevice.makeLibrary(source:)), so plain
// `swift build` does not need the offline Metal toolchain.
//
// Two passes:
//   1. scene_fragment   : native resolution (320 x rows). Reads the R8Uint
//                         playfield index texture, looks the index up in the
//                         256-entry palette texture, then draws the flipper
//                         sprite frames (RGBA atlas) and the composited ball
//                         (palette indices). Procedural shapes only as fallback.
//                         The classic composer's VRAM (lamp overlays, flipper
//                         frames, plunger) is already in the index texture; the
//                         window dot-message overlay (DAC 255) is drawn last.
//   2. present_*        : upscales the native screen into the drawable's
//                         integer-scaled viewport: the window rows come from the
//                         pass-1 frame, the rows below it from the display strip
//                         (palette indices). Filters: present_nearest (classic),
//                         present_epx ("xbrz-like" placeholder), present_crt
//                         (see UpscaleFilter in Renderer.swift).
//
// Keep the struct layouts in sync with Renderer.swift (float4-only on purpose).

#include <metal_stdlib>
using namespace metal;

struct SceneUniforms {
    float4 view;             // x: first source row, y: rows rendered, z: table width, w: table height
    float4 ball;             // xy: top-left of the ball box (table px), zw: box size
    float4 ballInfo;         // x: 0 hidden, 1 indexed sprite (ballPixels), 2 procedural
    float4 flipperRect[4];   // xy: top-left, zw: size (table px) of the sprite rectangle
    float4 flipperInfo[4];   // x: 0 none, 1 atlas sprite, 2 procedural capsule; y: atlas row of the frame; z: capsule radius
    float4 capsule[4];       // xy: one end, zw: other end (table px), procedural fallback
    uint4  ballPixels[14];   // 15x14 palette indices, 4 per uint (little endian), 0 = transparent
    float4 overlayInfo;      // x: 1 = draw the window dot overlay, y: overlay rows
};

struct PresentUniforms {
    float4 dst;   // xy: viewport origin (output px), zw: output px per source px (x, y)
    float4 src;   // x: source width, y: visible window rows, z: fractional row offset, w: unused
    float4 strip; // x: strip rows visible below the window (0 = none)
};

struct VSOut {
    float4 position [[position]];
};

// One oversized triangle covering the viewport.
vertex VSOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float sd_capsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

static float coverage(float d) { return clamp(0.5 - d, 0.0, 1.0); }

static uint ball_index(constant SceneUniforms &u, uint i) {
    uint word = u.ballPixels[i >> 4][(i >> 2) & 3];
    return (word >> ((i & 3) * 8)) & 0xFF;
}

fragment float4 scene_fragment(VSOut in [[stage_in]],
                               constant SceneUniforms &u [[buffer(0)]],
                               texture2d<uint, access::read> indices [[texture(0)]],
                               texture1d<float, access::read> palette [[texture(1)]],
                               texture2d<float, access::read> atlas [[texture(2)]],
                               texture2d<uint, access::read> overlay [[texture(3)]]) {
    uint2 pix = uint2(in.position.xy);
    int tableW = int(u.view.z), tableH = int(u.view.w);
    int ty = clamp(int(u.view.x) + int(pix.y), 0, tableH - 1);
    int tx = clamp(int(pix.x), 0, tableW - 1);
    uint idx = indices.read(uint2(tx, ty)).r;
    float3 color = palette.read(idx).rgb;
    float2 p = float2(tx, ty) + 0.5;  // pixel centre in table coordinates

    // Flippers: the game's own opaque sprite frames (background baked in), else a capsule.
    for (int i = 0; i < 4; i++) {
        float mode = u.flipperInfo[i].x;
        if (mode > 0.5 && mode < 1.5) {
            int2 local = int2(tx, ty) - int2(u.flipperRect[i].xy);
            int2 size = int2(u.flipperRect[i].zw);
            if (local.x >= 0 && local.y >= 0 && local.x < size.x && local.y < size.y) {
                float4 c = atlas.read(uint2(local.x, int(u.flipperInfo[i].y) + local.y));
                if (c.a > 0.5) { color = c.rgb; }
            }
        } else if (mode > 1.5) {
            float d = sd_capsule(p, u.capsule[i].xy, u.capsule[i].zw, u.flipperInfo[i].z);
            float3 fill = mix(float3(0.95, 0.93, 0.86), float3(0.80, 0.10, 0.08), smoothstep(-1.6, -0.6, d));
            color = mix(color, fill, coverage(d));
        }
    }

    // Ball: composited 15x14 index sprite (occluders already merged on the CPU), key 0.
    if (u.ballInfo.x > 0.5 && u.ballInfo.x < 1.5) {
        int2 local = int2(floor(float2(tx, ty) - u.ball.xy));
        int2 size = int2(u.ball.zw);
        if (local.x >= 0 && local.y >= 0 && local.x < size.x && local.y < size.y) {
            uint bi = ball_index(u, uint(local.y * size.x + local.x));
            if (bi != 0) { color = palette.read(bi).rgb; }
        }
    } else if (u.ballInfo.x > 1.5) {
        float2 c = u.ball.xy + u.ball.zw * 0.5;
        float r = min(u.ball.z, u.ball.w) * 0.5;
        float2 rel = p - c;
        float d = length(rel) - r;
        float2 n2 = rel / max(r, 1e-3);
        float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
        float3 l = normalize(float3(-0.5, -0.6, 0.65));
        float diff = max(dot(n, l), 0.0);
        float spec = pow(max(dot(reflect(-l, n), float3(0, 0, 1)), 0.0), 12.0);
        float3 steel = float3(0.35, 0.37, 0.42) + 0.55 * diff + 0.6 * spec;
        color = mix(color, clamp(steel, 0.0, 1.0), coverage(d));
    }

    // Dot messages: window-relative, plotted on top of everything (render_frame cs:43D5).
    if (u.overlayInfo.x > 0.5 && float(pix.y) < u.overlayInfo.y) {
        uint o = overlay.read(uint2(tx, pix.y)).r;
        if (o != 0) { color = palette.read(o).rgb; }
    }
    return float4(color, 1.0);
}

// ---- present pass -------------------------------------------------------------

#define PRESENT_TEX texture2d<float, access::read> frame, texture2d<uint, access::read> strip, texture1d<float, access::read> palette
#define PRESENT_ARGS frame, strip, palette

// Screen position (source px, 320 x (window + strip)) of this output pixel.
static float2 screen_pos(float4 pos, constant PresentUniforms &u) {
    return (pos.xy - u.dst.xy) / u.dst.zw;
}

// Colour of source pixel p (integer screen coordinates). Window rows are shifted by the
// fractional scroll offset `u.src.z` (only non-zero in enhanced mode), strip rows are not.
static float4 fetch(int2 p, float fracRow, constant PresentUniforms &u, PRESENT_TEX) {
    int wr = int(u.src.y), sr = int(u.strip.x);
    p.x = clamp(p.x, 0, int(u.src.x) - 1);
    if (sr > 0 && p.y >= wr) {
        int sy = clamp(p.y - wr, 0, sr - 1);
        return float4(palette.read(strip.read(uint2(p.x, sy)).r).rgb, 1.0);
    }
    int fy = clamp(int(floor(float(p.y) + fracRow)), 0, int(frame.get_height()) - 1);
    return frame.read(uint2(p.x, fy));
}

static float4 nearest_at(float2 local, constant PresentUniforms &u, PRESENT_TEX) {
    int wr = int(u.src.y);
    if (u.strip.x > 0.5 && local.y >= float(wr)) {
        return fetch(int2(floor(local)), 0.0, u, PRESENT_ARGS);
    }
    // Window: sample at local.y + frac (fetch floors the sum).
    return fetch(int2(int(floor(local.x)), int(floor(local.y))), fract(local.y) + u.src.z, u, PRESENT_ARGS);
}

// Nearest-neighbour integer upscale (classic).
fragment float4 present_nearest(VSOut in [[stage_in]],
                                constant PresentUniforms &u [[buffer(0)]],
                                texture2d<float, access::read> frame [[texture(0)]],
                                texture2d<uint, access::read> strip [[texture(1)]],
                                texture1d<float, access::read> palette [[texture(2)]]) {
    return nearest_at(screen_pos(in.position, u), u, PRESENT_ARGS);
}

static bool eq(float4 a, float4 b) { return all(abs(a.rgb - b.rgb) < 0.002); }

// "xbrz-like" placeholder: Scale2x/EPX rules evaluated per output pixel, so edges get
// 2x-resolution diagonals at any integer scale >= 2. Enhanced-mode groundwork only.
fragment float4 present_epx(VSOut in [[stage_in]],
                            constant PresentUniforms &u [[buffer(0)]],
                            texture2d<float, access::read> frame [[texture(0)]],
                            texture2d<uint, access::read> strip [[texture(1)]],
                            texture1d<float, access::read> palette [[texture(2)]]) {
    float2 local = screen_pos(in.position, u);
    if (u.dst.z < 1.5) { return nearest_at(local, u, PRESENT_ARGS); }
    int wr = int(u.src.y);
    bool inStrip = u.strip.x > 0.5 && local.y >= float(wr);
    float fr = inStrip ? 0.0 : u.src.z;
    // Work in the (possibly shifted) sampling space so window pixels stay aligned.
    float2 s = float2(local.x, local.y + fr);
    int2 p = int2(floor(s));
    float2 f = fract(s);
    float4 P = fetch(p, 0.0, u, PRESENT_ARGS);
    float4 A = fetch(p + int2(0, -1), 0.0, u, PRESENT_ARGS), B = fetch(p + int2(1, 0), 0.0, u, PRESENT_ARGS);
    float4 C = fetch(p + int2(-1, 0), 0.0, u, PRESENT_ARGS), D = fetch(p + int2(0, 1), 0.0, u, PRESENT_ARGS);
    if (f.x < 0.5 && f.y < 0.5) { return (eq(C, A) && !eq(C, D) && !eq(A, B)) ? A : P; }
    if (f.x >= 0.5 && f.y < 0.5) { return (eq(A, B) && !eq(A, C) && !eq(B, D)) ? B : P; }
    if (f.x < 0.5) { return (eq(D, C) && !eq(D, B) && !eq(C, A)) ? C : P; }
    return (eq(B, D) && !eq(B, A) && !eq(D, C)) ? D : P;
}

// CRT: nearest source pixel, darkened towards the edges of each source row (scanlines)
// and a light RGB aperture mask across output pixels.
fragment float4 present_crt(VSOut in [[stage_in]],
                            constant PresentUniforms &u [[buffer(0)]],
                            texture2d<float, access::read> frame [[texture(0)]],
                            texture2d<uint, access::read> strip [[texture(1)]],
                            texture1d<float, access::read> palette [[texture(2)]]) {
    float2 local = screen_pos(in.position, u);
    float4 c = nearest_at(local, u, PRESENT_ARGS);
    if (u.dst.w < 2.5) { return c; }
    float fy = fract(local.y) * 2.0 - 1.0;
    float scan = mix(1.0, 0.55, fy * fy);
    int m = int(in.position.x) % 3;
    float3 mask = float3(m == 0 ? 1.0 : 0.85, m == 1 ? 1.0 : 0.85, m == 2 ? 1.0 : 0.85);
    return float4(clamp(c.rgb * scan * mask * 1.15, 0.0, 1.0), 1.0);
}

// =============================================================================
// Enhanced pipeline (docs/enhanced/rendering.md). Classic mode (nearest, no HD pack,
// no lighting, no interpolation, integer scale) never runs anything below.
//
//   scene_enhanced / scene_hd : window rows at native / HD-pack resolution without the
//                               ball and the dot messages (those are output-resolution
//                               layers), flipper cross-fade for high refresh, and (HD) the
//                               per-pixel palette delta so palette effects still apply.
//   strip_rgb                 : display strip indices -> RGBA (native).
//   xbrz_prepass (compute)    : xBRZ corner analysis, 2 bits per corner per 2x2 block.
//   glow_emissive / glow_blur : lamp emissive mask -> separable Gaussian (native res).
//   quad_*                    : HD VRAM replay and HD strip composition.
//   present_enhanced          : filter (nearest/sharp, bicubic, xBRZ freescale, CRT) of
//                               window + strip, then shadow, ball, dots, glow, CRT post.
// =============================================================================

struct EnhSceneUniforms {
    float4 view;          // x: first table row, y: rows rendered, z: HD scale S (1 = native), w: flipper cross-fade alpha
    float4 flipRect[4];   // xy: top-left, zw: size (table px)
    float4 flipInfo[4];   // x: 1 = cross-fade, y: atlas row of the previous frame, z: atlas row of the current frame
};

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

fragment float4 scene_enhanced(VSOut in [[stage_in]],
                               constant EnhSceneUniforms &u [[buffer(0)]],
                               texture2d<uint, access::read> indices [[texture(0)]],
                               texture1d<float, access::read> palette [[texture(1)]],
                               texture2d<uint, access::read> flipAtlas [[texture(2)]]) {
    uint2 pix = uint2(in.position.xy);
    int ty = clamp(int(u.view.x) + int(pix.y), 0, 399);
    int tx = clamp(int(pix.x), 0, 319);
    uint idx = indices.read(uint2(tx, ty)).r;
    float3 c = palette.read(idx).rgb;
    for (int i = 0; i < 4; i++) {
        if (u.flipInfo[i].x < 0.5) { continue; }
        int2 local = int2(tx, ty) - int2(u.flipRect[i].xy);
        int2 size = int2(u.flipRect[i].zw);
        if (local.x < 0 || local.y < 0 || local.x >= size.x || local.y >= size.y) { continue; }
        uint cur = flipAtlas.read(uint2(local.x, int(u.flipInfo[i].z) + local.y)).r;
        if (cur != idx) { continue; }   // something was blitted over the flipper here
        uint prev = flipAtlas.read(uint2(local.x, int(u.flipInfo[i].y) + local.y)).r;
        c = mix(palette.read(prev).rgb, c, u.view.w);
    }
    return float4(c, 1.0);
}

fragment float4 scene_hd(VSOut in [[stage_in]],
                         constant EnhSceneUniforms &u [[buffer(0)]],
                         texture2d<float, access::read> hdVram [[texture(0)]],
                         texture2d<uint, access::read> indices [[texture(1)]],
                         texture1d<float, access::read> palette [[texture(2)]],
                         texture1d<float, access::read> basePalette [[texture(3)]],
                         texture2d<uint, access::read> flipAtlas [[texture(4)]],
                         texture2d<float, access::read> flipAtlasHD [[texture(5)]]) {
    int S = int(u.view.z);
    uint2 pix = uint2(in.position.xy);
    int hy = clamp(int(u.view.x) * S + int(pix.y), 0, 400 * S - 1);
    int hx = clamp(int(pix.x), 0, 320 * S - 1);
    float3 c = hdVram.read(uint2(hx, hy)).rgb;
    int tx = hx / S, ty = hy / S;
    uint idx = indices.read(uint2(tx, ty)).r;
    for (int i = 0; i < 4; i++) {
        if (u.flipInfo[i].x < 0.5) { continue; }
        int2 local = int2(tx, ty) - int2(u.flipRect[i].xy);
        int2 size = int2(u.flipRect[i].zw);
        if (local.x < 0 || local.y < 0 || local.x >= size.x || local.y >= size.y) { continue; }
        uint cur = flipAtlas.read(uint2(local.x, int(u.flipInfo[i].z) + local.y)).r;
        if (cur != idx) { continue; }
        int2 lh = int2(hx, hy) - int2(u.flipRect[i].xy) * S;
        float3 prev = flipAtlasHD.read(uint2(lh.x, int(u.flipInfo[i].y) * S + lh.y)).rgb;
        c = mix(prev, c, u.view.w);
    }
    // The pack is drawn in the base palette's colours; palette effects (lamp colours,
    // EP8's ring, DAC 255) shift the HD colour by the change of the pixel's native entry.
    float3 delta = palette.read(idx).rgb - basePalette.read(idx).rgb;
    return float4(clamp(c + delta, 0.0, 1.0), 1.0);
}

fragment float4 strip_rgb(VSOut in [[stage_in]],
                          texture2d<uint, access::read> strip [[texture(0)]],
                          texture1d<float, access::read> palette [[texture(1)]]) {
    uint2 pix = uint2(in.position.xy);
    return float4(palette.read(strip.read(pix).r).rgb, 1.0);
}

// ---- xBRZ (after Zenju's xBRZ: same corner analysis and line rules, evaluated
// scale-free per output pixel with analytic anti-aliasing) ----------------------

constant float XBRZ_EQ_TOL = 30.0;     // equal colour tolerance (YCbCr distance, 0-255)
constant float XBRZ_DOMINANT = 3.6;    // dominant direction threshold
constant float XBRZ_STEEP = 2.2;       // steep / shallow line threshold
constant float XBRZ_CENTRE_W = 4.0;    // centre pair weight in the gradient sums

// YCbCr (BT.2020 luma) distance on the 0-255 scale; alpha-aware (xBRZ's ARGB rule).
// Colours are premultiplied where alpha is used (only the ball texture).
static float ycc_dist(float4 a, float4 b) {
    float3 d = (a.rgb - b.rgb) * 255.0;
    const float kb = 0.0593, kr = 0.2627, kg = 1.0 - 0.0593 - 0.2627;
    float y = kr * d.r + kg * d.g + kb * d.b;
    float cb = 0.5 / (1.0 - kb) * (d.b - y);
    float cr = 0.5 / (1.0 - kr) * (d.r - y);
    float dist = sqrt(y * y + cb * cb + cr * cr);
    float a1 = a.a, a2 = b.a;
    return a1 < a2 ? a1 * dist + 255.0 * (a2 - a1) : a2 * dist + 255.0 * (a1 - a2);
}
static bool same(float4 a, float4 b) { return all(a == b); }
static bool near_eq(float4 a, float4 b) { return ycc_dist(a, b) < XBRZ_EQ_TOL; }

template <typename T>
static float4 px_at(T t, int2 q, int2 mx) {
    return t.read(uint2(clamp(q, int2(0), mx)));
}

// Block texel (x+1, y+1) describes the 2x2 block whose top-left pixel is (x, y):
// bits 0-1 bottom-right corner of the top-left pixel (F), 2-3 bottom-left of the
// top-right pixel (G), 4-5 top-right of the bottom-left pixel (J), 6-7 top-left of the
// bottom-right pixel (K); 0 none, 1 normal, 2 dominant.
kernel void xbrz_prepass(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<uint, access::write> dst [[texture(1)]],
                         constant int4 &size [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) > size.x || int(gid.y) > size.y) { return; }
    int2 f = int2(gid) - 1;
    int2 mx = size.xy - 1;
    float4 b = px_at(src, f + int2(0, -1), mx), c = px_at(src, f + int2(1, -1), mx);
    float4 e = px_at(src, f + int2(-1, 0), mx), F = px_at(src, f, mx);
    float4 g = px_at(src, f + int2(1, 0), mx), h = px_at(src, f + int2(2, 0), mx);
    float4 i = px_at(src, f + int2(-1, 1), mx), j = px_at(src, f + int2(0, 1), mx);
    float4 k = px_at(src, f + int2(1, 1), mx), l = px_at(src, f + int2(2, 1), mx);
    float4 n = px_at(src, f + int2(0, 2), mx), o = px_at(src, f + int2(1, 2), mx);
    uint res = 0u;
    bool fg = same(F, g), jk = same(j, k), fj = same(F, j), gk = same(g, k);
    if (!((fg && jk) || (fj && gk))) {
        float jg = ycc_dist(i, F) + ycc_dist(F, c) + ycc_dist(n, k) + ycc_dist(k, h) + XBRZ_CENTRE_W * ycc_dist(j, g);
        float fk = ycc_dist(e, j) + ycc_dist(j, o) + ycc_dist(b, g) + ycc_dist(g, l) + XBRZ_CENTRE_W * ycc_dist(F, k);
        if (jg < fk) {
            uint t = XBRZ_DOMINANT * jg < fk ? 2u : 1u;
            if (!fg && !fj) { res |= t; }
            if (!jk && !gk) { res |= t << 6; }
        } else if (fk < jg) {
            uint t = XBRZ_DOMINANT * fk < jg ? 2u : 1u;
            if (!fj && !jk) { res |= t << 4; }
            if (!fg && !gk) { res |= t << 2; }
        }
    }
    dst.write(uint4(res, 0, 0, 0), gid);
}

// Coverage of the half-plane dot(n, uv) > c inside the pixel, anti-aliased over one
// output pixel (`sc` = output pixels per source pixel).
static float half_plane(float2 uv, float2 n, float c, float sc) {
    return clamp((dot(n, uv) - c) / length(n) * sc + 0.5, 0.0, 1.0);
}

// xBRZ at an arbitrary scale: `pos` in source pixels (continuous), mx = last texel.
template <typename T>
static float4 xbrz_sample(T src, texture2d<uint, access::read> blend, int2 mx, float2 pos, float sc) {
    int2 p = int2(floor(pos));
    p = clamp(p, int2(0), mx);
    float2 f = pos - float2(p) - 0.5;
    int2 bmx = mx + 1;
    uint bBR = blend.read(uint2(clamp(p + 1, int2(0), bmx))).r & 3u;
    uint bBL = (blend.read(uint2(clamp(p + int2(0, 1), int2(0), bmx))).r >> 2) & 3u;
    uint bTR = (blend.read(uint2(clamp(p + int2(1, 0), int2(0), bmx))).r >> 4) & 3u;
    uint bTL = (blend.read(uint2(clamp(p, int2(0), bmx))).r >> 6) & 3u;
    float4 E = px_at(src, p, mx);
    if ((bBR | bBL | bTR | bTL) == 0u) { return E; }
    float4 res = E;
    for (int rot = 0; rot < 4; rot++) {
        // Rotated frame: r = "right", d = "down"; the corner handled is r + d.
        int2 r, d; uint bc, btr, bbl;
        if (rot == 0)      { r = int2(1, 0);  d = int2(0, 1);  bc = bBR; btr = bTR; bbl = bBL; }
        else if (rot == 1) { r = int2(0, 1);  d = int2(-1, 0); bc = bBL; btr = bBR; bbl = bTL; }
        else if (rot == 2) { r = int2(-1, 0); d = int2(0, -1); bc = bTL; btr = bBL; bbl = bTR; }
        else               { r = int2(0, -1); d = int2(1, 0);  bc = bTR; btr = bTL; bbl = bBR; }
        if (bc == 0u) { continue; }
        float4 B = px_at(src, p - d, mx), C = px_at(src, p + r - d, mx), D = px_at(src, p - r, mx);
        float4 F = px_at(src, p + r, mx), G = px_at(src, p - r + d, mx), H = px_at(src, p + d, mx);
        float4 I = px_at(src, p + r + d, mx);
        bool line;
        if (bc >= 2u) { line = true; }
        else if (btr != 0u && !near_eq(E, G)) { line = false; }       // no double blend (insular pixels)
        else if (bbl != 0u && !near_eq(E, C)) { line = false; }
        else if (!near_eq(E, I) && near_eq(G, H) && near_eq(H, I) && near_eq(I, F) && near_eq(F, C)) { line = false; }  // L-shapes: corner only
        else { line = true; }
        float4 col = ycc_dist(E, F) <= ycc_dist(E, H) ? F : H;
        float2 uv = float2(dot(f, float2(r)), dot(f, float2(d)));
        float cov;
        if (line) {
            float fg = ycc_dist(F, G), hc = ycc_dist(H, C);
            bool shallow = XBRZ_STEEP * fg <= hc && !same(E, G) && !same(D, G);
            bool steep = XBRZ_STEEP * hc <= fg && !same(E, C) && !same(B, C);
            float cs = half_plane(uv, float2(0.5, 1.0), 0.25, sc);   // (-1/2, 1/2) .. (1/2, 0)
            float ct = half_plane(uv, float2(1.0, 0.5), 0.25, sc);   // (1/2, -1/2) .. (0, 1/2)
            if (shallow && steep) { cov = max(cs, ct); }
            else if (shallow) { cov = cs; }
            else if (steep) { cov = ct; }
            else { cov = half_plane(uv, float2(1.0, 1.0), 0.5, sc); }  // 45 degree diagonal
        } else {
            // Corner only: the part of the corner quadrant outside the inscribed circle.
            cov = (uv.x > 0.0 && uv.y > 0.0) ? clamp((length(uv) - 0.5) * sc + 0.5, 0.0, 1.0) : 0.0;
        }
        res = mix(res, col, cov);
    }
    return res;
}

// ---- resampling helpers -------------------------------------------------------
// Hardware bilinear taps on texel-space positions; `lim` is the last valid texel centre, so
// taps never reach rows beyond those rendered this frame (clamp = edge replicate).

static float4 tap(texture2d<float, access::sample> t, sampler s, float2 p, float2 lim, float2 inv) {
    return t.sample(s, clamp(p, float2(0.5), lim) * inv);
}

// Sharp bilinear: nearest inside texels, a one-output-pixel linear transition at texel
// edges; one tap (weights are exactly 0/1 at integer scales, i.e. nearest).
static float4 sharp_bilinear(texture2d<float, access::sample> t, sampler s, float2 pos, float2 sc, float2 lim, float2 inv) {
    float2 p = pos - 0.5;
    float2 i = floor(p);
    float2 w = clamp((p - i - 0.5) * sc + 0.5, 0.0, 1.0);
    return tap(t, s, i + 0.5 + w, lim, inv);
}

// Catmull-Rom bicubic in 9 bilinear taps (the two middle taps per axis merged).
static float4 bicubic(texture2d<float, access::sample> t, sampler s, float2 pos, float2 lim, float2 inv) {
    float2 p = pos - 0.5;
    float2 i = floor(p);
    float2 f = p - i;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 c = i + 0.5;
    float2 p0 = c - 1.0, p3 = c + 2.0, p12 = c + w2 / w12;
    float4 r = tap(t, s, float2(p0.x, p0.y), lim, inv) * (w0.x * w0.y)
             + tap(t, s, float2(p12.x, p0.y), lim, inv) * (w12.x * w0.y)
             + tap(t, s, float2(p3.x, p0.y), lim, inv) * (w3.x * w0.y)
             + tap(t, s, float2(p0.x, p12.y), lim, inv) * (w0.x * w12.y)
             + tap(t, s, float2(p12.x, p12.y), lim, inv) * (w12.x * w12.y)
             + tap(t, s, float2(p3.x, p12.y), lim, inv) * (w3.x * w12.y)
             + tap(t, s, float2(p0.x, p3.y), lim, inv) * (w0.x * w3.y)
             + tap(t, s, float2(p12.x, p3.y), lim, inv) * (w12.x * w3.y)
             + tap(t, s, float2(p3.x, p3.y), lim, inv) * (w3.x * w3.y);
    return clamp(r, 0.0, 1.0);
}

// CRT beam: horizontally a Catmull-Rom sample along the source row (3 taps), vertically the
// row itself; the scanline profile is applied after composition.
static float4 crt_row(texture2d<float, access::sample> t, sampler s, float2 pos, float2 lim, float2 inv) {
    float y = floor(pos.y) + 0.5;
    float p = pos.x - 0.5;
    float i = floor(p), f = p - i;
    float w0 = f * (-0.5 + f * (1.0 - 0.5 * f)), w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float w2 = f * (0.5 + f * (2.0 - 1.5 * f)), w3 = f * f * (-0.5 + 0.5 * f);
    float c = i + 0.5, w12 = w1 + w2;
    float4 r = tap(t, s, float2(c - 1.0, y), lim, inv) * w0 + tap(t, s, float2(c + w2 / w12, y), lim, inv) * w12
             + tap(t, s, float2(c + 2.0, y), lim, inv) * w3;
    return clamp(r, 0.0, 1.0);
}

// ---- lighting -----------------------------------------------------------------

// Emissive colour at native resolution for the rendered window rows: lit lamp pixels
// (mask from the CPU: how much brighter the shown overlay is than its other record) and
// palette entries brightened by this frame's overrides.
kernel void glow_emissive(texture2d<uint, access::read> indices [[texture(0)]],
                          texture1d<float, access::read> palette [[texture(1)]],
                          texture1d<float, access::read> basePalette [[texture(2)]],
                          texture2d<float, access::read> lampMask [[texture(3)]],
                          texture2d<float, access::write> dst [[texture(4)]],
                          constant float4 &u [[buffer(0)]],   // x: first table row, y: rows, z: lamp gain, w: palette gain
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    int ty = clamp(int(u.x) + int(gid.y), 0, 399);
    uint2 t = uint2(gid.x, ty);
    uint idx = indices.read(t).r;
    float3 c = palette.read(idx).rgb, b = basePalette.read(idx).rgb;
    float w = lampMask.read(t).r * u.z * smoothstep(0.08, 0.55, luma(c));
    float pd = max(0.0, luma(c) - luma(b)) * u.w;
    dst.write(float4(c * (w + pd), 1.0), gid);
}

// Separable Gaussian (u.xy = direction, u.z = sigma, u.w = radius in texels).
kernel void glow_blur(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float4 &u [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    int2 mx = int2(src.get_width(), src.get_height()) - 1;
    int2 dir = int2(u.xy);
    int R = int(u.w);
    float inv = 1.0 / (2.0 * u.z * u.z);
    float4 acc = 0.0; float wsum = 0.0;
    for (int k = -R; k <= R; k++) {
        float w = exp(-float(k * k) * inv);
        acc += px_at(src, int2(gid) + dir * k, mx) * w;
        wsum += w;
    }
    dst.write(acc / wsum, gid);
}

// ---- HD VRAM replay / HD strip -----------------------------------------------------

struct QuadUniforms {
    float4 dst;     // x0, y0, x1, y1 in target pixels
    float4 target;  // xy: target size in pixels
    float4 src;     // xy: source texel of dst's top-left, zw: source texels per target pixel
    float4 tint;    // rgb: colour for masks / discs, a: disc radius (target px)
};

vertex VSOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &u [[buffer(0)]]) {
    const float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };
    float2 p = mix(u.dst.xy, u.dst.zw, corners[vid % 6]);
    VSOut o;
    o.position = float4(p.x / u.target.x * 2.0 - 1.0, 1.0 - p.y / u.target.y * 2.0, 0.0, 1.0);
    return o;
}

static uint2 quad_texel(float4 pos, constant QuadUniforms &u) {
    float2 t = u.src.xy + (floor(pos.xy) + 0.5 - u.dst.xy) * u.src.zw;
    return uint2(max(floor(t), 0.0));
}

fragment float4 quad_rgba(VSOut in [[stage_in]], constant QuadUniforms &u [[buffer(0)]],
                          texture2d<float, access::read> tex [[texture(0)]]) {
    return tex.read(quad_texel(in.position, u));
}

// Native indexed sprite (HD fallback): palette lookup, nearest.
fragment float4 quad_indexed(VSOut in [[stage_in]], constant QuadUniforms &u [[buffer(0)]],
                             texture2d<uint, access::read> tex [[texture(0)]],
                             texture1d<float, access::read> palette [[texture(1)]]) {
    return float4(palette.read(tex.read(quad_texel(in.position, u)).r).rgb, 1.0);
}

// Glyph coverage mask tinted with a palette colour (premultiplied, blended source-over).
fragment float4 quad_mask(VSOut in [[stage_in]], constant QuadUniforms &u [[buffer(0)]],
                          texture2d<float, access::read> tex [[texture(0)]]) {
    float a = tex.read(quad_texel(in.position, u)).r;
    return float4(u.tint.rgb * a, a);
}

// Round dot centred in the quad (premultiplied, blended source-over).
fragment float4 quad_disc(VSOut in [[stage_in]], constant QuadUniforms &u [[buffer(0)]]) {
    float2 c = (u.dst.xy + u.dst.zw) * 0.5;
    float d = length(in.position.xy - c);
    float a = clamp(u.tint.a - d + 0.5, 0.0, 1.0);
    return float4(u.tint.rgb * a, a);
}

// ---- present --------------------------------------------------------------------
// Specialised per configuration with function constants (dead paths compile away).

constant int  FC_FILTER    [[function_constant(0)]];   // 0 nearest (sharp), 1 smooth, 2 xbrz, 3 crt
constant bool FC_WIN_HD    [[function_constant(1)]];   // window texture is an HD-pack frame
constant bool FC_STRIP     [[function_constant(2)]];   // strip rows visible
constant bool FC_STRIP_HD  [[function_constant(3)]];
constant bool FC_LIGHT     [[function_constant(4)]];
constant int  FC_BALL      [[function_constant(5)]];   // 0 none, 1 texture, 2 procedural
constant bool FC_BALL_HD   [[function_constant(6)]];
constant bool FC_OCCLUSION [[function_constant(7)]];
constant bool FC_DOTS      [[function_constant(8)]];
constant bool FC_ROUND     [[function_constant(9)]];
constant bool FC_CURVE     [[function_constant(10)]];

struct EnhPresentUniforms {
    float4 dst;      // xy: viewport origin (output px), zw: output px per screen px (x, y)
    float4 src;      // x: screen width (320), y: window rows, z: fractional row offset, w: strip rows shown
    float4 mode;     // x: unused, y: window texture scale, z: strip texture scale, w: unused
    float4 frame;    // x: window texture rows (table px), y: first table row, z: overlay rows, w: unused
    float4 ball;     // xy: top-left (table px, interpolated), zw: box size
    float4 ballInfo; // x: unused, y: ball texture scale, z: occlusion level, w: texture padding (table px)
    float4 light;    // x: glow gain, y: shadow, z: specular, w: unused
    float4 crt;      // x: curvature, y: scanline depth, z: mask strength, w: unused
    float4 viewport; // xy: viewport size (output px), z: glow texture rows, w: unused
};

// One layer (window or strip): q in layer px (table px), S = texture px per layer px.
static float4 filter_layer(texture2d<float, access::sample> t, texture2d<uint, access::read> blend, sampler s,
                           float2 q, float2 layerSize, float S, bool hd, float2 sc) {
    float2 inv = 1.0 / float2(t.get_width(), t.get_height());
    float2 lim = layerSize * S - 0.5;
    if (hd) {
        // HD pack texture: resample the HD pixels (the pack replaces the upscaler).
        float2 hq = q * S, hsc = sc / S;
        if (FC_FILTER == 0) { return sharp_bilinear(t, s, hq, hsc, lim, inv); }
        if (FC_FILTER == 3) { return crt_row(t, s, float2(hq.x, (floor(q.y) + 0.5) * S), lim, inv); }
        return hsc.x >= 1.0 ? bicubic(t, s, hq, lim, inv) : sharp_bilinear(t, s, hq, max(hsc, 1.0), lim, inv);
    }
    if (FC_FILTER == 1) { return bicubic(t, s, q, lim, inv); }
    if (FC_FILTER == 2) { return xbrz_sample(t, blend, int2(layerSize) - 1, q, min(sc.x, sc.y)); }
    if (FC_FILTER == 3) { return crt_row(t, s, q, lim, inv); }
    return sharp_bilinear(t, s, q, sc, lim, inv);
}

// Premultiplied ball colour at ball-local position bl.
static float4 ball_layer(constant EnhPresentUniforms &u, float2 bl, float2 sc, sampler s,
                         texture2d<float, access::sample> ballTex, texture2d<uint, access::read> ballBlend) {
    if (FC_BALL == 2) {
        float2 c = u.ball.zw * 0.5;
        float r = min(u.ball.z, u.ball.w) * 0.5;
        float2 rel = bl - c;
        float d = length(rel) - r;
        float2 n2 = rel / max(r, 1e-3);
        float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
        float3 l = normalize(float3(-0.5, -0.6, 0.65));
        float3 steel = float3(0.35, 0.37, 0.42) + 0.55 * max(dot(n, l), 0.0);
        float a = clamp(0.5 - d * min(sc.x, sc.y), 0.0, 1.0);
        return float4(clamp(steel, 0.0, 1.0) * a, a);
    }
    float S = u.ballInfo.y;
    float2 size = float2(ballTex.get_width(), ballTex.get_height());
    float2 bq = (bl + u.ballInfo.w) * S;
    float2 inv = 1.0 / size, lim = size - 0.5, bsc = sc / S;
    if (FC_BALL_HD) { return bsc.x >= 1.0 ? bicubic(ballTex, s, bq, lim, inv) : sharp_bilinear(ballTex, s, bq, max(bsc, 1.0), lim, inv); }
    if (FC_FILTER == 1) { return bicubic(ballTex, s, bq, lim, inv); }
    if (FC_FILTER == 2) { return xbrz_sample(ballTex, ballBlend, int2(size) - 1, bq, min(sc.x, sc.y)); }
    return sharp_bilinear(ballTex, s, bq, sc, lim, inv);
}

fragment float4 present_enhanced(VSOut in [[stage_in]],
                                 constant EnhPresentUniforms &u [[buffer(0)]],
                                 texture2d<float, access::sample> frame [[texture(0)]],
                                 texture2d<uint, access::read> frameBlend [[texture(1)]],
                                 texture2d<float, access::sample> strip [[texture(2)]],
                                 texture2d<uint, access::read> stripBlend [[texture(3)]],
                                 texture2d<uint, access::read> overlay [[texture(4)]],
                                 texture1d<float, access::read> palette [[texture(5)]],
                                 texture2d<float, access::sample> glow [[texture(6)]],
                                 texture2d<uint, access::read> occlusion [[texture(7)]],
                                 texture2d<float, access::sample> ballTex [[texture(8)]],
                                 texture2d<uint, access::read> ballBlend [[texture(9)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 sc = u.dst.zw;
    float2 local = (in.position.xy - u.dst.xy) / u.dst.zw;   // screen px
    float screenH = u.src.y + u.src.w;
    float edge = 1.0;
    if (FC_CURVE) {
        // Subtle barrel curvature around the screen centre.
        float2 size = float2(u.src.x, screenH);
        float2 cc = local / size * 2.0 - 1.0;
        cc *= 1.0 + u.crt.x * float2(cc.y * cc.y, cc.x * cc.x);
        local = (cc + 1.0) * 0.5 * size;
        float2 m = min(local, size - local) * sc;
        edge = clamp(min(m.x, m.y), 0.0, 1.0);
        if (any(local < 0.0) || any(local >= size)) { return float4(0, 0, 0, 1); }
    }
    float3 color;
    if (FC_STRIP && local.y >= u.src.y) {
        float2 q = float2(local.x, local.y - u.src.y);
        color = filter_layer(strip, stripBlend, lin, q, float2(u.src.x, float(strip.get_height()) / u.mode.z),
                             u.mode.z, FC_STRIP_HD, sc).rgb;
    } else {
        float2 q = float2(local.x, local.y + u.src.z);       // window texture px (row 0 = first table row)
        float2 tp = float2(q.x, q.y + u.frame.y);            // table px
        color = filter_layer(frame, frameBlend, lin, q, float2(u.src.x, u.frame.x), u.mode.y, FC_WIN_HD, sc).rgb;
        float2 guv = float2(q.x / u.src.x, q.y / u.viewport.z);
        if (FC_LIGHT) { color += glow.sample(lin, guv).rgb * u.light.x; }
        if (FC_BALL != 0) {
            float2 bl = tp - u.ball.xy;
            float2 bc = u.ball.zw * 0.5;
            if (all(bl > -6.0) && all(bl < u.ball.zw + 6.0)) {
                bool hidden = false;
                if (FC_OCCLUSION) {
                    int2 ti = clamp(int2(floor(tp)), int2(0), int2(319, 399));
                    hidden = ((occlusion.read(uint2(ti)).r >> uint(u.ballInfo.z)) & 1u) != 0u;
                }
                if (FC_LIGHT && !hidden) {
                    // Soft contact shadow, offset away from the light (top-left).
                    float2 sd = (bl - bc - float2(1.8, 2.4)) / (bc * float2(1.15, 1.1));
                    color *= 1.0 - u.light.y * smoothstep(1.0, 0.25, length(sd));
                }
                if (!hidden && all(bl > -2.0) && all(bl < u.ball.zw + 2.0)) {
                    float4 b = ball_layer(u, bl, sc, lin, ballTex, ballBlend);
                    if (FC_LIGHT) {
                        float2 rel = (bl - bc) / bc - float2(-0.38, -0.42);
                        float spec = exp(-dot(rel, rel) * 14.0);
                        b.rgb += (u.light.z * spec) * b.a + glow.sample(lin, guv).rgb * 0.8 * b.a;
                    }
                    color = b.rgb + color * (1.0 - b.a);
                }
            }
        }
        if (FC_DOTS && local.y < u.frame.z) {
            // Dot messages (screen-relative like render_frame's plot): square or round dots.
            int2 c0 = int2(floor(local));
            int maxRow = int(u.frame.z) - 1;
            if (!FC_ROUND) {
                uint o = overlay.read(uint2(clamp(c0, int2(0), int2(319, maxRow)))).r;
                if (o != 0u) { color = palette.read(o).rgb; }
            } else {
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int2 c = c0 + int2(dx, dy);
                        if (c.x < 0 || c.y < 0 || c.x > 319 || c.y > maxRow) { continue; }
                        uint o = overlay.read(uint2(c)).r;
                        if (o == 0u) { continue; }
                        float d = length(local - (float2(c) + 0.5));
                        float a = clamp((0.58 - d) * min(sc.x, sc.y) + 0.5, 0.0, 1.0);
                        float3 dc = palette.read(o).rgb;
                        if (FC_LIGHT) { color += dc * 0.22 * exp(-d * d * 3.0); }
                        color = mix(color, dc, a);
                    }
                }
            }
        }
    }
    if (FC_FILTER == 3) {
        // Scanlines (beam width grows with brightness), aperture-grille mask, vignette.
        float fy = fract(local.y) - 0.5;
        float l = luma(color);
        float sigma = mix(0.26, 0.42, sqrt(clamp(l, 0.0, 1.0)));
        float beam = exp(-fy * fy / (2.0 * sigma * sigma));
        float scan = mix(1.0, beam * 1.55, u.crt.y * clamp((sc.y - 1.5) / 2.0, 0.0, 1.0));
        int m = int(in.position.x) % 3;
        float k = 1.0 - u.crt.z;
        float3 mask = float3(m == 0 ? 1.0 : k, m == 1 ? 1.0 : k, m == 2 ? 1.0 : k);
        color = color * color * scan * mask * (1.0 + u.crt.z * 0.9);   // rough gamma-2 space
        color = sqrt(max(color, 0.0));
        float2 vv = local / float2(u.src.x, screenH) - 0.5;
        color *= (1.0 - dot(vv, vv) * 0.35) * edge;
    }
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
