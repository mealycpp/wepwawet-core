# payload_load — real Earth-observation payload workload (mission-load experiment)

**What it is.** A payload-processor workload for the WEPWAWET mission-load experiment, made of a real
standard algorithm on real data:
- **Algorithm:** CCSDS 121.0-B lossless compression (Rice / Adaptive Entropy Coding), via the vendored
  open-source **libaec 1.1.8** (`libaec/`, BSD-2, built with a plain Makefile, no CMake, no internet).
  `ccsds_conformance` checks this build against the official CCSDS 121.0-B-2 "All Options" test vectors
  (`ccsds_testdata/`, n = 1–16 bit), using the same procedure as libaec's own `sampledata.sh`.
- **Data:** tiles of a real satellite band, uint16 (Landsat 8/9 C2 L1 or Sentinel-2) from
  `fetch_scene.sh`. The fallback is a real Landsat 7 subset in `sample_data/`.
  **Synthetic data is used only if you pass `--synthetic`, and it is flagged in stderr and in the JSON.**

**What it does.**
- Each worker thread is pinned to a core, with periodic frame releases at `--rate` frames/s.
- Every frame (one tile) is compressed with CCSDS 121.0.
- `--verify-every N` decompresses every Nth frame and compares it bit-for-bit.
- The CSV has one row per frame: processing time, lateness, deadline miss, compressed size.
- At exit it prints a JSON summary: frames, p50/p99/max frame time, deadline misses, compression ratio,
  MB/s while busy, and the CPU busy fraction per thread.

## Board commands (AUP1 / AUP2)

```bash
# 1. build (also runs the CCSDS conformance check: must say 40/40 ... PASS)
cd ~/payload && bash build_payload.sh

# 2. real data (needs internet on the board; record data/scene.tif.json with the results)
bash fetch_scene.sh            # auto: Planetary Computer Landsat C2 L1 -> Earth Search Sentinel-2 -> GCP Landsat C1
#    no internet: copy any real GeoTIFF to the board, then
#    /usr/local/share/pynq-venv/bin/python tiff2raw.py <scene.tif> data/tiles.raw --tile 1024 --max-tiles 16
#    bring-up only (8-bit Landsat 7 subset):
#    python3 tiff2raw.py sample_data/RGB.byte.tif data/tiles.raw --tile 256 --band 0

# 3. calibrate: one core, find the frame time of a 1024x1024 uint16 tile
./payload_load --input data/tiles.raw --cpus 0 --rate 1 --seconds 10 --verify-every 1

# 4. load all four A53 cores (example: 4 threads; pick --rate so that busy fraction is the target load)
./payload_load --input data/tiles.raw --cpus 0,1,2,3 --rate R --seconds 120 --csv payload_4core.csv
```

`--rate` is frames/s **per thread**, and the deadline is 1/rate. Busy fraction ≈ rate × p50 frame time,
so choose `R ≈ target_load / p50` from step 3, e.g. 0.8 / p50 for 80% of each core.

## Files

| File | Purpose |
|---|---|
| `payload_load.c` | The workload: pthreads, `sched_setaffinity`, `clock_nanosleep`-paced, SIGINT/SIGTERM safe |
| `libaec/` | Vendored libaec 1.1.8 sources (encoder, decoder, vector), hand-written `config.h`, plain `Makefile` |
| `ccsds_conformance.c`, `ccsds_testdata/` | CCSDS 121.0-B-2 reference vectors; encode bit-exact or size-exact, decode exact |
| `fetch_scene.py` / `fetch_scene.sh` | STAC search + download of one real band (stdlib only), writes provenance JSON |
| `tiff2raw.py` | Stdlib GeoTIFF reader (none/LZW/Deflate/PackBits, predictor 2, strips/tiles, chunky/planar, 8/16-bit) → `WCRAW1` tiles. Uses numpy if available (pynq venv) for speed; result is identical either way |
| `test_tiff2raw_vs_ref.py`, `tiff_decoder_crosscheck.log` | Decoder cross-check against tifffile on real GeoTIFFs |
| `sample_data/` | Fallback real image (Landsat 7 subset) and its source note |

## Input format (`WCRAW1`)

- 32-byte header: `"WCRAW1\0\0"`, then u32 `width`, `height`, `bits`, `nframes`, `flags`, `reserved`.
  `flags` bit 0 means synthetic.
- Then `nframes` frames of width×height samples: uint8, or uint16 little-endian.
