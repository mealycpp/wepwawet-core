#!/usr/bin/env python3
"""fetch_scene.py -- download ONE real satellite band (uint16 GeoTIFF) for payload_load. Python 3 stdlib only.

Sources, tried in order (or pick one with --source):
  pc      Landsat 8/9 Collection 2 Level-1 (OLI, uint16 COG) via Microsoft Planetary Computer STAC
          (https://planetarycomputer.microsoft.com/api/stac/v1, anonymous SAS token from /api/sas/v1/token)
  e84     Sentinel-2 L2A (MSI, uint16 COG, public bucket sentinel-cogs) via Element 84 Earth Search STAC
          (https://earth-search.aws.element84.com/v1)
  gcp     Landsat 8 Collection 1 Level-1 band from the Google Cloud public dataset (fixed URL)
usage: python3 fetch_scene.py [--source pc|e84|gcp|auto] [--bbox lon0,lat0,lon1,lat1] [--out scene.tif]
Prints the scene id and source URL (record them with the experiment). No authentication needed.
"""
import argparse, json, sys, time, urllib.parse, urllib.request

UA = {'User-Agent': 'wepwawet-payload-fetch/1.0'}
GCP_URL = ('https://storage.googleapis.com/gcp-public-data-landsat/LC08/01/044/034/'
           'LC08_L1TP_044034_20170829_20170914_01_T1/LC08_L1TP_044034_20170829_20170914_01_T1_B4.TIF')


def get_json(url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    hdr = dict(UA, **({'Content-Type': 'application/json'} if data else {}))
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=hdr), timeout=60) as r:
        return json.loads(r.read())


def download(url, out):
    t0 = time.time(); n = 0
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r, open(out, 'wb') as f:
        while True:
            b = r.read(1 << 20)
            if not b: break
            f.write(b); n += len(b)
            print(f'\r  {n / 1e6:7.1f} MB', end='', file=sys.stderr)
    print(f'\r  {n / 1e6:7.1f} MB in {time.time() - t0:.0f} s', file=sys.stderr)
    return n


def best(features):
    feats = [f for f in features if f.get('properties', {}).get('eo:cloud_cover') is not None]
    return min(feats or features, key=lambda f: f['properties'].get('eo:cloud_cover', 100))


def pick_asset(item, keys):
    for k in keys:
        if k in item['assets']: return k, item['assets'][k]['href']
    for k, a in item['assets'].items():
        if 'geotiff' in a.get('type', '') or a['href'].lower().endswith(('.tif', '.tiff')): return k, a['href']
    raise RuntimeError('no GeoTIFF asset in item')


def src_pc(bbox, dt):
    body = {'collections': ['landsat-c2-l1'], 'bbox': bbox, 'datetime': dt, 'limit': 20,
            'query': {'eo:cloud_cover': {'lt': 10}, 'platform': {'in': ['landsat-8', 'landsat-9']}}}
    items = get_json('https://planetarycomputer.microsoft.com/api/stac/v1/search', body)['features']
    if not items: raise RuntimeError('no Landsat C2 L1 items found')
    it = best(items); key, href = pick_asset(it, ['red', 'B4', 'green', 'nir08'])
    u = urllib.parse.urlparse(href); account = u.netloc.split('.')[0]; container = u.path.lstrip('/').split('/')[0]
    tok = get_json(f'https://planetarycomputer.microsoft.com/api/sas/v1/token/{account}/{container}')['token']
    return it['id'], key, href, href + ('&' if '?' in href else '?') + tok


def src_e84(bbox, dt):
    q = {'collections': ['sentinel-2-l2a'], 'bbox': bbox, 'datetime': dt, 'limit': 20,
         'query': {'eo:cloud_cover': {'lt': 10}}}
    items = get_json('https://earth-search.aws.element84.com/v1/search', q)['features']
    if not items: raise RuntimeError('no Sentinel-2 L2A items found')
    it = best(items); key, href = pick_asset(it, ['red', 'B04', 'green', 'nir'])
    return it['id'], key, href, href


def src_gcp(bbox, dt):
    return 'LC08_L1TP_044034_20170829_20170914_01_T1', 'B4', GCP_URL, GCP_URL


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', default='auto', choices=['auto', 'pc', 'e84', 'gcp'])
    ap.add_argument('--bbox', default='-118.0,33.9,-117.6,34.2', help='lon0,lat0,lon1,lat1 (default: LA / Pomona area)')
    ap.add_argument('--datetime', default='2023-01-01/2025-12-31')
    ap.add_argument('--out', default='scene.tif')
    a = ap.parse_args()
    bbox = [float(v) for v in a.bbox.split(',')]
    order = ['pc', 'e84', 'gcp'] if a.source == 'auto' else [a.source]
    for s in order:
        try:
            sid, key, href, url = {'pc': src_pc, 'e84': src_e84, 'gcp': src_gcp}[s](bbox, a.datetime)
            print(f'[{s}] scene {sid} asset {key}\n  {href}', file=sys.stderr)
            n = download(url, a.out)
            if n < 1_000_000: raise RuntimeError(f'download too small ({n} B)')
            meta = {'source': s, 'scene_id': sid, 'asset': key, 'href': href, 'bytes': n, 'file': a.out,
                    'fetched_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
            open(a.out + '.json', 'w').write(json.dumps(meta, indent=1))
            print(json.dumps(meta)); return 0
        except Exception as ex:
            print(f'[{s}] failed: {type(ex).__name__}: {ex}', file=sys.stderr)
    print('ALL SOURCES FAILED (no internet on this board?). Copy a real GeoTIFF over and use tiff2raw.py on it.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
