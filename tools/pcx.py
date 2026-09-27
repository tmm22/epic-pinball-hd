"""Minimal 8-bit PCX decoder that also reports where the image data ends.

Epic Pinball's EPn.DAT / REG.DAT files are ZSoft PCX v5 (RLE, 8bpp, 1 plane).
We decode manually rather than via Pillow so we can detect data that follows
the RLE stream and the trailing 256-colour palette.
"""
import struct
import sys
from dataclasses import dataclass

import numpy as np


@dataclass
class Pcx:
    width: int
    height: int
    pixels: np.ndarray  # (height, width) uint8 palette indices
    palette: np.ndarray  # (256, 3) uint8 RGB
    rle_end: int  # file offset just after the last RLE byte
    file_size: int


def decode(data: bytes) -> Pcx:
    manuf, version, enc, bpp = data[0], data[1], data[2], data[3]
    if manuf != 0x0A or enc != 1 or bpp != 8:
        raise ValueError(f"not an 8bpp RLE PCX (manuf={manuf:#x} enc={enc} bpp={bpp})")
    xmin, ymin, xmax, ymax = struct.unpack_from("<4H", data, 4)
    nplanes = data[65]
    bytes_per_line = struct.unpack_from("<H", data, 66)[0]
    if nplanes != 1:
        raise ValueError(f"unsupported plane count {nplanes}")
    width, height = xmax - xmin + 1, ymax - ymin + 1

    total = bytes_per_line * height
    out = bytearray(total)
    pos, o = 128, 0
    while o < total:
        b = data[pos]
        pos += 1
        if b >= 0xC0:
            count = b & 0x3F
            val = data[pos]
            pos += 1
        else:
            count, val = 1, b
        end = min(o + count, total)
        out[o:end] = bytes([val]) * (end - o)
        o += count

    pixels = np.frombuffer(bytes(out), dtype=np.uint8).reshape(height, bytes_per_line)[:, :width]

    # 256-colour palette: marker 0x0C followed by 768 bytes, normally at EOF.
    palette = np.zeros((256, 3), dtype=np.uint8)
    if len(data) >= 769 and data[-769] == 0x0C:
        palette = np.frombuffer(data[-768:], dtype=np.uint8).reshape(256, 3).copy()
    return Pcx(width, height, pixels.copy(), palette, pos, len(data))


def to_image(pcx: Pcx):
    from PIL import Image

    img = Image.fromarray(pcx.pixels, mode="P")
    img.putpalette(pcx.palette.flatten().tolist())
    return img


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            p = decode(f.read())
        trailing = p.file_size - p.rle_end
        print(f"{path}: {p.width}x{p.height} rle_end={p.rle_end:#x} trailing={trailing}")
