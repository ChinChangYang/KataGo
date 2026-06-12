#!/usr/bin/env python3
"""Verify the generated icon.

Modes:
  probe   : hard assertions on probe-pixel colors of the rendered shipped
            preview (regression test; exits 1 on failure).
  overlay : Sobel edge overlay of the match-geometry preview against the
            original raster icon; writes overlay.png (yellow=match,
            red=original-only, green=render-only) and prints the match %.
            Informational: the original is hand-drawn and asymmetric, so
            expect roughly 50-60% at +/-2px tolerance. Inspect the overlay.

Usage:
  python3 verify_icon.py probe   <preview.png>
  python3 verify_icon.py overlay <original.png> <match-preview.png> <out.png>
"""
import struct
import sys
import zlib


def load_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", f"not a PNG: {path}"
    i, idat = 8, b""
    W = H = ct = None
    while i < len(d):
        ln = struct.unpack(">I", d[i:i + 4])[0]
        typ, data = d[i + 4:i + 8], d[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b"IHDR":
            W, H, bd, ct = struct.unpack(">IIBB", data[:10])
            assert bd == 8, "only 8-bit PNGs supported"
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    stride = W * ch
    out, prev, pos = bytearray(), bytearray(stride), 0

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)

    for _ in range(H):
        f = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                line[x] = (line[x] + paeth(a, b, c)) & 255
        out += line
        prev = line
    return W, H, ch, bytes(out)


def write_png_rgb(path, W, H, rgb):
    def chunk(t, d):
        return (struct.pack(">I", len(d)) + t + d
                + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF))
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        raw += rgb[y * W * 3:(y + 1) * W * 3]
    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


def probe(path):
    W, H, ch, buf = load_png(path)
    assert (W, H) == (1024, 1024), f"expected 1024x1024, got {W}x{H}"

    def px(x, y):
        o = (y * W + x) * ch
        return buf[o], buf[o + 1], buf[o + 2]

    def lum(x, y):
        r, g, b = px(x, y)
        return (r + g + b) // 3

    def is_gold(x, y):
        r, g, b = px(x, y)
        return r > g > b and r > 180 and (r - b) > 80

    checks = [
        ("N field white", lum(512, 112) >= 200),
        ("E field black", lum(912, 512) <= 30),
        ("S field white", lum(512, 912) >= 200),
        ("W field black", lum(112, 512) <= 30),
        ("astroid gold center", is_gold(512, 512)),
        ("gold corner", is_gold(40, 40)),
        ("TL stone dark", lum(338, 338) <= 120),
        ("TR stone light", lum(686, 338) >= 225),
        ("BL stone light", lum(338, 686) >= 225),
        ("BR stone dark", lum(686, 686) <= 120),
    ]
    ok = True
    for name, passed in checks:
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
        ok = ok and passed
    return ok


def lum_grid(path, S=512):
    W, H, ch, buf = load_png(path)
    g = bytearray(S * S)
    for y in range(S):
        sy = int(y * H / S)
        for x in range(S):
            sx = int(x * W / S)
            o = (sy * W + sx) * ch
            g[y * S + x] = (buf[o] + buf[o + 1] + buf[o + 2]) // 3
    return g


def sobel(g, S=512, t=60):
    e = bytearray(S * S)
    for y in range(1, S - 1):
        for x in range(1, S - 1):
            i = y * S + x
            gx = ((g[i - S + 1] + 2 * g[i + 1] + g[i + S + 1])
                  - (g[i - S - 1] + 2 * g[i - 1] + g[i + S - 1]))
            gy = ((g[i + S - 1] + 2 * g[i + S] + g[i + S + 1])
                  - (g[i - S - 1] + 2 * g[i - S] + g[i - S + 1]))
            if abs(gx) + abs(gy) > t * 4:
                e[i] = 255
    return e


def dilate(e, S=512, r=2):
    d = bytearray(S * S)
    for y in range(S):
        for x in range(S):
            if e[y * S + x]:
                for dy in range(-r, r + 1):
                    for dx in range(-r, r + 1):
                        yy, xx = y + dy, x + dx
                        if 0 <= yy < S and 0 <= xx < S:
                            d[yy * S + xx] = 255
    return d


def overlay(orig_path, render_path, out_path, S=512):
    eo = sobel(lum_grid(orig_path, S), S)
    er = sobel(lum_grid(render_path, S), S)
    do, dr = dilate(eo, S), dilate(er, S)
    rgb = bytearray(S * S * 3)
    m = t = 0
    for i in range(S * S):
        R, G, B = 20, 20, 20
        if (eo[i] and dr[i]) or (er[i] and do[i]):
            R, G, B = 255, 230, 40
        elif eo[i]:
            R, G, B = 255, 60, 60
        elif er[i]:
            R, G, B = 70, 255, 90
        if eo[i]:
            t += 1
            m += 1 if dr[i] else 0
        rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = R, G, B
    write_png_rgb(out_path, S, S, rgb)
    print(f"edge match vs original: {100 * m / t:.1f}%  (overlay: {out_path})")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "probe":
        sys.exit(0 if probe(sys.argv[2]) else 1)
    elif len(sys.argv) == 5 and sys.argv[1] == "overlay":
        overlay(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__)
        sys.exit(2)
