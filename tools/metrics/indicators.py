#!/usr/bin/env python3
# Calcula los indicadores derivados de metrics.md a partir de contadores crudos
import argparse
import json
import sys

NA = "N/A"

# Contadores que el reporte necesita; el resto se conserva sin interpretar
REQUIRED = (
    "cpu_cycles", "cpu_instructions", "cpu_bundles",
    "l1_read_hits", "l1_read_misses", "l1_write_hits", "l1_write_misses",
    "l2_hits", "l2_misses",
    "dmem_completed", "dmem_latency_sum",
    "mem_read_words", "mem_write_words", "mem_read_cycles", "mem_write_cycles",
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Calcula los indicadores derivados de una medicion")
    parser.add_argument("--input", required=True,
                        help="archivo clave=valor exportado por la simulacion")
    parser.add_argument("--output", help="archivo de salida (default: stdout)")
    parser.add_argument("--format", choices=("texto", "json"), default="texto")
    parser.add_argument("--allow-invalid", action="store_true",
                        help="reporta aunque la ejecucion sea fallida o con overflow")
    return parser.parse_args()


def read_counters(path):
    # Acepta comentarios con # y lineas en blanco; los valores son enteros
    counters = {}
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as error:
        sys.exit(f"error: no se pudo leer '{path}': {error}")
    for number, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            sys.exit(f"error: linea {number} sin 'clave=valor': {line}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        try:
            counters[key] = int(value, 0)
        except ValueError:
            sys.exit(f"error: linea {number}, valor no entero para '{key}': {value}")
    return counters


def ratio(numerator, denominator):
    # Un denominador cero se informa como N/A y conserva el contador crudo
    if denominator == 0:
        return NA
    return numerator / denominator


def rates(hits, misses, prefix):
    total = hits + misses
    return {
        f"{prefix}_hit_rate": ratio(hits, total),
        f"{prefix}_miss_rate": ratio(misses, total),
    }


def compute(counters):
    get = lambda name: counters.get(name, 0)
    cycles = get("cpu_cycles")
    words = get("mem_read_words") + get("mem_write_words")
    bytes_moved = 4 * words

    result = {
        "ipc": ratio(get("cpu_instructions"), cycles),
        "bundle_throughput": ratio(get("cpu_bundles"), cycles),
    }
    result.update(rates(get("l1_read_hits"), get("l1_read_misses"), "l1_read"))
    result.update(rates(get("l1_write_hits"), get("l1_write_misses"), "l1_write"))
    result.update(rates(get("l2_hits"), get("l2_misses"), "l2"))
    result["amat_observado"] = ratio(get("dmem_latency_sum"), get("dmem_completed"))

    for name, counter in (("wb", "wb_occupancy_sum"), ("eb", "eb_occupancy_sum"),
                          ("l2", "l2_inflight_sum")):
        result[f"ocupacion_media_{name}"] = ratio(get(counter), cycles)

    result["bytes_transferidos"] = bytes_moved
    seconds = ratio(cycles, get("cpu_hz"))
    result["ancho_banda_bytes_s"] = NA if seconds in (NA, 0) else bytes_moved / seconds
    # Equivale a palabras * MEM_CLOCK_DIV / cpu_cycles
    result["utilizacion_ancho_banda"] = ratio(words * get("mem_clock_div"), cycles)
    result["fraccion_tiempo_transferencia"] = ratio(
        get("mem_read_cycles") + get("mem_write_cycles"), cycles)
    return result


def reference_amat(counters, indicators):
    # AMAT de referencia sin forwarding ni contencion
    miss_l1 = indicators["l1_read_miss_rate"]
    miss_l2 = indicators["l2_miss_rate"]
    if miss_l1 == NA or miss_l2 == NA:
        return NA
    read_first = counters.get("mem_read_first_word_cycles", 0)
    t_read = read_first + 7 * counters.get("mem_clock_div", 0)
    return 1 + miss_l1 * (8 + miss_l2 * t_read)


def comparable(counters):
    # Una ejecucion fallida o con overflow no entra en comparaciones
    reasons = []
    if counters.get("failed", 0):
        reasons.append("la ejecucion termino con error")
    if counters.get("overflow", 0):
        reasons.append("algun contador se saturo")
    missing = [name for name in REQUIRED if name not in counters]
    if missing:
        reasons.append("faltan contadores: " + ", ".join(missing))
    return reasons


def render(value):
    if value == NA:
        return NA
    if isinstance(value, int):
        return str(value)
    return f"{value:.6g}"


def main():
    args = parse_args()
    counters = read_counters(args.input)
    reasons = comparable(counters)
    indicators = compute(counters)
    indicators["amat_referencia"] = reference_amat(counters, indicators)

    report = {
        "entrada": args.input,
        "comparable": not reasons,
        "motivos": reasons,
        "indicadores": {k: (NA if v == NA else v) for k, v in indicators.items()},
        "contadores": counters,
    }

    if args.format == "json":
        text = json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True)
    else:
        lines = [f"medicion       : {args.input}",
                 f"comparable     : {'si' if not reasons else 'NO'}"]
        lines += [f"  motivo       : {reason}" for reason in reasons]
        lines.append("")
        width = max(len(name) for name in indicators)
        for name, value in indicators.items():
            lines.append(f"{name.ljust(width)} : {render(value)}")
        text = "\n".join(lines)

    if args.output:
        open(args.output, "w", encoding="utf-8").write(text + "\n")
    else:
        print(text)
    return 0 if not reasons or args.allow_invalid else 1


if __name__ == "__main__":
    sys.exit(main())
