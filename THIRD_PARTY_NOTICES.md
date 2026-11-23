# Third-party notices

The PolyForm Noncommercial licence in `LICENSE` covers only material written for
WEPWAWET-CORE. The items below belong to their authors and keep their own licences.

| Component | Where it appears | Licence | Upstream |
|---|---|---|---|
| libaec 1.1.8 (CCSDS 121.0 codec) | `mission/payload/libaec/` | BSD-2-Clause, per the vendored `LICENSE.txt` | https://github.com/MathisRosenhauer/libaec |
| PQClean ML-DSA-44, clean | `fprime/HwAccelMgr/pqclean/` | Public domain (CC0), per the vendored `LICENSE_PQClean_mldsa44_clean` | https://github.com/PQClean/PQClean |
| PQClean ML-DSA-44, aarch64 | `fprime/HwAccelMgr/pqclean_neon/` | MIT or CC0 1.0, per the vendored `LICENSE_PQClean_mldsa44_aarch64` and per-file headers | https://github.com/PQClean/PQClean |
| PQClean-derived sources | `ground_ca/src/`, `analysis/attempts_reference/sign.c` | No licence file vendored here; see upstream | https://github.com/PQClean/PQClean |
| F Prime | `fprime/` components build against it; the framework is not redistributed | See upstream | https://github.com/nasa/fprime |
| Vitis HLS generated Verilog | `rtl/*/hls_*` | Generated from project C++ sources; generated-file headers retained; see upstream for tool terms | https://www.amd.com |
| gem5 | `gem5/` scripts run against an external build; gem5 is not redistributed | See upstream | https://www.gem5.org |
| Sample scene `RGB.byte.tif` | `mission/payload/sample_data/` | Landsat 7 subset from the rasterio test data, per `SOURCE.txt`; see upstream | https://github.com/rasterio/rasterio |

