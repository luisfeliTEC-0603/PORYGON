"""Presenta los indicadores de una simulación en la terminal."""
import json
import sys


def print_summary(report):
    counters = report["contadores"]
    indicators = report["indicadores"]
    rows = [
        ("Ciclos totales", counters["cpu_cycles"], "d"),
        ("Instrucciones completadas", counters["cpu_instructions"], "d"),
        ("IPC", indicators["ipc"], ".3f"),
        ("Ciclos de espera por memoria", counters["cpu_stall_cycles"], "d"),
        ("Aciertos L1 · lecturas", indicators["l1_read_hit_rate"], ".2%"),
        ("Aciertos L1 · escrituras", indicators["l1_write_hit_rate"], ".2%"),
        ("Aciertos L2", indicators["l2_hit_rate"], ".2%"),
        ("AMAT observado (ciclos/acceso)", indicators["amat_observado"], ".2f"),
    ]
    cells = [(label, value if value == "N/A" else format(value, spec))
             for label, value, spec in rows]
    left = max(len(label) for label, _ in cells)
    right = max(len(value) for _, value in cells)
    width = left + right + 5
    title = "PORYGON · Resumen de rendimiento"
    print("┌" + "─" * width + "┐")
    print(f"│ {title:<{width - 2}} │")
    print("├" + "─" * (left + 2) + "┬" + "─" * (right + 2) + "┤")
    for label, value in cells:
        print(f"│ {label:<{left}} │ {value:>{right}} │")
    print("└" + "─" * (left + 2) + "┴" + "─" * (right + 2) + "┘")
    if not report["comparable"]:
        print("Medición no comparable: " + ", ".join(report["motivos"]))


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        print_summary(json.load(source))
