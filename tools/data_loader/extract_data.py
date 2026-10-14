#!/usr/bin/env python3
# Extrae un rango de memoria de un volcado de simulacion y lo guarda como archivo binario

import argparse
import sys
from pathlib import Path

import memimage

DEFAULT_MEM_BASE = 0x10000
DEFAULT_MEM_BYTES = 65536


def auto_int(value):
    try:
        parsed = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"entero inválido: '{value}'") from error
    if parsed < 0:
        raise argparse.ArgumentTypeError("el valor no puede ser negativo")
    return parsed


def parse_args():
    parser = argparse.ArgumentParser(description="Extrae datos de un volcado de memoria a un archivo")
    parser.add_argument("--memory", required=True, help="volcado generado por $writememh")
    parser.add_argument("--address", required=True, type=auto_int,
                        help="direccion física inicial del rango a extraer")
    parser.add_argument("--size", required=True, type=int, help="cantidad de bytes a extraer")
    parser.add_argument("--output", required=True, help="archivo binario de salida")
    parser.add_argument("--width", type=int, default=8, choices=memimage.WIDTHS,
                        help="bits por palabra del volcado (default 8)")
    parser.add_argument("--endian", default="little", choices=("little", "big"),
                        help="orden de bytes dentro de la palabra (default little)")
    parser.add_argument("--mem-base", type=auto_int, default=DEFAULT_MEM_BASE,
                        help="direccion que corresponde a la posicion 0 del arreglo (default 0x10000)")
    parser.add_argument("--mem-bytes", type=int, default=DEFAULT_MEM_BYTES,
                        help=f"tamano del arreglo de memoria en bytes (default {DEFAULT_MEM_BYTES})")
    parser.add_argument("--allow-uninitialized", action="store_true",
                        help="rellena huecos ausentes con cero; nunca permite valores x/z")
    return parser.parse_args()


def main():
    args = parse_args()
    address = args.address
    mem_base = args.mem_base
    word = memimage.bytes_per_word(args.width)

    dump = Path(args.memory)
    if not dump.is_file():
        sys.exit(f"error: no existe el volcado '{dump}'")
    if args.size <= 0:
        sys.exit("error: --size debe ser mayor que cero")
    if args.mem_bytes <= 0:
        sys.exit("error: --mem-bytes debe ser mayor que cero")

    offset = address - mem_base
    if offset < 0:
        sys.exit(f"error: la direccion 0x{address:08X} es anterior a la base del arreglo 0x{mem_base:08X}")
    if offset % word:
        sys.exit(f"error: la direccion 0x{address:08X} no esta alineada a {word} bytes")
    limit = mem_base + args.mem_bytes
    end = address + args.size
    if end > limit:
        sys.exit(f"error: el rango 0x{address:08X}-0x{end - 1:08X} excede la RAM; "
                 f"la ultima direccion valida es 0x{limit - 1:08X}")

    try:
        cells = memimage.parse(dump.read_text(), args.width)
    except (OSError, UnicodeError, ValueError) as error:
        sys.exit(f"error: {error}")

    # Se leen palabras completas y el recorte final devuelve el tamano exacto pedido
    count = (args.size + word - 1) // word
    start = offset // word
    try:
        words = memimage.extract(cells, start, count, args.allow_uninitialized)
    except ValueError as error:
        sys.exit(f"error: {error}")
    data = memimage.unpack(words, args.width, args.endian)[:args.size]
    try:
        Path(args.output).write_bytes(data)
    except OSError as error:
        sys.exit(f"error: no se pudo escribir '{args.output}': {error}")

    missing = sum(1 for i in range(count) if start + i not in cells)
    print(f"volcado         : {dump}")
    print(f"direcciones     : 0x{address:08X} - 0x{address + args.size - 1:08X}")
    print(f"palabras leidas : {count} de {args.width} bits")
    print(f"bytes escritos  : {len(data)}")
    print(f"salida          : {args.output}")

    if missing and args.allow_uninitialized:
        print(f"aviso: {missing} de {count} palabras no estaban en el volcado, se rellenaron con cero",
              file=sys.stderr)


if __name__ == "__main__":
    main()
