#!/bin/bash
# Fetch one real satellite band and cut it into payload tiles. Run on the AUP board (needs internet).
#   bash fetch_scene.sh [pc|e84|gcp|auto]      -> data/scene.tif, data/scene.tif.json, data/tiles.raw
set -e; cd "$(dirname "$0")"; mkdir -p data
python3 fetch_scene.py --source "${1:-auto}" --out data/scene.tif
PY=python3; [ -x /usr/local/share/pynq-venv/bin/python ] && PY=/usr/local/share/pynq-venv/bin/python   # has numpy -> fast
$PY tiff2raw.py data/scene.tif data/tiles.raw --tile 1024 --max-tiles 16 --min-valid 0.9
ls -la data/
