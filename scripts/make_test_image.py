"""Generate a PNG containing large block text, with no image libraries.

Used to test the vision projector: the model either reads the text or it
does not, which makes the result unambiguous.
"""

import argparse
import struct
import zlib

# Minimal 5x7 bitmap font, only the glyphs the test needs.
FONT = {
    "G": ("01110", "10001", "10000", "10111", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "C": ("01110", "10001", "10000", "10000", "10000", "10001", "01110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    " ": ("00000",) * 7,
}


def render(text: str, scale: int, pad: int) -> tuple[list[bytearray], int, int]:
    glyphs = [FONT[c] for c in text]
    cols = sum(len(g[0]) + 1 for g in glyphs) - 1
    width = cols * scale + pad * 2
    height = 7 * scale + pad * 2
    rows = [bytearray(b"\xff" * (width * 3)) for _ in range(height)]

    x0 = pad
    for glyph in glyphs:
        for gy, line in enumerate(glyph):
            for gx, bit in enumerate(line):
                if bit != "1":
                    continue
                for dy in range(scale):
                    row = rows[pad + gy * scale + dy]
                    start = (x0 + gx * scale) * 3
                    # Solid black block, 3 bytes per pixel.
                    row[start:start + scale * 3] = b"\x00" * (scale * 3)
        x0 += (len(glyph[0]) + 1) * scale
    return rows, width, height


def write_png(path: str, rows: list[bytearray], width: int, height: int) -> None:
    raw = b"".join(b"\x00" + bytes(r) for r in rows)  # filter type 0 per row

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", ihdr))
        fh.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        fh.write(chunk(b"IEND", b""))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", default="ARC 742")
    ap.add_argument("--out", default="/tmp/vision-test.png")
    ap.add_argument("--scale", type=int, default=24)
    ap.add_argument("--pad", type=int, default=40)
    a = ap.parse_args()

    text = a.text.upper()
    missing = sorted(set(text) - set(FONT))
    if missing:
        raise SystemExit(f"no glyph for: {missing}")

    rows, w, h = render(text, a.scale, a.pad)
    write_png(a.out, rows, w, h)
    print(f"wrote {a.out} ({w}x{h}) containing {text!r}")


if __name__ == "__main__":
    main()
