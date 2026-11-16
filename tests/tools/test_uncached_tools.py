#!/usr/bin/env python3
"""Comprueba la referencia real, exportacion, recuperacion y cierres fallidos."""
import json
import os
from pathlib import Path
import signal
import subprocess


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "p2-12-tools"
BUILD.mkdir(parents=True, exist_ok=True)


def run(command, log_name, expected=0, marker=None):
    """Limita tiempo real y conserva diagnosticos, incluidos fatales esperados."""
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output = process.communicate(timeout=30)[0]
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output = process.communicate()[0]
        (BUILD / log_name).write_text(output)
        raise AssertionError(f"timeout real de {command}") from None
    (BUILD / log_name).write_text(output)
    assert process.returncode == expected, output[-5000:]
    if marker:
        assert marker in output, output[-5000:]


def counters(path):
    return {key: int(value, 0) for key, value in
            (line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)}


for mode in (1, 2):
    run(["vvp", f"build/uncached_timeout_{mode}.vvp"], f"timeout-{mode}.log",
        expected=1, marker=f"UNCACHED_TIMEOUT_OK mode={mode}")
print("PASS P2-12: timeout de lectura y escritura con el controlador real")

program = "tests/programs/feistel4/kit_texto_corto.mem"
data = "tests/programs/feistel4/kit_texto_corto_datos.mem"
runs = {}
for name, extra in (("cache", []), ("reference", ["--no-cache"])):
    output_dir = BUILD / name
    run(["bash", "tools/sim.sh", program, "--data", data, "--out", str(output_dir),
         "--expect", "errors=0", "--expect", "halted=1", *extra], f"{name}.log")
    raw = counters(output_dir / "metrics.txt")
    result = counters(output_dir / "results.txt")
    indicators = json.loads((output_dir / "indicators.json").read_text())
    assert indicators["comparable"] and not raw["failed"] and not raw["overflow"]
    assert raw["reference_without_cache"] == int(name == "reference")
    assert raw["cpu_cycles"] == result["cycles"]
    for address, size, filename, expected_path in (
        ("0x14000", 21, "recovered.bin", "tests/programs/feistel4/inputs/texto_corto.txt"),
        ("0x12000", 24, "encrypted.bin", "tests/programs/feistel4/expected/texto_corto.txt.enc"),
    ):
        extracted = output_dir / filename
        run(["python3", "tools/memory/extract_data.py", "--memory", str(output_dir / "memory.dump.mem"),
             "--address", address, "--size", str(size), "--output", str(extracted)], f"{name}-{filename}.log")
        assert extracted.read_bytes() == (ROOT / expected_path).read_bytes()
    if name == "reference":
        assert raw["mem_reads"] == raw["dmem_completed"]
        assert raw["mem_writes"] == raw["dmem_writes_completed"]
        assert raw["mem_read_words"] == 8 * raw["mem_reads"]
        assert raw["mem_write_words"] == 8 * raw["mem_writes"]
        assert all(value == 0 for key, value in raw.items()
                   if key.startswith(("l1_", "l2_", "wb_", "eb_", "pending_")))
        assert all(indicators["indicadores"][key] == "N/A" for key in (
            "l1_read_hit_rate", "l1_read_miss_rate", "l1_write_hit_rate", "l1_write_miss_rate",
            "l2_hit_rate", "l2_miss_rate", "ocupacion_media_wb", "ocupacion_media_eb", "ocupacion_media_l2"))
    runs[name] = (raw, result, output_dir)

for register in range(8):
    assert runs["cache"][1][f"r{register}"] == runs["reference"][1][f"r{register}"]
assert (runs["cache"][2] / "memory.dump.mem").read_bytes() == (runs["reference"][2] / "memory.dump.mem").read_bytes()
assert runs["cache"][0]["mem_reads"] < runs["reference"][0]["mem_reads"]
print("PASS P2-12: Feistel identico en RF/RAM/cifrado/descifrado, trafico y N/A exportados")

watchdog = BUILD / "watchdog"
run(["bash", "tools/sim.sh", program, "--data", data, "--no-cache", "--out", str(watchdog),
     "--max-cycles", "10"], "watchdog.log", expected=1, marker="TIMEOUT")
assert counters(watchdog / "metrics.txt")["failed"] == 1
assert counters(watchdog / "results.txt")["halted"] == 0
assert not json.loads((watchdog / "indicators.json").read_text())["comparable"]
print("PASS P2-12: watchdog conserva medicion fallida y no reporta HALT")
