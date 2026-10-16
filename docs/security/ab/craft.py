# Crafts hostile model files for the A/B runs from a known-good v8 model.
# usage: python3 craft.py <out-dir> cpp/tests/models/g170-b6c96-s175395328-d26788732.bin.gz
import gzip, struct, sys, os
out = sys.argv[1]
src = gzip.open(os.path.expanduser(sys.argv[2])).read()

def tokens_until_bin(buf, pos, n):
    """Read n whitespace tokens starting at pos; return (tokens, pos)."""
    toks = []
    while len(toks) < n:
        while buf[pos:pos+1].isspace(): pos += 1
        end = pos
        while not buf[end:end+1].isspace(): end += 1
        toks.append(buf[pos:end].decode()); pos = end
    return toks, pos

# Header: name version nIn nGlobal ; trunk: name blocks c mid regular dilated gpool ; conv1: name y x ic oc dy dx
hdr, p = tokens_until_bin(src, 0, 4)
trunk, p = tokens_until_bin(src, p, 7)
conv, p = tokens_until_bin(src, p, 7)
at = src.index(b"@BIN@", p) + 5
y, x, ic, oc = map(int, conv[1:5])
p = at + y*x*ic*oc*4
mm, p2 = tokens_until_bin(src, p, 3)          # ginputw ic oc
assert mm[1] == hdr[3], (mm, hdr)
mat = src.index(b"@BIN@", p2) + 5
mic, moc = int(mm[1]), int(mm[2])
rest = src[mat + mic*moc*4:]

def w(name, data):
    with gzip.open(f"{out}/{name}", "wb") as f: f.write(data)

# M3: 1 global input channel instead of 19 (consistent within the file, wrong for v8)
newHdr = f"{hdr[0]}\n{hdr[1]}\n{hdr[2]}\n1\n".encode()
w("m3_global_channels.bin.gz", newHdr + src[len(b"\n".join(t.encode() for t in hdr))+1:p]
  + f"\n{mm[0]}\n1\n{moc}\n@BIN@".encode() + src[mat:mat+moc*4] + rest)

# M2/alloc: a tiny file whose first conv claims 1x1x40000x40000 (1.6e9 floats, 6.4 GB) but holds no weights
prefix = src[:p - y*x*ic*oc*4 - 5]  # up to just before @BIN@ of conv1
prefix = prefix[:prefix.rindex(conv[0].encode())]
w("m2_huge_conv.bin.gz", prefix + f"{conv[0]}\n1\n1\n40000\n40000\n1\n1\n@BIN@".encode() + b"\0" * 64)
# M2/overflow: 1x1x65536x65537 wraps a 32-bit int product to 65536
w("m2_overflow_conv.bin.gz", prefix + f"{conv[0]}\n1\n1\n65536\n65537\n1\n1\n@BIN@".encode() + b"\0" * 64)

# M4: converter-only case. The first matmul declares -1 input channels
# (desc.cpp already rejects this; the CoreML converter parser did not).
m3 = gzip.open(f"{out}/m3_global_channels.bin.gz").read()
i = m3.index(f"{mm[0]}\n1\n{moc}\n".encode())
w("m4_neg_matmul.bin.gz", m3[:i] + f"{mm[0]}\n-1\n{moc}\n@BIN@".encode() + b"\0" * 64)

# M1: decompression bomb, ~1.5 MB on disk, 1.5 GB inflated
with gzip.open(f"{out}/m1_bomb.bin.gz", "wb", compresslevel=9) as f:
    f.write(src[:200]); chunk = b" " * (1 << 24)
    for _ in range(96): f.write(chunk)
for n in os.listdir(out):
    if n.endswith(".gz"): print(n, os.path.getsize(f"{out}/{n}"))
