# Line-for-line Python port of SgfHeaderScan's size logic, OLD (regex) vs NEW (root-node scan).
# This checks the algorithm, not the compiled Swift; the XCTests in the repo are the real gate.
import re, sys
def old(sgf):
    t = sgf[sgf.index(';'):]
    m = re.search(r'SZ\[(\d+)(?::(\d+))?\]', t)
    if not m: return (19, 19, True)
    w = int(m.group(1)); h = int(m.group(2)) if m.group(2) else w
    return (w, h, True)               # old code had no "supported" notion
def root_props(sgf):
    res = {}; i = sgf.find('('); 
    if i < 0: return res
    j = sgf.find(';', i)
    if j < 0: return res
    i = j + 1; key = ''; has = False
    while i < len(sgf):
        c = sgf[i]
        if c.isascii() and c.isalpha():
            if has: key = ''; has = False
            key += c; i += 1
        elif c.isspace(): i += 1
        elif c == '[' and key:
            i += 1; v = ''; esc = False; closed = False
            while i < len(sgf):
                vc = sgf[i]; i += 1
                if esc: esc = False; v += vc
                elif vc == '\\': esc = True
                elif vc == ']': closed = True; break
                else: v += vc
            if not closed: break
            res.setdefault(key, []).append(v); has = True
        else: break
    return res
def parse(raw):
    parts = raw.split(':')
    try:
        if len(parts) == 1: n = int(parts[0].strip()); return (n, n)
        if len(parts) == 2: return (int(parts[0].strip()), int(parts[1].strip()))
    except ValueError: return None
    return None
def new(sgf):
    vals = root_props(sgf).get('SZ')
    if vals is None: return (19, 19, True)
    p = parse(vals[0])
    if p is None: return (19, 19, False)
    cl = lambda x: min(max(x, 2), 37)
    return (cl(p[0]), cl(p[1]), len(vals) == 1 and 2 <= p[0] <= 37 and 2 <= p[1] <= 37)
cases = {
 r'(;GM[1]C[x\]SZ[100000:100000]SZ[19];B[dd])': 'C++ loads 19x19',
 r'(;GM[1]C[x\]SZ[9]SZ[37];B[aa])': 'C++ (MAX_LEN 37) loads 37x37',
 r'(;GM[1]C[a\]SZ[3]SZ[13])': 'C++ loads 13x13',
 r'(;GM[1]SZ[4000000000:4000000000])': 'C++ rejects (> MAX_LEN)',
 r'(;GM[1]SZ[9]SZ[37])': 'C++ rejects (non-singleton)',
 r'(;GM[1];SZ[9]B[aa])': 'C++ loads 19x19 (SZ not in root)',
 r'(;GM[1]SZ[ 37 : 2 ])': 'C++ loads 37x2',
 r'(;GM[1]SZ[19];B[dd])': 'C++ loads 19x19 (normal game)',
}
for s, truth in cases.items():
    o = old(s); n = new(s)
    alloc = o[0] * o[1]
    print(f"{s:46} OLD={o[0]}x{o[1]}{' (alloc %.0e cells)' % alloc if alloc > 37*37 else ''}  NEW={n[0]}x{n[1]} supported={n[2]}  | truth: {truth}")
