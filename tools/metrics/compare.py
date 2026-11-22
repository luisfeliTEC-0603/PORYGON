#!/usr/bin/env python3
# Compara varias mediciones a partir de los reportes de indicators.py
import argparse
import json
import sys
from pathlib import Path

NA = "N/A"

FILAS = (
    ("cpu_cycles", "ciclos", "contador"),
    ("cpu_instructions", "instrucciones", "contador"),
    ("cpu_stall_cycles", "ciclos de stall", "contador"),
    ("ipc", "IPC", "indicador"),
    ("l1_read_hit_rate", "hit rate L1 lectura", "indicador"),
    ("l2_hit_rate", "hit rate L2", "indicador"),
    ("amat_observado", "AMAT observado", "indicador"),
    ("amat_referencia", "AMAT de referencia", "indicador"),
    ("l1_read_misses", "fallas L1", "contador"),
    ("l2_demands", "demandas L2", "contador"),
    ("mem_reads", "lecturas a memoria", "contador"),
    ("mem_read_words", "palabras leidas", "contador"),
    ("bytes_transferidos", "bytes transferidos", "indicador"),
    ("utilizacion_ancho_banda", "utilizacion de BW", "indicador"),
    ("fraccion_tiempo_transferencia", "tiempo en transferencia", "indicador"),
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compara mediciones ya reducidas a indicadores")
    parser.add_argument("runs", nargs="+", metavar="NOMBRE=RUTA",
                        help="reporte JSON de indicators.py por medicion")
    parser.add_argument("--baseline", help="medicion usada como referencia del speedup")
    parser.add_argument("--format", choices=("texto", "markdown"), default="texto")
    parser.add_argument("--output", help="archivo de salida (default: stdout)")
    return parser.parse_args()


def load(spec):
    if "=" not in spec:
        sys.exit(f"error: se esperaba NOMBRE=RUTA y se recibio '{spec}'")
    name, path = spec.split("=", 1)
    try:
        report = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as error:
        sys.exit(f"error: no se pudo leer '{path}': {error}")
    except json.JSONDecodeError as error:
        sys.exit(f"error: '{path}' no es JSON valido: {error}")
    return name.strip(), report


def value(report, key):
    if key in report["indicadores"]:
        return report["indicadores"][key]
    return report["contadores"].get(key, NA)


def render(raw):
    if raw == NA or raw is None:
        return NA
    if isinstance(raw, int):
        return f"{raw}"
    if abs(raw) >= 10000:
        return f"{raw:.4g}"
    return f"{raw:.4f}".rstrip("0").rstrip(".")


def main():
    args = parse_args()
    runs = [load(spec) for spec in args.runs]
    names = [name for name, _ in runs]
    if len(set(names)) != len(names):
        sys.exit("error: los nombres de las mediciones deben ser distintos")

    # Una medicion fallida o con overflow no entra en el speedup
    descartadas = [name for name, report in runs if not report["comparable"]]

    baseline = args.baseline
    if baseline and baseline not in names:
        sys.exit(f"error: la medicion base '{baseline}' no esta entre las dadas")
    if baseline and baseline in descartadas:
        sys.exit(f"error: la medicion base '{baseline}' no es comparable")

    filas = []
    for key, etiqueta, _ in FILAS:
        celdas = [render(value(report, key)) for _, report in runs]
        if any(c != NA for c in celdas):
            filas.append((etiqueta, celdas))

    if baseline:
        base_cycles = value(dict(runs)[baseline], "cpu_cycles")
        celdas = []
        for name, report in runs:
            cycles = value(report, "cpu_cycles")
            if name in descartadas or cycles in (NA, 0) or base_cycles in (NA, 0):
                celdas.append(NA)
            else:
                celdas.append(f"{base_cycles / cycles:.3f}x")
        filas.append((f"speedup vs {baseline}", celdas))

    ancho = max(len(e) for e, _ in filas)
    columnas = [max(len(n), 12) for n in names]

    lineas = []
    if args.format == "markdown":
        lineas.append("| " + " | ".join(["metrica"] + names) + " |")
        lineas.append("|" + "|".join(["---"] * (len(names) + 1)) + "|")
        for etiqueta, celdas in filas:
            lineas.append("| " + " | ".join([etiqueta] + celdas) + " |")
    else:
        lineas.append(" " * ancho + "  " + "  ".join(
            n.rjust(w) for n, w in zip(names, columnas)))
        for etiqueta, celdas in filas:
            lineas.append(etiqueta.ljust(ancho) + "  " + "  ".join(
                c.rjust(w) for c, w in zip(celdas, columnas)))
    if descartadas:
        lineas.append("")
        for name in descartadas:
            motivos = "; ".join(dict(runs)[name]["motivos"])
            lineas.append(f"no comparable: {name} ({motivos})")

    text = "\n".join(lineas)
    if args.output:
        Path(args.output).write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 1 if descartadas else 0


if __name__ == "__main__":
    sys.exit(main())
