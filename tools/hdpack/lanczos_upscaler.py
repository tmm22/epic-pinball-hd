#!/usr/bin/env python3
"""Stand-in for an external AI upscaler, for testing make_pack.py's --upscaler-cmd hook:

    make_pack.py --table 1 --upscaler-cmd '.venv/bin/python tools/hdpack/lanczos_upscaler.py {in} {out} {scale}'

Any real tool with the same contract works (reads PNG {in}, writes PNG {out} at {scale}x),
e.g. 'realesrgan-ncnn-vulkan -i {in} -o {out} -s {scale} -n realesrgan-x4plus-anime'.
"""
import sys
from PIL import Image

src, dst, s = sys.argv[1], sys.argv[2], int(sys.argv[3])
im = Image.open(src).convert("RGB")
im.resize((im.width * s, im.height * s), Image.LANCZOS).save(dst)
