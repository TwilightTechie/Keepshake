#!/bin/bash
# One-shot Zephyr workspace setup + P0 firmware build. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .toolchain-venv ]; then
  python3 -m venv .toolchain-venv
fi
.toolchain-venv/bin/pip -q install --upgrade west

if [ ! -d .west ]; then
  .toolchain-venv/bin/west init -l manifest
fi
echo "== west update (fetches zephyr + modules, shallow) =="
.toolchain-venv/bin/west update -o=--depth=1 -n
.toolchain-venv/bin/west zephyr-export
.toolchain-venv/bin/pip -q install -r zephyr/scripts/requirements-base.txt

echo "== zephyr sdk install (arm toolchain) =="
.toolchain-venv/bin/west sdk install -t arm-zephyr-eabi 2>&1 | tail -2

echo "== build =="
.toolchain-venv/bin/west build -p auto -b xiao_ble/nrf52840/sense app
echo "BUILD_OK: $(ls -la build/zephyr/zephyr.uf2 2>/dev/null || echo 'uf2 missing')"
