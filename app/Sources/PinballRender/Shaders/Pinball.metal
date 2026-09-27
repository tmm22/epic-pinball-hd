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
//   2. present_*        : upscales the native frame into the drawable's
//                         integer-scaled viewport. `present_nearest` is the only
//                         filter today; further filters (xBR, CRT, ...) are
//                         additional fragment functions with the same inputs
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
};

struct PresentUniforms {
    float4 dst;   // xy: viewport origin (output px), zw: output px per source px (x, y)
    float4 src;   // x: source width, y: visible rows, z: fractional row offset, w: unused
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
                               texture2d<float, access::read> atlas [[texture(2)]]) {
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
    return float4(color, 1.0);
}

// Nearest-neighbour integer upscale of the native frame.
fragment float4 present_nearest(VSOut in [[stage_in]],
                                constant PresentUniforms &u [[buffer(0)]],
                                texture2d<float, access::read> frame [[texture(0)]]) {
    float2 local = (in.position.xy - u.dst.xy) / u.dst.zw;
    local.y += u.src.z;
    uint2 s = uint2(clamp(local, float2(0.0), float2(frame.get_width() - 1, frame.get_height() - 1)));
    return frame.read(s);
}
