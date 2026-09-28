"""xBRZ pixel-art scaler in numpy (scale-free "freescale" form).

Same rules and constants as the renderer's Metal implementation
(app/Sources/PinballRender/Shaders/Pinball.metal: xbrz_prepass + xbrz_sample), after
Zenju's xBRZ: YCbCr colour distance, 2x2-block corner analysis with dominant-direction
detection, then per pixel and per corner a corner / diagonal / shallow / steep line blend.
The blend regions are evaluated analytically at output-pixel centres with one output
pixel of anti-aliasing, so any integer scale works and the result matches the GPU filter
(up to float rounding).

Input and output are float32 arrays (H, W, 4) with premultiplied RGBA in 0..1.
"""
import numpy as np

EQ_TOL = 30.0
DOMINANT = 3.6
STEEP = 2.2
CENTRE_W = 4.0

_KB, _KR = 0.0593, 0.2627
_KG = 1.0 - _KB - _KR


def dist(a, b):
    """YCbCr distance (0-255 scale), alpha-aware like xBRZ's ARGB variant."""
    d = (a[..., :3] - b[..., :3]) * 255.0
    y = _KR * d[..., 0] + _KG * d[..., 1] + _KB * d[..., 2]
    cb = 0.5 / (1.0 - _KB) * (d[..., 2] - y)
    cr = 0.5 / (1.0 - _KR) * (d[..., 0] - y)
    dd = np.sqrt(y * y + cb * cb + cr * cr)
    a1, a2 = a[..., 3], b[..., 3]
    return np.where(a1 < a2, a1 * dd + 255.0 * (a2 - a1), a2 * dd + 255.0 * (a1 - a2))


def same(a, b):
    return np.all(a == b, axis=-1)


def near(a, b):
    return dist(a, b) < EQ_TOL


class _Padded:
    """Edge-replicated source with offset access: at(dy, dx) = src[y+dy, x+dx] for all y, x."""

    def __init__(self, src, pad=3):
        self.p = np.pad(src, ((pad, pad), (pad, pad), (0, 0)), mode="edge")
        self.pad = pad
        self.h, self.w = src.shape[:2]

    def at(self, dy, dx, h=None, w=None, oy=0, ox=0):
        h = self.h if h is None else h
        w = self.w if w is None else w
        y0, x0 = self.pad + dy + oy, self.pad + dx + ox
        return self.p[y0:y0 + h, x0:x0 + w]


def prepass(src):
    """Blend bits per 2x2 block; result[y+1, x+1] is the block with top-left pixel (x, y)
    for x in -1..W-1 (bits 0-1 F bottom-right, 2-3 G bottom-left, 4-5 J top-right,
    6-7 K top-left; 0 none, 1 normal, 2 dominant)."""
    P = _Padded(src)
    H, W = src.shape[:2]
    h, w = H + 1, W + 1
    at = lambda dy, dx: P.at(dy, dx, h, w, -1, -1)  # block origin f = (x-1, y-1)
    b, c = at(-1, 0), at(-1, 1)
    e, F, g, hh = at(0, -1), at(0, 0), at(0, 1), at(0, 2)
    i, j, k, l = at(1, -1), at(1, 0), at(1, 1), at(1, 2)
    n, o = at(2, 0), at(2, 1)
    fg, jk, fj, gk = same(F, g), same(j, k), same(F, j), same(g, k)
    skip = (fg & jk) | (fj & gk)
    jg = dist(i, F) + dist(F, c) + dist(n, k) + dist(k, hh) + CENTRE_W * dist(j, g)
    fk = dist(e, j) + dist(j, o) + dist(b, g) + dist(g, l) + CENTRE_W * dist(F, k)
    res = np.zeros((h, w), np.uint8)
    t1 = np.where(DOMINANT * jg < fk, 2, 1).astype(np.uint8)
    t2 = np.where(DOMINANT * fk < jg, 2, 1).astype(np.uint8)
    c1 = ~skip & (jg < fk)
    c2 = ~skip & (fk < jg)
    res |= np.where(c1 & ~fg & ~fj, t1, 0).astype(np.uint8)
    res |= np.where(c1 & ~jk & ~gk, t1 << 6, 0).astype(np.uint8)
    res |= np.where(c2 & ~fj & ~jk, t2 << 4, 0).astype(np.uint8)
    res |= np.where(c2 & ~fg & ~gk, t2 << 2, 0).astype(np.uint8)
    return res


