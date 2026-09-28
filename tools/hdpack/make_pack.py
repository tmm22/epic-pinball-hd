#!/usr/bin/env python3
"""Generate an HD asset pack for one Epic Pinball table from YOUR extracted data.

    .venv/bin/python tools/hdpack/make_pack.py --table 1 --scale 4
    .venv/bin/python tools/hdpack/make_pack.py --table 10 --scale 4 --verify
    .venv/bin/python tools/hdpack/make_pack.py --table 1 --scale 4 \\
        --upscaler-cmd 'realesrgan-ncnn-vulkan -i {in} -o {out} -s 4 -n realesrgan-x4plus-anime'

Reads extracted/tables/EPn/ (playfield_idx.npy, palette.json, sprites/sprites.json and the
sprite PNGs, engine.json for the ball) and writes extracted/hdpacks/EPn/ (gitignored; in the
app the packs live in ~/Library/Application Support/EpicPinballHD/HDPacks/). The pack is
derived from the user's own copy of the game and must never be committed or distributed.

Format: docs/enhanced/rendering.md ("HD asset packs"). Every asset is exactly `scale` times
the original record and aligned to the original pixel grid: HD pixel (X, Y) belongs to
original pixel (X // scale, Y // scale). Collision never uses the pack.

Methods:
  xbrz     built-in numpy xBRZ (tools/hdpack/xbrz.py), the same filter as the renderer's.
  nearest  pixel replication (for testing the pipeline / alignment).
  ai       an external upscaler command (--upscaler-cmd) for the playfield and opaque
           sprites; {in} / {out} are PNG paths, {scale} the factor. Its output is resized to
           the exact size if needed and then anchored to the original pixels by iterative
           back-projection (--anchor N) so the pack stays aligned. Ball alpha and font masks
           always use xBRZ.

Lamp overlays, flipper frames and the plunger are opaque rectangles with the playfield
baked in; they are upscaled inside their playfield context (pasted into the playfield with
a margin, scaled, cropped) so their HD edges meet the HD playfield without seams.
"""
import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xbrz  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FORMAT = "epic-pinball-hdpack"
VERSION = 1
MARGIN = 3  # context pixels around sprites (xBRZ reads 2)


def load_table(data, n):
    d = os.path.join(data, "tables", f"EP{n}")
    idx = np.load(os.path.join(d, "playfield_idx.npy"))
    assert idx.shape == (400, 320) and idx.dtype == np.uint8, idx.shape
    pal = np.array(json.load(open(os.path.join(d, "palette.json"))), dtype=np.uint8)
    assert pal.shape == (256, 3)
    sprites = json.load(open(os.path.join(d, "sprites", "sprites.json")))
    engine = json.load(open(os.path.join(d, "engine.json")))
    return d, idx, pal, sprites, engine


def rgba_of(idx, pal):
    rgb = pal[idx]
    return np.concatenate([rgb, np.full(idx.shape + (1,), 255, np.uint8)], axis=-1)


class Upscaler:
    def __init__(self, method, S, cmd=None, anchor=0):
        self.method, self.S, self.cmd, self.anchor = method, S, cmd, anchor
        self.tmp = tempfile.mkdtemp(prefix="ep_hdpack_")

    def opaque(self, rgba):
        """Opaque RGBA (h, w, 4) uint8 -> (h*S, w*S, 4)."""
        S = self.S
        if self.method == "nearest":
            return np.repeat(np.repeat(rgba, S, 0), S, 1)
        if self.method == "xbrz" or not self.cmd:
            return xbrz.scale_rgba8(rgba, S)
        src = os.path.join(self.tmp, "in.png")
        dst = os.path.join(self.tmp, "out.png")
        Image.fromarray(rgba[..., :3]).save(src)
        if os.path.exists(dst):
            os.remove(dst)
        cmd = self.cmd.format(**{"in": shlex.quote(src), "out": shlex.quote(dst), "scale": S})
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(dst):
            raise SystemExit(f"upscaler failed ({r.returncode}): {cmd}\n{r.stderr[-2000:]}")
        out = Image.open(dst).convert("RGB")
        want = (rgba.shape[1] * S, rgba.shape[0] * S)
        if out.size != want:
            out = out.resize(want, Image.LANCZOS)
        hd = np.array(out, dtype=np.float32)
        hd = back_project(hd, rgba[..., :3].astype(np.float32), S, self.anchor)
        return np.concatenate([np.clip(np.rint(hd), 0, 255).astype(np.uint8),
                               np.full(hd.shape[:2] + (1,), 255, np.uint8)], axis=-1)

    def alpha(self, rgba):
        """RGBA with transparency (ball) -> always xBRZ / nearest (alpha-aware)."""
        if self.method == "nearest":
            return np.repeat(np.repeat(rgba, self.S, 0), self.S, 1)
        return xbrz.scale_rgba8(rgba, self.S)

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def box_down(hd, S):
    h, w = hd.shape[0] // S, hd.shape[1] // S
    return hd[:h * S, :w * S].reshape(h, S, w, S, -1).mean(axis=(1, 3))


