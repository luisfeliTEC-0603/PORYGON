#!/usr/bin/env python3
"""
Genera y valida el programa completo de Cifrado y Descifrado Feistel4 para PORYGON.
"""
import sys
from pathlib import Path

def rol32(x, r): return ((x << r) | (x >> (32 - r))) & 0xffffffff
def F(x, k):
    t = (rol32(x, 5) + k) & 0xffffffff
    return t ^ rol32(x, 13)

# 1. Encoders para cada formato ISA
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
    # bundle = slot3 (63:48), slot2 (47:32), slot1 (31:16), slot0 (15:0)
    val = (s3 << 48) | (s2 << 32) | (s1 << 16) | s0
    return f"{val:016x}"

NOP_BUNDLE = make_bundle(0, 0, 0, 0)

def main():
    # Parametros de prueba
    L0 = 0x01234567
    R0 = 0x89abcdef
    subkeys = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
    password = [0xdff0f76a, 0xa9a67018, 0xda48db07, 0x146317bb]

    # Modelo de referencia
    # Cifrado
    L, R = L0, R0
    for k in subkeys:
        L, R = R, L ^ F(R, k)
    cipher_L, cipher_R = L, R

    # Descifrado: input (R, L), llaves en orden inverso
    A, B = cipher_R, cipher_L
    for k in reversed(subkeys):
        A, B = B, A ^ F(B, k)
    recov_L, recov_R = B, A

    assert (recov_L, recov_R) == (L0, R0), "Modelo de referencia falló"
    print(f"[Modelo Ref] Plaintext : L=0x{L0:08x}, R=0x{R0:08x}")
    print(f"[Modelo Ref] Ciphertext: L=0x{cipher_L:08x}, R=0x{cipher_R:08x}")
    print(f"[Modelo Ref] RecovText : L=0x{recov_L:08x}, R=0x{recov_R:08x}")

    # 2. Generar crypto_data.mem
    # Estructura en RAM (segmento 0x00010000):
    # 0x00..0x07: Plaintext (L0, R0)
    # 0x10..0x1f: Subkeys 0..3 (4 words)
    # 0x20..0x2f: Credentials 0..3 (4 words)
    # 0x30..0x37: Espacio para guardar Ciphertext
    # 0x40..0x47: Espacio para guardar Recovered Plaintext
    data_words = {}
    # L0, R0 en little endian
    def put_word(addr, val):
        for b in range(4):
            data_words[addr + b] = (val >> (8 * b)) & 0xff

    put_word(0x00, L0)
    put_word(0x04, R0)
    for i, k in enumerate(subkeys):
        put_word(0x10 + 4 * i, k)
    for i, pw in enumerate(password):
        put_word(0x20 + 4 * i, pw)

    max_addr = 0x50
    lines_data = []
    for a in range(max_addr):
        val = data_words.get(a, 0x00)
        lines_data.append(f"{val:02x}")

    Path("hardware/tb/programs/crypto_data.mem").write_text("\n".join(lines_data) + "\n")
    print("hardware/tb/programs/crypto_data.mem generado.")

    # 3. Generar crypto_program.mem
    # r1: base RAM = 0x00010000
    # r2, r3, r4: registros de trabajo
    bundles = []
    
    # Bundle 0: Configurar r1 = 0x4000
    # sumi r1, r0, #0x4000 (MATH_SUM=2, imm=1)
    s0 = enc_math(rs1=1, rs2=0, funct=2, pipe=0, imm=1)
    s1 = 0x4000
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Bundle 3: shli r1, r0, #2 -> r1 = 0x00010000
    # MATH_SHL=8, pipe=1, imm=1
    s0 = enc_math(rs1=1, rs2=0, funct=8, pipe=1, imm=1)
    s1 = 0x0002
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Autenticación: cargar credenciales 0..3 y ejecutar LOPW
    for word_idx in range(4):
        # lowi r2, (0x20 + 4*word_idx)(r1) (LOST_LOW=0, imm=1)
        s0 = enc_lost(rd=2, rs=1, funct=0, imm=1)
        s1 = 0x0020 + 4 * word_idx
        bundles.append(make_bundle(s0=s0, s1=s1))
        bundles.append(NOP_BUNDLE)
        bundles.append(NOP_BUNDLE)
        # LOPW r2, word_idx
        # CRYPTO_LOPW=5
        s0 = enc_crypto(rs1=2, rs2=0, funct=5, shared_idx=word_idx, key_idx=0)
        bundles.append(make_bundle(s0=s0))
        bundles.append(NOP_BUNDLE)

    # Ejecutar auth (CRYPTO_AUTH=0)
    s0 = enc_crypto(rs1=0, rs2=0, funct=0, shared_idx=0, key_idx=0)
    bundles.append(make_bundle(s0=s0))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Programar subllaves 0..3 para Llave 0
    for sk_idx in range(4):
        # lowi r2, (0x10 + 4*sk_idx)(r1)
        s0 = enc_lost(rd=2, rs=1, funct=0, imm=1)
        s1 = 0x0010 + 4 * sk_idx
        bundles.append(make_bundle(s0=s0, s1=s1))
        bundles.append(NOP_BUNDLE)
        bundles.append(NOP_BUNDLE)
        # write r2, sk_idx, key=0 (CRYPTO_WRITE=1)
        s0 = enc_crypto(rs1=2, rs2=0, funct=1, shared_idx=sk_idx, key_idx=0)
        bundles.append(make_bundle(s0=s0))
        bundles.append(NOP_BUNDLE)

    # Cargar Plaintext L0 en r2, R0 en r3
    s0 = enc_lost(rd=2, rs=1, funct=0, off=0, imm=0) # low r2, 0(r1)
    bundles.append(make_bundle(s0=s0))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    s0 = enc_lost(rd=3, rs=1, funct=0, imm=1) # lowi r3, 4(r1)
    s1 = 0x0004
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # 4 Rondas de Cifrado
    for rnd in range(4):
        # feistel r2, r3, rnd, k=0 (CRYPTO_FEISTEL=2)
        s0 = enc_crypto(rs1=2, rs2=3, funct=2, shared_idx=rnd, key_idx=0)
        bundles.append(make_bundle(s0=s0))
        bundles.append(NOP_BUNDLE)
        bundles.append(NOP_BUNDLE)

    # Guardar Ciphertext en 0x30 y 0x34
    # stwi r2, 0x30(r1) (LOST_STW=5, imm=1)
    s0 = enc_lost(rd=2, rs=1, funct=5, imm=1)
    s1 = 0x0030
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)

    # stwi r3, 0x34(r1)
    s0 = enc_lost(rd=3, rs=1, funct=5, imm=1)
    s1 = 0x0034
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # 4 Rondas de Descifrado:
    # Pasamos r3 como L (operando A) y r2 como R (operando B)
    # y subllaves en orden 3, 2, 1, 0
    for rnd in [3, 2, 1, 0]:
        s0 = enc_crypto(rs1=3, rs2=2, funct=2, shared_idx=rnd, key_idx=0)
        bundles.append(make_bundle(s0=s0))
        bundles.append(NOP_BUNDLE)
        bundles.append(NOP_BUNDLE)

    # Tras las 4 rondas, el resultado descifrado está:
    # r3 contiene R0
    # r2 contiene L0
    # Guardamos en 0x40 (L0) y 0x44 (R0)
    # stwi r2, 0x40(r1)
    s0 = enc_lost(rd=2, rs=1, funct=5, imm=1)
    s1 = 0x0040
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)

    # stwi r3, 0x44(r1)
    s0 = enc_lost(rd=3, rs=1, funct=5, imm=1)
    s1 = 0x0044
    bundles.append(make_bundle(s0=s0, s1=s1))
    bundles.append(NOP_BUNDLE)
    bundles.append(NOP_BUNDLE)

    # Padding final de NOPs
    for _ in range(5):
        bundles.append(NOP_BUNDLE)

    Path("hardware/tb/programs/crypto_integration.mem").write_text("\n".join(bundles) + "\n")
    print(f"hardware/tb/programs/crypto_integration.mem generado con {len(bundles)} bundles.")

if __name__ == "__main__":
    main()
