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