def back_project(hd, lo, S, iters):
    """Adjust `hd` so that each S x S block averages to the original pixel (alignment anchor)."""
    for _ in range(iters):
        err = lo - box_down(hd, S)
        hd = np.clip(hd + np.repeat(np.repeat(err, S, 0), S, 1), 0, 255)
    return hd


def context_crop(field_rgba, rec_rgba, x, y, S, up):
    """Upscale a position-bound opaque record inside the playfield context."""
    H, W = field_rgba.shape[:2]
    h, w = rec_rgba.shape[:2]
    canvas = field_rgba.copy()
    # paste (clipped like blit_list: rows/columns outside the table are dropped)
    y0, y1, x0, x1 = max(0, y), min(H, y + h), max(0, x), min(W, x + w)
    if y1 > y0 and x1 > x0:
        canvas[y0:y1, x0:x1] = rec_rgba[y0 - y:y1 - y, x0 - x:x1 - x]
    # region = record rect + margin, clipped; pixels of the record outside the table are
    # upscaled on their own (edge replicated)
    cy0, cy1 = max(0, y - MARGIN), min(H, y + h + MARGIN)
    cx0, cx1 = max(0, x - MARGIN), min(W, x + w + MARGIN)
    if not (y0 == y and x0 == x and y1 == y + h and x1 == x + w):
        return up.opaque(rec_rgba)
    region = canvas[cy0:cy1, cx0:cx1]
    hd = up.opaque(region)
    oy, ox = (y - cy0) * S, (x - cx0) * S
    return hd[oy:oy + h * S, ox:ox + w * S]


