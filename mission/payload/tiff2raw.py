#!/usr/bin/env python3
"""tiff2raw.py -- real satellite imagery (GeoTIFF) -> WCRAW1 tiles for payload_load. Python 3 stdlib only.

Supports classic little/big-endian TIFF (incl. Cloud-Optimized GeoTIFF as used by Landsat Collection 2 and
Sentinel-2 JP2 converted to TIFF), compression none / LZW / Deflate / PackBits, horizontal predictor 2,
strip or tile layout, chunky or planar samples, 8- or 16-bit unsigned samples.

usage: python3 tiff2raw.py SCENE.TIF out.raw [--tile 1024] [--band 0] [--max-tiles 16] [--min-valid 0.5] [--region x,y,w,h]
Tiles that are mostly fill (0) -- e.g. the black border of a Landsat scene -- are skipped (--min-valid).
"""
import argparse, struct, sys, zlib

TYPES = {1: 'B', 2: 'c', 3: 'H', 4: 'I', 5: 'II', 6: 'b', 7: 'B', 8: 'h', 9: 'i', 10: 'ii', 11: 'f', 12: 'd', 16: 'Q'}
SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 16: 8}


def read_ifd(buf, off, e):
    n = struct.unpack_from(e + 'H', buf, off)[0]
    tags = {}
    for i in range(n):
        tag, typ, cnt, val = struct.unpack_from(e + 'HHI4s', buf, off + 2 + 12 * i)
        size = SIZES.get(typ, 1) * cnt
        data = val if size <= 4 else buf[struct.unpack(e + 'I', val)[0]:struct.unpack(e + 'I', val)[0] + size]
        fmt = TYPES.get(typ, 'B')
        if typ in (5, 10):
            vals = struct.unpack(e + fmt[0] * (2 * cnt), data[:size])
        elif typ == 2:
            vals = data[:size]
        else:
            vals = struct.unpack(e + fmt * cnt, data[:size])
        tags[tag] = vals
    return tags


def lzw_decode(data):
    out = bytearray(); table = [bytes([i]) for i in range(256)] + [b'', b'']
    bitpos, nbits, prev = 0, 9, None
    total = len(data) * 8
    while bitpos + nbits <= total:
        byte = bitpos >> 3
        chunk = int.from_bytes(data[byte:byte + 4].ljust(4, b'\0'), 'big')
        code = (chunk >> (32 - (bitpos & 7) - nbits)) & ((1 << nbits) - 1)
        bitpos += nbits
        if code == 256:
            table = table[:258]; nbits = 9; prev = None; continue
        if code == 257:
            break
        if prev is None:
            entry = table[code]
        elif code < len(table):
            entry = table[code]; table.append(prev + entry[:1])
        else:
            entry = prev + prev[:1]; table.append(entry)
        out += entry; prev = entry
        if len(table) + 1 >= (1 << nbits) and nbits < 12:
            nbits += 1
    return bytes(out)


