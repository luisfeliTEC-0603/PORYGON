#!/usr/bin/env python3
"""Balances de eventos reales y timeout de la jerarquia integrada, P2-13."""
import os
from pathlib import Path
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def read_metrics(name):
    path = ROOT / "build" / "p2-12-tools" / name / "metrics.txt"
    return {key: int(value, 0) for key, value in
            (line.split("=", 1) for line in path.read_text().splitlines())}


for name in ("cache", "reference"):
    m = read_metrics(name)
    assert m["failed"] == m["overflow"] == m["dmem_failed"] == 0, name
    assert m["dmem_completed"] == m["dmem_reads_completed"] + m["dmem_writes_completed"], name
    assert m["cpu_stall_cycles"] == m["cpu_wait_accept"] + m["cpu_wait_miss"] + m["cpu_wait_rsp"], name
    assert m["dmem_latency_sum"] == m["dmem_completed"] + m["cpu_stall_cycles"], name
    assert m["dmem_latency_sum"] == m["dmem_read_latency_sum"] + m["dmem_write_latency_sum"], name
    assert m["mem_read_words"] == 8 * m["mem_reads_complete"], name
    assert m["mem_write_words"] == 8 * m["mem_writes_complete"], name
    assert all(value == 0 for key, value in m.items() if key.startswith("pending_")), name
    if name == "cache":
        for access in ("read", "write"):
            assert m[f"l1_{access}_hits"] + m[f"l1_{access}_misses"] == m[f"l1_{access}s"], access
        assert m["l1_reads"] + m["l1_writes"] == m["dmem_completed"]
        assert m["l1_read_misses"] + m["l1_write_misses"] == m["wb_forwarded"] + m["l2_demands"]
        assert m["l2_demands"] == m["l2_hits"] + m["l2_misses"]
        assert m["l2_hits"] == m["l2_promotions"]
        assert m["l2_misses"] == m["mem_reads"]
        assert m["wb_enqueued"] == m["wb_forwarded"] + m["wb_installed"]
        assert m["wb_sent"] == m["wb_installed"]
        assert m["eb_enqueued"] == m["eb_written"] == m["mem_writes"]
    print(f"PASS P2-13 {name}: balances de accesos, finalizaciones, latencias, stalls y pendientes")

log_path = ROOT / "build" / "p2-13-cached-timeout.log"
process = subprocess.Popen(["vvp", "build/cached_timeout.vvp"], cwd=ROOT, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, start_new_session=True)
try:
    output = process.communicate(timeout=15)[0]
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    output = process.communicate()[0]
    log_path.write_text(output)
    raise AssertionError("La jerarquia no produjo su timeout") from None
log_path.write_text(output)
assert process.returncode == 1 and "CACHED_TIMEOUT_OK" in output, output
print("PASS P2-13: timeout del controlador real durante un miss L1/L2")