def save_png(path, arr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Image.fromarray(arr).save(path, optimize=False, compress_level=6)


def verify(pack_dir, data, n):
    """Downsample every asset back and compare with the original pixels."""
    _, idx, pal, sp, engine = load_table(data, n)
    man = json.load(open(os.path.join(pack_dir, "pack.json")))
    S = man["scale"]
    sdir = os.path.join(data, "tables", f"EP{n}", "sprites")
    report = {"table": n, "scale": S, "assets": {}}
    total_shift = {}

    def check(name, hd, orig):
        hd = hd.astype(np.float32)
        orig = orig.astype(np.float32)
        if orig.shape[-1] == 4:
            # compare colour only where the original is opaque (premultiplied box average)
            a = orig[..., 3:4] / 255
            box = box_down(hd[..., :3] * hd[..., 3:4] / 255, S)
            ref = orig[..., :3] * a
        else:
            box = box_down(hd[..., :3], S)
            ref = orig[..., :3]
        centre = hd[S // 2::S, S // 2::S, :3][:ref.shape[0], :ref.shape[1]]
        if orig.shape[-1] == 4:
            m = orig[..., 3] == 255
            centre_ok = np.all(np.abs(centre - orig[..., :3]) <= 1, axis=-1)[m].mean() if m.any() else 1.0
        else:
            centre_ok = np.all(np.abs(centre - ref) <= 1, axis=-1).mean()
        mae = np.abs(box - ref).mean()
        # alignment: box-average error for HD shifts of -S/2..S/2 pixels; the best must be 0,0
        best, shifts = None, {}
        cands = [(0, 0)] + [(dy, dx) for dy in range(-(S // 2), S // 2 + 1) for dx in range(-(S // 2), S // 2 + 1) if (dy, dx) != (0, 0)]
        for dy, dx in cands:
            if True:
                sh = np.roll(np.roll(hd, dy, 0), dx, 1)
                src = sh[..., :3] * (sh[..., 3:4] / 255 if orig.shape[-1] == 4 else 1)
                b = box_down(src, S)
                cut = slice(1, -1) if min(ref.shape[:2]) > 4 else slice(None)
                e = float(np.abs(b[cut, cut] - ref[cut, cut]).mean())
                shifts[(dy, dx)] = e
                if best is None or e < shifts[best] - 1e-9:
                    best = (dy, dx)
        # aligned: no shift of the HD grid fits the original better (ties = flat sprites)
        # (tiny records with repetitive rows make the shift test ambiguous: there the centre
        # samples, which any misalignment of S/2 or more would change, decide)
        small = ref.shape[0] * ref.shape[1] < 400
        aligned = shifts[(0, 0)] <= shifts[best] + 0.1 or (small and centre_ok >= 0.9)
        for key, e in shifts.items():
            total_shift[key] = total_shift.get(key, 0.0) + e * ref.shape[0] * ref.shape[1]
        report["assets"][name] = {"box_mae": round(float(mae), 3), "centre_exact": round(float(centre_ok), 4),
                                  "best_shift": list(best), "shift0_err": round(shifts[(0, 0)], 3), "aligned": bool(aligned)}
        return aligned

    ok = True
    pf = np.array(Image.open(os.path.join(pack_dir, man["playfield"])).convert("RGB"))
    ok &= check("playfield", pf, pal[idx])
    for name, e in sorted(man.get("sprites", {}).items()):
        hd = np.array(Image.open(os.path.join(pack_dir, e["file"])).convert("RGBA"))
        orig = np.array(Image.open(os.path.join(sdir, name + ".png")).convert("RGBA"))
        if orig.shape[0] * S != hd.shape[0] or orig.shape[1] * S != hd.shape[1]:
            report["assets"][name] = {"error": "size mismatch"}
            ok = False
            continue
        ok &= check(name, hd, orig[..., :3])
    if "ball" in man:
        hd = np.array(Image.open(os.path.join(pack_dir, man["ball"]["file"])).convert("RGBA"))
        b = engine["ball"]
        bi = np.array(b["pixels"], np.uint8).reshape(b["h"], b["w"])
        orig = rgba_of(bi, pal)
        orig[bi == b.get("transparent", 0), 3] = 0
        ok &= check("ball", hd, orig)
    vals = [v for v in report["assets"].values() if "box_mae" in v]
    agg_best = min(total_shift, key=lambda k: (total_shift[k], k != (0, 0)))
    report["aggregate_best_shift"] = list(agg_best)
    ok &= agg_best == (0, 0)
    report["summary"] = {
        "assets": len(vals),
        "all_aligned": all(v["aligned"] for v in vals),
        "aggregate_best_shift (all assets, pixel-weighted)": list(agg_best),
        "best_shift_nonzero": sorted(k for k, v in report["assets"].items() if v.get("best_shift", [0, 0]) != [0, 0]),
        "playfield": report["assets"]["playfield"],
        "sprites_box_mae_mean": round(float(np.mean([v["box_mae"] for k, v in report["assets"].items() if k != "playfield" and "box_mae" in v] or [0])), 3),
        "sprites_centre_exact_mean": round(float(np.mean([v["centre_exact"] for k, v in report["assets"].items() if k != "playfield" and "centre_exact" in v] or [1])), 4),
    }
    json.dump(report, open(os.path.join(pack_dir, "verify.json"), "w"), indent=1)
    return ok, report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--table", type=int, required=True)
    ap.add_argument("--scale", type=int, default=4, choices=[2, 3, 4, 5, 6, 7, 8])
    ap.add_argument("--data", default=os.path.join(ROOT, "extracted"), help="the extracted/ directory")
    ap.add_argument("--out", help="pack directory (default <data>/hdpacks/EPn)")
    ap.add_argument("--method", choices=["xbrz", "nearest", "ai"], default=None)
    ap.add_argument("--upscaler-cmd", help="external upscaler, e.g. 'realesrgan-ncnn-vulkan -i {in} -o {out} -s {scale}'")
    ap.add_argument("--anchor", type=int, default=None, help="back-projection iterations for external upscaler output (default 3)")
    ap.add_argument("--verify", action="store_true", help="downsample the pack back and compare with the original")
    ap.add_argument("--verify-only", action="store_true")
    a = ap.parse_args()
    method = a.method or ("ai" if a.upscaler_cmd else "xbrz")
    if method == "ai" and not a.upscaler_cmd:
        ap.error("--method ai needs --upscaler-cmd")
    S, n = a.scale, a.table
    out = a.out or os.path.join(a.data, "hdpacks", f"EP{n}")
    if a.verify_only:
        ok, rep = verify(out, a.data, n)
        print(json.dumps(rep["summary"], indent=1))
        sys.exit(0 if ok else 1)

    t0 = time.time()
    tdir, idx, pal, sp, engine = load_table(a.data, n)
    sdir = os.path.join(tdir, "sprites")
    up = Upscaler(method, S, a.upscaler_cmd, 3 if a.anchor is None else a.anchor)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    field = rgba_of(idx, pal)
    manifest = {
        "format": FORMAT, "version": VERSION, "table": n, "scale": S,
        "generator": {"tool": "tools/hdpack/make_pack.py", "method": method,
                      "upscaler_cmd": a.upscaler_cmd, "anchor": up.anchor if method == "ai" else 0},
        "source": {"playfield_idx_sha256": hashlib.sha256(idx.tobytes()).hexdigest(),
                   "palette_sha256": hashlib.sha256(pal.tobytes()).hexdigest()},
        "playfield": "playfield.png", "sprites": {}, "fonts": {},
        "note": "Generated from the user's own game data. Do not distribute.",
    }
    print(f"EP{n}: playfield {320 * S}x{400 * S} ({method})", flush=True)
    save_png(os.path.join(out, "playfield.png"), up.opaque(field))

    count = 0
    for s in sp["sprites"]:
        name, group, fmt = s["name"], s.get("group"), s.get("format")
        if fmt not in ("planar", "chunky") or group not in ("lamp", "flipper", "plunger", "digit", "display"):
            continue
        png = os.path.join(sdir, name + ".png")
        if not os.path.exists(png):
            continue
        rec = np.array(Image.open(png).convert("RGBA"))
        rec[..., 3] = 255
        if group in ("lamp", "flipper", "plunger") and "x" in s and "y" in s:
            hd = context_crop(field, rec, s["x"], s["y"], S, up)
        else:
            hd = up.opaque(rec)
        rel = f"sprites/{name}.png"
        save_png(os.path.join(out, rel), hd)
        e = {"file": rel, "w": rec.shape[1], "h": rec.shape[0], "group": group}
        if "x" in s:
            e["x"], e["y"] = s["x"], s["y"]
        manifest["sprites"][name] = e
        count += 1
    print(f"  {count} sprites", flush=True)

    b = engine["ball"]
    if b.get("pixels"):
        bi = np.array(b["pixels"], np.uint8).reshape(b["h"], b["w"])
        ball = rgba_of(bi, pal)
        ball[bi == b.get("transparent", 0)] = 0
        padded = np.pad(ball, ((2, 2), (2, 2), (0, 0)))
        hd = up.alpha(padded)[2 * S:(2 + b["h"]) * S, 2 * S:(2 + b["w"]) * S]
        save_png(os.path.join(out, "sprites/ball.png"), hd)
        manifest["ball"] = {"file": "sprites/ball.png", "w": b["w"], "h": b["h"]}

    # font8 coverage atlas (glyph g at rows g*8S), white = covered; always xBRZ on the bits.
    glyphs = {int(s["char"]): s["name"] for s in sp["sprites"] if s.get("format") == "font8" and "char" in s}
    if glyphs:
        first, last = 0x20, max(glyphs)
        cell = 8 * S
        atlas = np.zeros(((last - first + 1) * cell, cell, 4), np.uint8)
        atlas[..., 3] = 255
        for ch in range(first, last + 1):
            if ch not in glyphs:
                continue
            g = np.array(Image.open(os.path.join(sdir, glyphs[ch] + ".png")).convert("RGBA"))
            m = (g[..., 3] > 0) & (g[..., :3].max(axis=-1) > 0)
            bits = np.zeros((8, 8, 4), np.uint8)
            bits[..., 3] = 255
            bits[m, :3] = 255
            padded = np.pad(bits, ((2, 2), (2, 2), (0, 0)), mode="constant", constant_values=0)
            padded[..., 3] = 255
            hdm = xbrz.scale_rgba8(padded, S)[2 * S:10 * S, 2 * S:10 * S] if method != "nearest" else np.repeat(np.repeat(bits, S, 0), S, 1)
            atlas[(ch - first) * cell:(ch - first + 1) * cell] = hdm
        save_png(os.path.join(out, "fonts/font8.png"), atlas)
        manifest["fonts"]["font8"] = {"file": "fonts/font8.png", "first": 0, "cell": 8, "glyphs": last - first + 1,
                                      "layout": "vertical, glyph index from ' ', red channel = coverage"}
    json.dump(manifest, open(os.path.join(out, "pack.json"), "w"), indent=1)
    up.close()
    print(f"  wrote {out} in {time.time() - t0:.1f} s", flush=True)
    if a.verify:
        ok, rep = verify(out, a.data, n)
        print(json.dumps(rep["summary"], indent=1))
        if not ok:
            print("ALIGNMENT CHECK FAILED (see verify.json)")
            sys.exit(1)


if __name__ == "__main__":
    main()
