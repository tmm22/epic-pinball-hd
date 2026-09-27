"""SFXn.PIN sound-effect banks -> WAV files.

Layout (inferred, see docs/formats/sfx-pin.md):
  header: N entries of (u16 length_bytes, u16 offset_paragraphs), where
          N = first_offset_paragraphs * 16 / 4 (header runs up to sample 0)
  body:   signed 8-bit mono PCM, each sample starts on a 16-byte boundary.
The playback rate is not yet confirmed from the engine; 11025 Hz is a guess.

Usage: .venv/bin/python tools/sfx.py original/SFX1.PIN out_dir [rate]
"""
import os
import struct
import sys
import wave


def parse(data: bytes) -> list:
    first_off = struct.unpack_from("<H", data, 2)[0] * 16
    entries = []
    for i in range(first_off // 4):
        length, para = struct.unpack_from("<HH", data, i * 4)
        off = para * 16
        if length == 0 or off + length > len(data):
            continue
        entries.append((i, off, length))
    return entries


def to_wav(pcm_signed: bytes, path: str, rate: int) -> None:
    unsigned = bytes((b + 128) & 0xFF for b in pcm_signed)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)  # WAV 8-bit is unsigned
        w.setframerate(rate)
        w.writeframes(unsigned)


def main():
    src, out = sys.argv[1], sys.argv[2]
    rate = int(sys.argv[3]) if len(sys.argv) > 3 else 11025
    data = open(src, "rb").read()
    os.makedirs(out, exist_ok=True)
    entries = parse(data)
    for i, off, length in entries:
        to_wav(data[off : off + length], os.path.join(out, f"sfx{i:02d}.wav"), rate)
    print(f"{src}: {len(entries)} samples -> {out}")


if __name__ == "__main__":
    main()
