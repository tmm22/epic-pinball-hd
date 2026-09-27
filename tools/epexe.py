"""Structural parser for Epic Pinball table executables (EPn.EXE).

Findings (see docs/formats/table-exe.md):
  * Plain MZ executable, hand-written real-mode assembly, not packed.
  * The playfield is 320x400 raw 8bpp pixels, stored as two 64000-byte
    halves in two consecutive segments that are referenced from the
    relocation table (segment values differ by exactly 0xFA0 paragraphs).
  * The in-game palette is 768 bytes of 8-bit RGB in the data segment; the
    engine shifts each component right by 2 before writing the VGA DAC.
    Its location varies per table; see find_palette() in extract.py.
"""
import re
import struct
from dataclasses import dataclass, field

import numpy as np

HALF = 320 * 200  # bytes per 320x200 screen segment
HALF_PARAS = HALF // 16  # 0xFA0


@dataclass
class TableExe:
    path: str
    data: bytes
    header_size: int
    entry_cs: int
    entry_ip: int
    relocs: list = field(default_factory=list)  # (seg, off) of each fixup
    seg_values: dict = field(default_factory=dict)  # seg value -> ref count

    def image_off(self, seg: int, off: int = 0) -> int:
        """File offset for a load-image seg:off address."""
        return self.header_size + seg * 16 + off


def load(path: str) -> TableExe:
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        raise ValueError(f"{path}: not an MZ executable")
    nreloc = struct.unpack_from("<H", data, 6)[0]
    hdr_paras = struct.unpack_from("<H", data, 8)[0]
    ip, cs = struct.unpack_from("<HH", data, 0x14)
    reloc_off = struct.unpack_from("<H", data, 0x18)[0]
    exe = TableExe(path, data, hdr_paras * 16, cs, ip)
    for i in range(nreloc):
        off, seg = struct.unpack_from("<HH", data, reloc_off + i * 4)
        exe.relocs.append((seg, off))
        val = struct.unpack_from("<H", data, exe.image_off(seg, off))[0]
        exe.seg_values[val] = exe.seg_values.get(val, 0) + 1
    return exe


def find_playfield_segments(exe: TableExe) -> tuple:
    """Return (top_seg, bottom_seg, after_seg).

    Every table has a chain of three relocated segments 0xFA0 paras apart:
    the two playfield halves, then a heavily-referenced data segment that
    begins immediately after the playfield.
    """
    segs = exe.seg_values
    starts = [a for a in sorted(segs) if a + HALF_PARAS in segs and a - HALF_PARAS not in segs]
    chains = [(a, a + HALF_PARAS, a + 2 * HALF_PARAS) for a in starts if a + 2 * HALF_PARAS in segs]
    if len(chains) != 1:
        raise ValueError(f"{exe.path}: expected one 3-segment chain, got {chains}")
    return chains[0]


def playfield(exe: TableExe) -> np.ndarray:
    top = find_playfield_segments(exe)[0]
    start = exe.image_off(top)
    raw = np.frombuffer(exe.data[start : start + 2 * HALF], dtype=np.uint8)
    return raw.reshape(400, 320).copy()


def data_segment(exe: TableExe) -> int:
    """Entry code starts: push ds / mov ax,0 / push ax / mov ax,<DS> / mov ds,ax."""
    entry = exe.image_off(exe.entry_cs, exe.entry_ip)
    code = exe.data[entry : entry + 32]
    m = re.search(rb"\xb8(..)\x8e\xd8", code, re.S)
    if not m:
        raise ValueError(f"{exe.path}: could not find DS setup at entry")
    return struct.unpack("<H", m.group(1))[0]