def packbits_decode(data):
    out = bytearray(); i = 0
    while i < len(data):
        n = data[i]; i += 1
        if n < 128:
            out += data[i:i + n + 1]; i += n + 1
        elif n > 128:
            out += data[i:i + 1] * (257 - n); i += 1
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('tif'); ap.add_argument('out')
    ap.add_argument('--tile', type=int, default=1024); ap.add_argument('--band', type=int, default=0)
    ap.add_argument('--max-tiles', type=int, default=16); ap.add_argument('--min-valid', type=float, default=0.5)
    ap.add_argument('--region', default=None, help='x,y,w,h crop in source pixels (default: centred)')
    a = ap.parse_args()
    buf = open(a.tif, 'rb').read()
    e = {b'II': '<', b'MM': '>'}[buf[:2]]
    if struct.unpack_from(e + 'H', buf, 2)[0] != 42:
        sys.exit('BigTIFF/unsupported TIFF variant')
    t = read_ifd(buf, struct.unpack_from(e + 'I', buf, 4)[0], e)
    W, H = t[256][0], t[257][0]
    bps = t.get(258, (1,))[0]; spp = t.get(277, (1,))[0]; comp = t.get(259, (1,))[0]
    pred = t.get(317, (1,))[0]; planar = t.get(284, (1,))[0]; fmt = t.get(339, (1,))[0]
    if bps not in (8, 16) or fmt not in (1,):
        sys.exit(f'unsupported sample format bps={bps} sampleformat={fmt}')
    bpp = bps // 8
    if 322 in t:   # tiled
        tw, th = t[322][0], t[323][0]; offs, cnts = t[324], t[325]
    else:          # stripped
        tw, th = W, t.get(278, (H,))[0]; offs, cnts = t[273], t[279]
    chunk_spp = 1 if planar == 2 else spp
    tiles_x = (W + tw - 1) // tw; tiles_y = (H + th - 1) // th
    per_plane = tiles_x * tiles_y
    T = min(a.tile, W, H)
    # region of interest: centred square holding up to max_tiles output tiles (avoids decoding a whole
    # 7k x 7k Landsat band and avoids the black scene border); --region overrides
    if a.region:
        rx, ry, rw, rh = (int(v) for v in a.region.split(','))
    else:
        k = max(1, int(a.max_tiles ** 0.5 + 0.999))
        rw = min(W, k * T); rh = min(H, k * T); rx = (W - rw) // 2; ry = (H - rh) // 2
    img = bytearray(rw * rh * bpp)
    try:
        import numpy as np
    except ImportError:
        np = None

    def decode(raw):
        if comp == 1: return raw
        if comp == 5: return lzw_decode(raw)
        if comp in (8, 32946): return zlib.decompress(raw)
        if comp == 32773: return packbits_decode(raw)
        sys.exit(f'unsupported compression {comp} (JPEG/lossy TIFFs are deliberately not supported)')

    band = a.band if planar == 1 else 0
    for ci in range(per_plane):
        x0 = (ci % tiles_x) * tw; y0 = (ci // tiles_x) * th
        if x0 >= rx + rw or x0 + tw <= rx or y0 >= ry + rh or y0 + th <= ry:
            continue
        idx = ci + (a.band * per_plane if planar == 2 else 0)
        raw = decode(buf[offs[idx]:offs[idx] + cnts[idx]])
        rows = th if 322 in t else min(th, H - y0); cols = tw
        need = rows * cols * chunk_spp * bpp
        raw = raw.ljust(need, b'\0')[:need]
        if np is not None:
            dt = np.dtype((e + ('u1' if bpp == 1 else 'u2')))
            arr = np.frombuffer(raw, dtype=dt).reshape(rows, cols, chunk_spp).astype(np.uint32)
            if pred == 2:
                arr = np.cumsum(arr, axis=1) & ((1 << bps) - 1)
            plane = arr[:, :, band].astype('<u1' if bpp == 1 else '<u2')
            getrow = lambda r, c0, c1: plane[r, c0:c1].tobytes()
        else:
            samp = list(struct.unpack(e + ('B' if bpp == 1 else 'H') * (rows * cols * chunk_spp), raw))
            if pred == 2:
                for r in range(rows):
                    base = r * cols * chunk_spp
                    for c in range(chunk_spp, cols * chunk_spp):
                        samp[base + c] = (samp[base + c] + samp[base + c - chunk_spp]) & ((1 << bps) - 1)
            def getrow(r, c0, c1, samp=samp):
                v = samp[(r * cols + c0) * chunk_spp + band:(r * cols + c1) * chunk_spp:chunk_spp]
                return struct.pack('<' + ('B' if bpp == 1 else 'H') * len(v), *v)
        for r in range(rows):
            y = y0 + r
            if y < ry: continue
            if y >= ry + rh or y >= H: break
            c0 = max(0, rx - x0); c1 = min(cols, rx + rw - x0, W - x0)
            if c1 <= c0: continue
            o = ((y - ry) * rw + (x0 + c0 - rx)) * bpp
            img[o:o + (c1 - c0) * bpp] = getrow(r, c0, c1)
    W0, H0 = W, H; W, H = rw, rh
    T = min(T, W, H)
    tiles = []
    for ty in range(H // T):
        for tx in range(W // T):
            tb = bytearray()
            for r in range(T):
                o = ((ty * T + r) * W + tx * T) * bpp
                tb += img[o:o + T * bpp]
            vals = tb if bpp == 1 else memoryview(tb).cast('H')
            nz = sum(1 for v in vals if v) / (T * T)
            if nz >= a.min_valid:
                tiles.append(bytes(tb))
            if len(tiles) >= a.max_tiles: break
        if len(tiles) >= a.max_tiles: break
    if not tiles:
        sys.exit('no tile passed --min-valid; lower it or use a smaller --tile')
    with open(a.out, 'wb') as f:
        f.write(b'WCRAW1\0\0' + struct.pack('<6I', T, T, bps, len(tiles), 0, 0))
        for tb in tiles: f.write(tb)
    print(f'{a.tif}: {W0}x{H0} region {rx},{ry},{rw}x{rh} {bps}-bit spp={spp} comp={comp} pred={pred} -> {len(tiles)} tiles {T}x{T} band {a.band} -> {a.out}')


if __name__ == '__main__':
    main()
