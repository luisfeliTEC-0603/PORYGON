#!/usr/bin/env python3
"""
Genera y valida la prueba de EDGE CASES del procesador PORYGON:
- Concurrencia de los 5 canales de Writeback en un solo ciclo
- Inmunidad de r0 contra escrituras
- Bucle hacia atras con delay slots ejecutando operaciones utiles
- Violacion de seguridad: rechazo de feistel desautorizado con access_error
"""
from pathlib import Path

def enc_math(rs1, rs2, funct, pipe=0, imm=0):
    return (rs1 << 13) | (rs2 << 10) | (funct << 4) | (pipe << 3) | (imm << 2) | 0

def enc_lost(rd, rs, funct, off=0, imm=0):
    off_masked = off & 0x7
    return (rd << 13) | (rs << 10) | (funct << 6) | (off_masked << 3) | (imm << 2) | 1

def enc_jump(rd, off, funct=0, imm=0):
    off_masked = off & 0xff
    return (rd << 13) | (off_masked << 5) | (funct << 3) | (imm << 2) | 2

def enc_crypto(rs1, rs2, funct, shared_idx=0, key_idx=0):
    return (rs1 << 13) | (rs2 << 10) | (funct << 7) | (shared_idx << 5) | (key_idx << 3) | 3

def make_bundle(s0=0, s1=0, s2=0, s3=0):
    val = (s3 << 48) | (s2 << 32) | (s1 << 16) | s0
    return f"{val:016x}"

NOP_BUNDLE = make_bundle(0, 0, 0, 0)

def main():
    bundles = []

    # 1. Preparar base RAM r1 = 0x00010000
    # sumi r1, r0, #0x4000
    bundles.append(make_bundle(s0=enc_math(1, 0, 2, pipe=0, imm=1), s1=0x4000))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # shli r1, r0, #2 -> r1 = 0x00010000
    bundles.append(make_bundle(s0=enc_math(1, 0, 8, pipe=1, imm=1), s1=0x0002))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # 2. Prueba de Seguridad A: Intentar FEISTEL sin autenticar -> DEBE fallar con access_error
    # feistel r2, r3, rnd=0, key=0
    bundles.append(make_bundle(s0=enc_crypto(2, 3, 2, 0, 0)))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # 3. Autenticar para pruebas posteriores
    # Cargar contraseña desde RAM
    # En data.mem en 0x20..0x2f estara la clave correcta
    for w in range(4):
        bundles.append(make_bundle(s0=enc_lost(2, 1, 0, imm=1), s1=0x0020 + 4*w))
        bundles.append(NOP_BUNDLE)
        bundles.append(NOP_BUNDLE)
        bundles.append(make_bundle(s0=enc_crypto(2, 0, 5, shared_idx=w, key_idx=0))) # LOPW
        bundles.append(NOP_BUNDLE)

    # auth
    bundles.append(make_bundle(s0=enc_crypto(0, 0, 0, 0, 0)))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Programar subkey 0 para key 0
    bundles.append(make_bundle(s0=enc_lost(2, 1, 0, imm=1), s1=0x0010))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)
    bundles.append(make_bundle(s0=enc_crypto(2, 0, 1, shared_idx=0, key_idx=0))) # write
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # 4. Prueba de Concurrencia de 5 Canales de Writeback en un solo bundle
    # Inicializar r4=0x11112222, r5=0x33334444 para feistel
    bundles.append(make_bundle(s0=enc_math(4, 0, 2, pipe=0, imm=1), s1=0x2222))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)
    bundles.append(make_bundle(s0=enc_math(5, 0, 2, pipe=0, imm=1), s1=0x4444))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Preparar r7 con un valor para ALU0 y ALU1
    bundles.append(make_bundle(s0=enc_math(7, 0, 2, pipe=0, imm=1), s1=0x00AA))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # BUNDLE CONCURRENTE SUPER-PARALELO:
    # Slot 0: ALU0      -> sum r1, r7, r7 (r1 = 0x00AA + 0x00AA = 0x0154) -> escribe r1
    # Slot 1: SuperALU  -> shl r2, r7, r0 (pipe=1, no-imm: r2 = r7 << r0 = 0x00AA) -> escribe r2
    # Slot 2: LSU (Load)-> low r3, 0(r1)  (lee RAM[0x00010000]) -> escribe r3
    # Slot 3: Crypto    -> feistel r4, r5 (ronda 0, key 0) -> escribe r4 y r5
    # TOTAL: 5 registros (r1, r2, r3, r4, r5) escritos en el MISMO ciclo WB!
    # Nota: para que low lea de r6 base, primero ponemos r6=0x00010000
    bundles.append(make_bundle(s0=enc_math(6, 1, 1, pipe=0, imm=0))) # mov r6, r1
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    s0 = enc_math(rs1=1, rs2=7, funct=2, pipe=0, imm=0) # sum r1, r7
    s1 = enc_math(rs1=2, rs2=7, funct=1, pipe=1, imm=0) # mov r2, r7 (pipe 1)
    s2 = enc_lost(rd=3, rs=6, funct=0, off=0, imm=0)    # low r3, 0(r6)
    s3 = enc_crypto(rs1=4, rs2=5, funct=2, shared_idx=0, key_idx=0) # feistel r4, r5
    bundles.append(make_bundle(s0=s0, s1=s1, s2=s2, s3=s3))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE) # En este flanco WB se escriben r1, r2, r3, r4, r5 simultaneamente!

    # 5. Prueba de Inmunidad de r0:
    # Intentar escribir en r0 desde ALU0
    bundles.append(make_bundle(s0=enc_math(0, 7, 2, pipe=0, imm=0))) # sum r0, r7
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # 6. Prueba de Bucle con Salto hacia Atras (Loop con delay slots):
    # Contador en r1 = 3
    # r7 = 0 (acumulador)
    bundles.append(make_bundle(s0=enc_math(1, 0, 2, pipe=0, imm=1), s1=0x0003))
    bundles.append(make_bundle(s0=enc_math(7, 0, 1, pipe=0, imm=0))) # mov r7, r0 (0)
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # LOOP_START (índice de bundle actual):
    loop_start_idx = len(bundles)
    # Bundle A: decrementar r1 = r1 - 1
    # diffi r1, r0, #1
    bundles.append(make_bundle(s0=enc_math(1, 0, 3, pipe=0, imm=1), s1=0x0001))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Bundle B: jnz r1, loop_start_idx
    # offset en bundles hacia atras: (loop_start_idx - pc_actual)
    # pc_actual es este bundle. El salto relativo es (target - current).
    # target = loop_start_idx, current = len(bundles)
    offset = loop_start_idx - len(bundles)
    bundles.append(make_bundle(s0=enc_jump(rd=1, off=offset, funct=2, imm=0))) # jnz r1
    # Delay slot 1: sumi r7, r0, #10 (r7 acumula 10 en cada iteracion!)
    bundles.append(make_bundle(s0=enc_math(7, 0, 2, pipe=0, imm=1), s1=0x000a))
    # Delay slot 2: NOP
    bundles.append(NOP_BUNDLE)

    # Fuera del bucle: cuando r1=0, el bucle termina
    for _ in range(6):
        bundles.append(NOP_BUNDLE)

    Path("hardware/tb/programs/edge_cases.mem").write_text("\n".join(bundles) + "\n")
    print(f"hardware/tb/programs/edge_cases.mem generado con {len(bundles)} bundles.")

if __name__ == "__main__":
    main()
