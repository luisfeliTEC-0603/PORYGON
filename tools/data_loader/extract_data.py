#!/usr/bin/env python3
# Extrae un rango de memoria de un volcado de simulacion y lo guarda como archivo binario

import argparse
import sys
from pathlib import Path

import memimage


def parse_args():
    parser = argparse.ArgumentParser(description="Extrae datos de un volcado de memoria a un archivo")
    parser.add_argument("--memory", required=True, help="volcado generado por $writememh")
    parser.add_argument("--address", required=True, help="direccion inicial del rango a extraer")
    parser.add_argument("--size", required=True, type=int, help="cantidad de bytes a extraer")
    parser.add_argument("--output", required=True, help="archivo binario de salida")
    parser.add_argument("--width", type=int, default=8, choices=memimage.WIDTHS,
                        help="bits por palabra del volcado (default 8)")
    parser.add_argument("--endian", default="little", choices=("little", "big"),
                        help="orden de bytes dentro de la palabra (default little)")
    parser.add_argument("--mem-base", default="0x0",
                        help="direccion que corresponde a la posicion 0 del arreglo (default 0x0)")
    return parser.parse_args()


def main():
    args = parse_args()
    address = int(args.address, 0)
    mem_base = int(args.mem_base, 0)
    word = memimage.bytes_per_word(args.width)

    dump = Path(args.memory)
    if not dump.is_file():
        sys.exit(f"error: no existe el volcado '{dump}'")
    if args.size <= 0:
        sys.exit("error: --size debe ser mayor que cero")

    offset = address - mem_base
    if offset < 0:
        sys.exit(f"error: la direccion 0x{address:08X} es anterior a la base del arreglo 0x{mem_base:08X}")
    if offset % word:
        sys.exit(f"error: la direccion 0x{address:08X} no esta alineada a {word} bytes")

    try:
        cells = memimage.parse(dump.read_text(), args.width)
    except ValueError as error:
        sys.exit(f"error: {error}")

    # Se leen palabras completas y el recorte final devuelve el tamano exacto pedido
    count = (args.size + word - 1) // word
    start = offset // word
    words = memimage.extract(cells, start, count)
    data = memimage.unpack(words, args.width, args.endian)[:args.size]
    Path(args.output).write_bytes(data)

    missing = sum(1 for i in range(count) if start + i not in cells)
    print(f"volcado         : {dump}")
    print(f"direcciones     : 0x{address:08X} - 0x{address + args.size - 1:08X}")
    print(f"palabras leidas : {count} de {args.width} bits")
    print(f"bytes escritos  : {len(data)}")
    print(f"salida          : {args.output}")

    if missing:
        print(f"aviso: {missing} de {count} palabras no estaban en el volcado, se rellenaron con cero",
              file=sys.stderr)


if __name__ == "__main__":
    main()
