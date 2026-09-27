"""Extract assets from an Epic Pinball install into extracted/.

Usage:  .venv/bin/python tools/extract.py [original_dir] [out_dir]

Outputs per table n:
  extracted/tables/EPn/playfield.png        320x400 indexed PNG, in-game palette
  extracted/tables/EPn/playfield_idx.npy    raw palette indices (for tools / engine import)
  extracted/tables/EPn/palette.json         256 RGB triplets (8-bit)
  extracted/tables/EPn/preview.png          table-select screen (EPn.DAT, PCX)
"""
import json
import os
import re
import struct
import sys

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import epexe  # noqa: E402
import pcx  # noqa: E402

# Tables whose playfield segments hold only a background layer; every toy is a
# lamp overlay (see docs/formats/sprites.md and tools/sprites.py).
LAYERED_TABLES = {8}


_FADE_SIG = re.compile(rb"\x8d\x3e..\xb9\x00\x03\xb0\x00\xf3\xaa\x8d\x36(..)", re.S)


def find_palette(exe: epexe.TableExe, preview_palette: np.ndarray) -> tuple:
    """Locate the 8-bit in-game palette. Returns (file_offset, preview_match, method).

    Preferred: the fade-in routine (lea di,[work]; mov cx,300h; mov al,0;
    rep stosb; lea si,[pal]) names the palette directly (EP1-8).
    Fallback: slide the first 200 preview-PCX entries across the file; indices
    0-199 are static table colours that mostly match the preview (EP9-13).
    """
    d = np.frombuffer(exe.data, dtype=np.uint8)
    ref = preview_palette.flatten()[:600]
    code = exe.data[exe.image_off(exe.entry_cs) :]
    m = _FADE_SIG.search(code)
    if m:
        off = exe.image_off(epexe.data_segment(exe), struct.unpack("<H", m.group(1))[0])
        method = "fade-code"
    else:
        probe = np.arange(0, 600, 10)
        coarse = (sliding_window_view(d, 600)[:, probe] == ref[probe]).mean(axis=1)
        off = int(coarse.argmax())
        method = "preview-match"
    score = float((d[off : off + 600] == ref).mean())
    return off, score, method


def extract_table(n: int, src: str, out: str) -> dict:
    exe = epexe.load(os.path.join(src, f"EP{n}.EXE"))
    prev = pcx.decode(open(os.path.join(src, f"EP{n}.DAT"), "rb").read())
    top, bottom, after = epexe.find_playfield_segments(exe)
    pal_off, score, pal_method = find_palette(exe, prev.palette)
    pal = np.frombuffer(exe.data[pal_off : pal_off + 768], dtype=np.uint8).reshape(256, 3)
    pf = epexe.playfield(exe)

    tdir = os.path.join(out, "tables", f"EP{n}")
    os.makedirs(tdir, exist_ok=True)
    img = Image.frombytes("P", (pf.shape[1], pf.shape[0]), pf.tobytes())
    img.putpalette(pal.flatten().tolist())
    img.save(os.path.join(tdir, "playfield.png"))
    np.save(os.path.join(tdir, "playfield_idx.npy"), pf)
    with open(os.path.join(tdir, "palette.json"), "w") as f:
        json.dump(pal.tolist(), f)
    pimg = Image.frombytes("P", (prev.width, prev.height), prev.pixels.tobytes())
    pimg.putpalette(prev.palette.flatten().tolist())
    pimg.save(os.path.join(tdir, "preview.png"))

    return {
        "table": n,
        "playfield_file_offset": hex(exe.image_off(top)),
        "segments": [hex(top), hex(bottom), hex(after)],
        "data_segment": hex(epexe.data_segment(exe)),
        "palette_file_offset": hex(pal_off),
        "palette_match": round(score, 2),
        "palette_method": pal_method,
        "layered_not_decoded": n in LAYERED_TABLES,
    }


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "original"
    out = sys.argv[2] if len(sys.argv) > 2 else "extracted"
    report = []
    for n in range(1, 14):
        info = extract_table(n, src, out)
        report.append(info)
        flag = "  (layered: toys are overlays)" if info["layered_not_decoded"] else ""
        print(f"EP{n:<2} playfield@{info['playfield_file_offset']} palette@{info['palette_file_offset']} "
              f"match={info['palette_match']} via {info['palette_method']}{flag}")
    with open(os.path.join(out, "tables", "manifest.json"), "w") as f:
        json.dump(report, f, indent=2)


if __name__ == "__main__":
    main()
