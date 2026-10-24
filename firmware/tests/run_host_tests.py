#!/usr/bin/env python3
"""Compile actual driver event code, with fake hardware, before and after backport."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
original = root / "zephyr/drivers/audio/dmic_nrfx_pdm.c"
patch = root / "patches/zephyr-pdm-ownership.patch"

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="keepsake-host-tests-") as temp:
    temp = Path(temp)
    fixed = temp / "pdm_fixed.c"
    run("patch", "-s", "-o", str(fixed), str(original), str(patch))
    for source, expected in [(original, 42), (fixed, 0)]:
        text = source.read_text()
        # No reimplementation: compile the driver's own structs and event handler.
        excerpt = text[text.index("struct dmic_nrfx_pdm_drv_data {"):text.index("static bool is_in_freq_range")]
        (temp / "pdm_under_test.inc").write_text(excerpt)
        binary = temp / "pdm_test"
        flags = ["-DORIGINAL_DRIVER"] if expected == 42 else []
        run("clang", "-std=c11", "-Wall", "-Wextra", "-Werror", *flags,
            "-fsanitize=address,undefined", "-I", str(temp),
            str(root / "tests/pdm_ownership_test.c"), "-o", str(binary))
        result = subprocess.run([str(binary)])
        if result.returncode != expected:
            raise SystemExit(f"{source.name}: expected {expected}, got {result.returncode}")
    for name in ["protocol", "recovery"]:
        binary = temp / name
        run("clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
            str(root / f"tests/{name}_test.c"), "-o", str(binary))
        run(str(binary))
    main = (root / "app/src/main.c").read_text()
    def section(start, end):
        return main[main.index(start):main.index(end)]
    (temp / "transport_under_test.inc").write_text(
        section("enum transport_metric", "static void trace_main") +
        section("struct audio_block {", "static void feed_watchdog") +
        section("static void notify_complete", "static int mic_start"))
    run("clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-Wno-unused-variable", "-fsanitize=address,undefined", "-I", str(temp),
        str(root / "tests/transport_test.c"), "-o", str(temp / "transport"))
    run(str(temp / "transport"))
