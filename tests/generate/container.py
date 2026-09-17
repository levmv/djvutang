#!/usr/bin/env python3
"""Regenerate tiny container/OCR regression fixtures; requires cjb2 and djvm."""
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

def command(*args):
    return subprocess.run(args, check=True, capture_output=True, timeout=30)


def u32(data, pos):
    return struct.unpack_from(">I", data, pos)[0]


def chunks(data, start, end):
    result = []
    while start + 8 <= end:
        size = u32(data, start + 4)
        stop = start + 8 + size
        assert stop <= end
        result.append((data[start:start + 4], start, stop + (size & 1)))
        start = stop + (size & 1)
    return result


def append_chunk(data, tag, payload):
    body = data[12:12 + u32(data, 8)]
    body += bytes(len(body) & 1)
    body += tag + struct.pack(">I", len(payload)) + payload + bytes(len(payload) & 1)
    return data[:8] + struct.pack(">I", len(body)) + body


def zone(kind, x, y, width, height, start, length, children):
    return (bytes([kind]) + struct.pack(">HHHHH", x + 32768, y + 32768,
            width + 32768, height + 32768, start + 32768)
            + length.to_bytes(3, "big") + len(children).to_bytes(3, "big")
            + b"".join(children))


def generate(out):
    for name, width, height in [("a", 37, 29), ("b", 31, 41)]:
        pbm = out / f"{name}.pbm"
        pixels = [str(int(x == 3 or y == 5 or (7 < x < 14 and 10 < y < 17)))
                  for y in range(height) for x in range(width)]
        pbm.write_text(f"P1\n{width} {height}\n" + " ".join(pixels) + "\n")
        command("cjb2", str(pbm), str(out / f"{name}.djvu"))
    command("djvm", "-c", str(out / "ordered.djvu"), str(out / "a.djvu"), str(out / "b.djvu"))
    original = (out / "ordered.djvu").read_bytes()
    entries = chunks(original, 16, 12 + u32(original, 8))
    forms = [(p, end) for tag, p, end in entries if tag == b"FORM"]
    assert len(forms) == 2 and forms[0][1] == forms[1][0] and forms[1][1] in {len(original), len(original) + 1}
    first, second = forms
    second_bytes = original[second[0]:second[1]]
    second_bytes += bytes(len(second_bytes) & 1)
    reordered = bytearray(original[:first[0]] + second_bytes
                        + original[first[0]:first[1]])
    struct.pack_into(">I", reordered, 8, len(reordered) - 12)
    dirm = next(p + 8 for tag, p, end in entries if tag == b"DIRM")
    assert original[dirm] == 0x81 and original[dirm + 1:dirm + 3] == b"\0\2"
    assert [u32(original, dirm + 3 + i * 4) for i in range(2)] == [first[0], second[0]]
    struct.pack_into(">II", reordered, dirm + 3, first[0] + second[1] - second[0], first[0])
    (out / "reordered.djvu").write_bytes(reordered)

    single = (out / "a.djvu").read_bytes()
    # A valid image with a bounded, deliberately invalid optional zone type 0.
    (out / "bad-text.djvu").write_bytes(append_chunk(single, b"TXTa", b"\0\0\1A\1\0"))
    rotated = bytearray(single)
    info = next(p + 8 for tag, p, end in chunks(single, 16, len(single)) if tag == b"INFO")
    rotated[info + 9] = 6  # INFO orientation: counterclockwise quarter-turn.
    (out / "rotated.djvu").write_bytes(rotated)
    text = "AЖB".encode("utf-8")
    word = zone(6, 0, 0, 10, 10, 1, 2, [])
    page = zone(1, 0, 0, 37, 29, 0, len(text), [word])
    payload = len(text).to_bytes(3, "big") + text + b"\1" + page
    (out / "unicode-text.djvu").write_bytes(append_chunk(single, b"TXTa", payload))

    target = Path(__file__).resolve().parents[1] / 'fixtures'
    for source, name in [('a', 'plain'), ('bad-text', 'bad-text'),
                         ('rotated', 'rotated'), ('reordered', 'reordered'),
                         ('unicode-text', 'unicode-text')]:
        shutil.copyfile(out / f'{source}.djvu', target / f'{name}.djvu')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='djvu-container-') as directory:
        generate(Path(directory))
