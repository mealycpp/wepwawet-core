#!/usr/bin/env python3
"""(JPEG-compressed TIFF, comp=7, is lossy and deliberately unsupported.)
Cross-check tiff2raw.py's stdlib TIFF decoder against tifffile on real GeoTIFFs (first tile, chosen band)."""
import struct, subprocess, sys
import numpy as np, tifffile
D = '<RASTERIO_SRC>/tests/data/'
cases = [(D + 'RGB.byte.tif', 0), (D + 'RGB.byte.tif', 2), (D + 'rgb_lzw.tif', 1), (D + 'rgb_deflate.tif', 1),
         (D + 'world.byte.tif', 0), (D + 'rotated.tif', 0), (D + 'RGBA.uint16.tif', 0),
         (D + 'world.rgb.tif', 2), ('/tmp/u16_cog_like.tif', 0), ('/tmp/u16_lzw_pred2.tif', 0)]
ok = True
for f, band in cases:
    with tifffile.TiffFile(f) as tf:
        p = tf.pages[0]; a = p.asarray()
        if a.ndim == 3:
            a = a[band] if p.planarconfig == 2 else a[..., band]
    T = min(a.shape)
    r = subprocess.run([sys.executable, 'tiff2raw.py', f, '/tmp/t.raw', '--tile', str(T), '--band', str(band),
                        '--min-valid', '0', '--max-tiles', '1', '--region', f'0,0,{T},{T}'], capture_output=True, text=True)
    if r.returncode:
        print(f'{f}: FAILED {r.stderr.strip()[-150:]}'); ok = False; continue
    d = open('/tmp/t.raw', 'rb').read(); w, h, bits, n = struct.unpack('<4I', d[8:24])
    mine = np.frombuffer(d[32:32 + T * T * (2 if bits > 8 else 1)], dtype='<u2' if bits > 8 else 'u1').reshape(T, T)
    same = np.array_equal(mine, a[:T, :T])
    ok &= same
    print(f'{f.split("/")[-1]:20s} band {band} {T}x{T} {bits:2d}-bit : {"MATCH tifffile" if same else "MISMATCH"}')
print('TIFF DECODER CROSS-CHECK:', 'PASS' if ok else 'FAIL')
