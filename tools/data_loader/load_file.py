#!/usr/bin/env python3
# Carga un archivo de cualquier formato en una imagen de memoria .mem para $readmemh

import argparse
import sys
from pathlib import Path

import memimage

TEXT_SEGMENT = (0x00000000, 0x0000FFFF)
DATA_SEGMENT = (0x00010000, 0x0001FFFF)
STACK_SEGMENT = (0x0001F000, 0x0001FFFF)


def parse_args():
    parser = argparse.ArgumentParser(description="Inyecta un archivo en una imagen de memoria .mem")
    parser.add_argument("--input", required=True, help="archivo de entrada (texto, imagen, binario)")
    parser.add_argument("--output", required=True, help="imagen .mem de salida")
    parser.add_argument("--address", default="0x0", help="direccion de carga (default 0x0)")
    parser.add_argument("--width", type=int, default=8, choices=memimage.WIDTHS,
                        help="bits por palabra del .mem (default 8)")
    parser.add_argument("--endian", default="little", choices=("little", "big"),
                        help="orden de bytes dentro de la palabra (default little)")
    parser.add_argument("--mem-base", default="0x0",
                        help="direccion que corresponde a la posicion 0 del arreglo (default 0x0)")
    parser.add_argument("--block", type=int, default=8,
                        help="rellena con ceros hasta multiplo de N bytes (default 8)")
    parser.add_argument("--no-pad", action="store_true", help="no rellenar el ultimo bloque")
    parser.add_argument("--append", action="store_true",
                        help="agrega el bloque a un .mem existente en lugar de sobrescribirlo")
    return parser.parse_args()


def overlaps(start, end, segment):
    return start <= segment[1] and end >= segment[0]


def check_segments(start, end):
    # El mapa de isa.md solapa datos y pila, por eso estos casos avisan en lugar de abortar
    warnings = []
    if overlaps(start, end, TEXT_SEGMENT):
        warnings.append("el rango invade el segmento de instrucciones (0x00000000-0x0000FFFF)")
    if overlaps(start, end, STACK_SEGMENT):
        warnings.append("el rango invade el segmento de pila (0x0001F000-0x0001FFFF)")
    if end > DATA_SEGMENT[1]:
        warnings.append(f"el rango excede el mapa de memoria (ultima direccion 0x{DATA_SEGMENT[1]:08X})")
    return warnings


def main():
    args = parse_args()
    address = int(args.address, 0)
    mem_base = int(args.mem_base, 0)
    word = memimage.bytes_per_word(args.width)

    source = Path(args.input)
    if not source.is_file():
        sys.exit(f"error: no existe el archivo de entrada '{source}'")

    data = source.read_bytes()
    original = len(data)
    if original == 0:
        sys.exit("error: el archivo de entrada esta vacio")

    padding = 0
    if not args.no_pad and args.block > 1 and original % args.block:
        padding = args.block - original % args.block
    # Una palabra parcial no se puede emitir, se completa aunque se haya pedido --no-pad
    if (original + padding) % word:
        padding += word - (original + padding) % word
    data += bytes(padding)

    offset = address - mem_base
    if offset < 0:
        sys.exit(f"error: la direccion 0x{address:08X} es anterior a la base del arreglo 0x{mem_base:08X}")
    if offset % word:
        sys.exit(f"error: la direccion 0x{address:08X} no esta alineada a {word} bytes")

    words = memimage.pack(data, args.width, args.endian)
    block = memimage.render(words, args.width, offset // word)
    target = Path(args.output)

    collisions = 0
    if args.append and target.is_file():
        # $readmemh procesa las directivas @ en orden, asi que basta con concatenar el bloque nuevo
        previous = target.read_text()
        occupied = memimage.parse(previous, args.width)
        collisions = sum(1 for i in range(len(words)) if offset // word + i in occupied)
        target.write_text(previous + block)
    else:
        target.write_text(block)

    last = address + len(data) - 1
    print(f"archivo         : {source}")
    print(f"tamano original : {original} bytes")
    if padding:
        print(f"relleno         : {padding} bytes de ceros")
    print(f"bytes escritos  : {len(data)}")
    print(f"direcciones     : 0x{address:08X} - 0x{last:08X}")
    print(f"palabras .mem   : {len(words)} de {args.width} bits")
    print(f"bloques de 64 b : {len(data) // 8}")
    print(f"salida          : {args.output}")
    print(f"para extraer    : --address 0x{address:08X} --size {original}")

    if collisions:
        print(f"aviso: {collisions} posiciones ya estaban ocupadas en '{args.output}' y quedan sobrescritas",
              file=sys.stderr)
    for warning in check_segments(address, last):
        print(f"aviso: {warning}", file=sys.stderr)


if __name__ == "__main__":
    main()
