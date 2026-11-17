#!/usr/bin/env python3
# Genera el programa y las imagenes de datos de los benchmarks de patron de acceso
import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools" / "memory"))
import memimage

DATA_BASE = 0x10000
NODE_BYTES = 4
LINE_BYTES = 32
WORDS_PER_LINE = LINE_BYTES // NODE_BYTES
NODES = 4096                      # 16 KiB, el tamano de L2
ACCESSES = NODES                  # un recorrido completo por patron
SEED = 20261116                   # semilla fija del patron aleatorio

MATH_MOV, MATH_SUM, MATH_SHL = 1, 2, 8
LOST_LOW = 0
JUMP_JNZ = 2


def enc_math(rs1, rs2, funct, pipe=0, imm=0):
    return (rs1 << 13) | (rs2 << 10) | (funct << 4) | (pipe << 3) | (imm << 2) | 0


def enc_lost(rd, rs, funct, off=0, imm=0):
    return (rd << 13) | (rs << 10) | (funct << 6) | ((off & 0x7) << 3) | (imm << 2) | 1


def enc_jump(rd, off, funct=0, imm=0):
    return (rd << 13) | ((off & 0xFF) << 5) | (funct << 3) | (imm << 2) | 2


def bundle(s0=0, s1=0):
    return f"{(s1 << 16) | s0:016x}"


NOP = bundle()


def program():
    # r7 base del arreglo, r1 acumulador, r3 puntero, r4 accesos restantes
    b = []
    b.append(bundle(enc_math(7, 0, MATH_MOV, imm=1), 0x4000))
    b += [NOP, NOP]
    b.append(bundle(enc_math(7, 0, MATH_SHL, pipe=1, imm=1), 2))   # r7 = 0x10000
    b += [NOP, NOP]
    b.append(bundle(enc_math(1, 0, MATH_MOV, imm=1), 0))
    b += [NOP, NOP]
    b.append(bundle(enc_math(3, 7, MATH_MOV)))
    b += [NOP, NOP]
    b.append(bundle(enc_math(4, 0, MATH_MOV, imm=1), ACCESSES))
    b += [NOP, NOP]

    start = len(b)
    b.append(bundle(enc_lost(3, 3, LOST_LOW)))          # r3 = mem[r3]
    b += [NOP, NOP]
    b.append(bundle(enc_math(1, 3, MATH_SUM)))          # r1 += r3
    b += [NOP, NOP]
    b.append(bundle(enc_math(4, 0, MATH_SUM, imm=1), 0xFFFF))  # r4 -= 1
    b += [NOP, NOP]
    jump_at = len(b)
    b.append(bundle(enc_jump(4, start - jump_at, funct=JUMP_JNZ)))
    b += [NOP, NOP]                                     # delay slots
    b.append(bundle(enc_jump(0, 0)))                    # halt
    return b, start, jump_at - start + 3


def order_secuencial():
    # Palabras consecutivas: ocho nodos por linea, maxima localidad espacial
    return list(range(NODES))


def order_stride():
    # Un nodo por linea: recorre las 512 lineas y repite con el desplazamiento siguiente
    return [line * WORDS_PER_LINE + word
            for word in range(WORDS_PER_LINE)
            for line in range(NODES // WORDS_PER_LINE)]


def order_aleatorio():
    # Permutacion con semilla fija, reproducible entre corridas
    nodes = list(range(NODES))
    random.Random(SEED).shuffle(nodes)
    return nodes


PATTERNS = {
    "secuencial": order_secuencial,
    "stride": order_stride,
    "aleatorio": order_aleatorio,
}


def data_image(order):
    # Cada nodo guarda la direccion absoluta de su sucesor en el recorrido
    successor = [0] * NODES
    for position, node in enumerate(order):
        successor[node] = DATA_BASE + NODE_BYTES * order[(position + 1) % NODES]
    raw = b"".join(value.to_bytes(NODE_BYTES, "little") for value in successor)
    words = memimage.pack(raw, 8, "little")
    return memimage.render(words, 8, 0)


def expected_sum(order):
    # El programa acumula la direccion de cada sucesor visitado
    total = sum(DATA_BASE + NODE_BYTES * order[(k + 1) % NODES]
                for k in range(ACCESSES))
    return total & 0xFFFFFFFF


def main():
    parser = argparse.ArgumentParser(
        description="Genera los benchmarks de patron de acceso")
    parser.add_argument("--output", default=str(Path(__file__).resolve().parent),
                        help="directorio de salida")
    args = parser.parse_args()
    out = Path(args.output)

    bundles, loop_start, loop_len = program()
    (out / "patron.mem").write_text("\n".join(bundles) + "\n")

    resultados = {}
    for name, builder in PATTERNS.items():
        order = builder()
        assert sorted(order) == list(range(NODES)), f"{name} no es una permutacion"
        (out / f"{name}_datos.mem").write_text(data_image(order))
        resultados[name] = expected_sum(order)

    print(f"programa        : patron.mem, {len(bundles)} bundles")
    print(f"bucle           : {loop_len} bundles por acceso, inicia en {loop_start}")
    print(f"arreglo         : {NODES} nodos de {NODE_BYTES} B = {NODES * NODE_BYTES} B")
    print(f"accesos         : {ACCESSES}")
    print(f"semilla         : {SEED}")
    for name, value in resultados.items():
        print(f"r1 esperado ({name:10s}): {value} (0x{value:08X})")
    if len(set(resultados.values())) != 1:
        sys.exit("error: los patrones deberian recorrer el mismo conjunto")
    return 0


if __name__ == "__main__":
    sys.exit(main())