def _half_plane(u, v, n, c, sc):
    return np.clip((n[0] * u + n[1] * v - c) / np.hypot(*n) * sc + 0.5, 0.0, 1.0)


# rotation: (r, d, corner field, topR field, bottomL field); fields: 'BR','BL','TR','TL'
_ROTS = [
    ((0, 1), (1, 0), "BR", "TR", "BL"),
    ((1, 0), (0, -1), "BL", "BR", "TL"),
    ((0, -1), (-1, 0), "TL", "BL", "TR"),
    ((-1, 0), (0, 1), "TR", "TL", "BR"),
]  # vectors as (dy, dx)


def scale(src, S):
    """xBRZ-scale premultiplied RGBA float32 (H, W, 4) by the integer S."""
    H, W = src.shape[:2]
    blend = prepass(src)
    Bp = np.pad(blend, ((0, 1), (0, 1)), mode="edge")
    corners = {
        "BR": Bp[1:H + 1, 1:W + 1] & 3,
        "BL": (Bp[1:H + 1, 0:W] >> 2) & 3,
        "TR": (Bp[0:H, 1:W + 1] >> 4) & 3,
        "TL": (Bp[0:H, 0:W] >> 6) & 3,
    }
    P = _Padded(src)
    E = src
    # sub-pixel centres relative to the source pixel centre
    offs = (np.arange(S, dtype=np.float32) + 0.5) / S - 0.5
    out = np.repeat(np.repeat(E, S, axis=0), S, axis=1).reshape(H, S, W, S, 4).transpose(0, 2, 1, 3, 4).copy()
    # out[y, x, sy, sx, :]
    fy = offs[:, None]
    fx = offs[None, :]
    for (ry, rx), (dy, dx), fc, ftr, fbl in _ROTS:
        bc, btr, bbl = corners[fc], corners[ftr], corners[fbl]
        active = bc != 0
        if not active.any():
            continue
        px = lambda oy, ox: P.at(oy, ox)
        B = px(-dy, -dx)
        C = px(ry - dy, rx - dx)
        D = px(-ry, -rx)
        F = px(ry, rx)
        G = px(-ry + dy, -rx + dx)
        Hh = px(dy, dx)
        I = px(ry + dy, rx + dx)
        line = np.where(bc >= 2, True,
                np.where((btr != 0) & ~near(E, G), False,
                np.where((bbl != 0) & ~near(E, C), False,
                np.where(~near(E, I) & near(G, Hh) & near(Hh, I) & near(I, F) & near(F, C), False, True))))
        col = np.where((dist(E, F) <= dist(E, Hh))[..., None], F, Hh)
        fgd, hcd = dist(F, G), dist(Hh, C)
        shallow = (STEEP * fgd <= hcd) & ~same(E, G) & ~same(D, G)
        steep = (STEEP * hcd <= fgd) & ~same(E, C) & ~same(B, C)
        # rotated local coordinates of every sub-pixel: u along r, v along d
        u = fx * rx + fy * ry
        v = fx * dx + fy * dy
        sc = float(S)
        cs = _half_plane(u, v, (0.5, 1.0), 0.25, sc)
        ct = _half_plane(u, v, (1.0, 0.5), 0.25, sc)
        cd = _half_plane(u, v, (1.0, 1.0), 0.5, sc)
        cc = np.where((u > 0) & (v > 0), np.clip((np.hypot(u, v) - 0.5) * sc + 0.5, 0, 1), 0.0)
        case = np.where(~line, 0, np.where(shallow & steep, 4, np.where(shallow, 2, np.where(steep, 3, 1))))
        cov_tab = np.stack([cc, cd, cs, ct, np.maximum(cs, ct)])  # (5, S, S)
        cov = cov_tab[case]  # (H, W, S, S)
        cov = np.where(active[..., None, None], cov, 0.0).astype(np.float32)
        out = out + (col[:, :, None, None, :] - out) * cov[..., None]
    return out.transpose(0, 2, 1, 3, 4).reshape(H * S, W * S, 4)


def scale_rgba8(rgba, S):
    """uint8 straight RGBA (H, W, 4) -> uint8 straight RGBA (H*S, W*S, 4)."""
    f = rgba.astype(np.float32) / 255.0
    f[..., :3] *= f[..., 3:4]
    o = scale(f, S)
    a = o[..., 3:4]
    rgb = np.where(a > 1e-6, o[..., :3] / np.maximum(a, 1e-6), 0.0)
    res = np.concatenate([rgb, a], axis=-1)
    return np.clip(np.rint(res * 255.0), 0, 255).astype(np.uint8)
