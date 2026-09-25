# ISA – Procesador PORYGON

PORYGON es un procesador VLIW (_Very Long Instruction Word_) con ISA propia, que incluye una unidad de cifrado por bloques Feistel4. El compilador empaqueta instrucciones en bundles de 64 bits (4 slots de 16 bits) que se ejecutan en paralelo.

La ISA de PORYGON se organiza en cuatro formatos de instrucción que comparten un campo `opcode` de 2 bits:

| `opcode` | Formato | Unidad funcional principal |
|----------|---------|----------------------------|
| `00`     | MATH    | ALU (general y especializada) |
| `01`     | LOST    | LSU (load/store) |
| `10`     | JUMP    | BRU (control de flujo) |
| `11`     | CRYPTO  | Unidad criptográfica Feistel4 + Bóveda de llaves |

El direccionamiento de memoria es **registro-registro** (con offset), el ordenamiento de bits es **Little Endian**, y la arquitectura expone **8 registros de propósito general de 32 bits** y un **Program Counter (PC)**.

## Organización

### Mapa de memoria

### Características generales

| Característica | Valor |
|----------------|-------|
| Tamaño mínimo | 64 KB |
| Direccionamiento | 32 bits |
| Endianness | Little Endian |
| Unidad mínima direccionable | 1 byte (8 bits) |
| Palabra | 32 bits (4 bytes) |
| Media palabra | 16 bits (2 bytes) |
| Bundle | 64 bits (8 bytes) |

### Segmentos de memoria

| Segmento | Rango típico | Uso |
|----------|--------------|-----|
| Instrucciones (texto) | `0x00000000` – `0x0000FFFF` | Bundles de instrucciones |
| Datos | `0x00010000` – `0x0001FFFF` | Datos generales, archivos cargados |
| Pila | `0x0001F000` – `0x0001FFFF` | Pila del programa (crece hacia abajo) |
| Reservado | resto | Reservado para expansión |

### Unidades funcionales especializadas

| Unidad | Descripción |
|--------|-------------|
| **ALU general (pipe 0)** | Suma, resta, AND, OR, XOR, NOT, comparaciones |
| **ALU especializada (pipe 1)** | Multiplicaciones, desplazamientos lógicos y aritméticos |
| **LSU** | Load y store (byte, media palabra, palabra) |
| **BRUH** | Saltos condicionales e incondicionales |
| **Crypto (Feistel4)** | Ronda Feistel4, escritura de subllaves, autenticación, cambio de contraseña, revocación; incluye una boveda de almacenamiento seguro de 4 llaves de 128 bits (16 subllaves de 32 bits) |

> [!NOTE]
>
> PORYGON utiliza un esquema de asignación de slots, cualquier slot puede contener cualquier tipo de instrucción (MATH, LOST, JUMP o CRYPTO). La unidad de **DISPATCH** redirige con base en el `opcode` de cada slot, la instrucción a la unidad funcional correspondiente.

## Convenciones de registros

### Banco de registros de propósito general (GPR)

PORYGON expone **8 registros de propósito general de 32 bits**:

| Registro | Nombre | Uso | ¿Escribible? |
|----------|--------|-----|--------------|
| `r0`     | zero   | Siempre 0 | No |
| `r1`     | —      | Propósito general | Sí |
| `r2`     | —      | Propósito general | Sí |
| `r3`     | —      | Propósito general | Sí |
| `r4`     | —      | Propósito general | Sí |
| `r5`     | —      | Propósito general | Sí |
| `r6`     | —      | Propósito general | Sí |
| `r7`     | —      | Propósito general | Sí |

**Consideraciones:**
- `r0` está conectado a *ground*: su valor es siempre `0x0` y **no puede sobrescribirse**. Cualquier intento de escritura en `r0` se ignora silenciosamente (no genera excepción).
- Los registros `r1`–`r7` son de lectura/escritura y pueden almacenar cualquier valor de 32 bits.
- Representación sin signo: rango `0` a `4,294,967,295` (2³² − 1).
- Representación con signo (complemento a dos): rango `−2,147,483,648` a `2,147,483,647` (−2³¹ a 2³¹ − 1).

### Registros internos de la bóveda

La bóveda de llaves mantiene internamente los siguientes recursos:

| Recurso | Ancho | Tipo | Descripción |
|---------|-------|------|-------------|
| `keys[0..3]` | 4 × 128 bits | R/W (solo `write`) | 4 llaves de 128 bits, cada una dividida en 4 subllaves de 32 bits |
| `rsp` | 32 bits | R/W (solo `pwd`) | *Register for Stored Password*: almacena la contraseña de autenticación |
| `rsa` | 32 bits | WO (solo `auth`) | *Register for Stored Authentication*: almacena temporalmente el token recibido para compararlo con `rsp` |
| `state` | 2 bits | R/W (FSM) | Estado de la FSM de autenticación |

**Notas:**

- `rsa` es un registro **write-only** propio de la unidad criptográfica. El programa **no puede leerlo**; solo se escribe mediante la instrucción `auth`.
- `rsp` **no es legible** desde registros de propósito general. Solo se escribe mediante `pwd` (previa autenticación) y se compara internamente con `rsa`.
- Las llaves `keys[0..3]` **nunca** se escriben en registros de propósito general ni en memoria general. Solo `feistel` las lee (como subllaves) y `write` las escribe.
- El estado `state` controla el acceso a las operaciones privilegiadas.

> [!WARNING]
> 
> Los recursos de esta unidad son **inaccesibles** como registros de propósito general o memoria tradicional.

> [!TIP]
>
> **Comparación `rsa == rsp`**
>
> El mecanismo de autenticación opera de la siguiente manera:
> 1. El programa coloca un token en un registro de propósito general (por ejemplo, `rs1`).
> 2. Ejecuta `auth rs1`. La unidad criptográfica **escribe** el valor de `rs1` en `rsa`. 
> 3. La unidad criptográfica **compara** `rsa` con `rsp`.
> 4. Si `rsa == rsp`, la FSM transiciona a `AUTHENTICATED` y el bit `AUTH` del registro de estado se pone en 1.
> 5. Si `rsa != rsp`, la FSM permanece en `LOCKED` y se genera la excepción `AUTENTICACION_FALLIDA`.
> 6. Tras la comparación, `rsa` es limpiado para no dejar el token residual.

## Bundle

Un **bundle** es una palabra de instrucción VLIW de **64 bits** compuesta por **4 slots de 16 bits** cada uno.

```
  Bit 63                                     Bit 0
 ┌───────────┬───────────┬───────────┬───────────┐
 │  Slot 3   │  Slot 2   │  Slot 1   │  Slot 0   │
 │ [63:48]   │ [47:32]   │ [31:16]   │ [15:0]    │
 └───────────┴───────────┴───────────┴───────────┘
```

> [!NOTE]
> **Mecanismo de inmediato**
>
> El campo `imm` es un bit que indica si la instrucción consume el slot inmediatamente siguiente como inmediato de 16 bits. Por convención siempre va después del `opcode` (nunca en el bit 0).
>
> **- `imm = 1`**, el slot siguiente del bundle contiene el inmediato de 16 bits y no se decodifica como instrucción.
> 
> **- `imm = 0`**, el slot siguiente es una decodificado como una instrucción normal (o NOP).
>
> ```
> ┌───────────┬───────────┬───────────┬───────────────┐
> │  Slot 3   │  Slot 2   │  Slot 1   │  Slot 0       │
> │ instrucc. │ instrucc. │ INMEDIATO │ instr (imm=1) │
> └───────────┴───────────┴───────────┴───────────────┘
>                               ▲             │
>                               └─────────────┘
>                     Slot 1 es el inmediato de Slot 0
> ```

## Instruction Reference Sheet

> [!TIP]
>
> **Convención de codificación:** en todos los formatos, el `opcode` ocupa los bits **[1:0]**. El bit `imm` se ubica, en caso de ser necesario, **inmediatamente después** del opcode. Los campos restantes se distribuyen en los bits superiores.

### Formato MATH

#### Estructura interna (16 bits)

| Bits    | Campo  | Ancho | Descripción |
|---------|--------|-------|-------------|
| [15:13] | `rs1`  | 3     | Registro fuente y destino (`Reg[rs1] ← Reg[rs1] op Reg[rs2]`) |
| [12:10] | `rs2`  | 3     | Registro fuente |
| [9:4]   | `funct`| 6     | Operación específica |
| [3]     | `pipe` | 1     | 0 = ALU general, 1 = ALU especializada (mul/shift) |
| [2]     | `imm`  | 1     | Bandera de inmediato en el siguiente slot |
| [1:0]   | `opcode`| 2    | `00` = MATH |

**Forma de uso:** `<instr> rs1, rs2` → `Reg[rs1] ← Reg[rs1] <op> Reg[rs2]`

Con inmediato (`imm = 1`): `<instr> rs1, #imm` → `Reg[rs1] ← Reg[rs1] <op> imm`

#### Tabla de instrucciones MATH

| Instrucción | `funct` | `pipe` | `imm` | Descripción |
|-------------|---------|--------|-------|-------------|
| `nop`       | `000000`| 0      | 0     | No operación |
| `mov`       | `000001`| 0      | 0     | `rs1 ← rs2` |
| `sum`       | `000010`| 0      | 0     | `rs1 ← rs1 + rs2` |
| `sumi`      | `000010`| 0      | 1     | `rs1 ← rs1 + imm` |
| `diff`       | `000011`| 0      | 0     | `rs1 ← rs1 − rs2` |
| `diffi`       | `000011`| 0      | 1     | `rs1 ← rs1 − imm` |
| `and`       | `000100`| 0      | 0     | `rs1 ← rs1 & rs2` |
| `andi`      | `000100`| 0      | 1     | `rs1 ← rs1 & imm` |
| `or`        | `000101`| 0      | 0     | `rs1 ← rs1 \| rs2` |
| `ori`       | `000101`| 0      | 1     | `rs1 ← rs1 \| imm` |
| `xor`       | `000110`| 0      | 0     | `rs1 ← rs1 ^ rs2` |
| `xori`      | `000110`| 0      | 1     | `rs1 ← rs1 ^ imm` |
| `not`       | `000111`| 0      | 0     | `rs1 ← ~rs1` |
| `shl`       | `001000`| 1      | 0     | `rs1 ← rs1 << rs2` (lógico) |
| `shli`      | `001000`| 1      | 1     | `rs1 ← rs1 << imm` |
| `shr`       | `001001`| 1      | 0     | `rs1 ← rs1 >> rs2` (lógico) |
| `shri`      | `001001`| 1      | 1     | `rs1 ← rs1 >> imm` |
| `sar`       | `001010`| 1      | 0     | `rs1 ← rs1 >>> rs2` (aritmético) |
| `sari`      | `001010`| 1      | 1     | `rs1 ← rs1 >>> imm` |
| `mul`       | `001011`| 1      | 0     | `rs1 ← rs1 × rs2` (parte baja) |
| `muli`      | `001011`| 1      | 1     | `rs1 ← rs1 × imm` |
| `gtn`       | `001100`| 0      | 0     | `rs1 ← (rs1 > rs2) ? 1 : 0` |
| `ltn`       | `001101`| 0      | 0     | `rs1 ← (rs1 < rs2) ? 1 : 0` |
| `eor`       | `001110`| 0      | 0     | `rs1 ← (rs1 == rs2) ? 1 : 0` |
| `nez`       | `001111`| 0      | 0     | `rs1 ← (rs1 != 0) ? 1 : 0` |

**Notas:**

- Las operaciones con sufijo `i` (por ejemplo `sumi`) requieren `imm = 1` y consumen el slot siguiente como inmediato de 16 bits.
- Las operaciones lógicas y comparaciones actualizan las banderas `Z`, `N`, `C`, `V` del registro de estado.
- Las operaciones `pipe = 1` se ejecutan en la ALU especializada.

### Formato LOST

#### Estructura interna (16 bits)

| Bits    | Campo  | Ancho | Descripción |
|---------|--------|-------|-------------|
| [15:13] | `rd`   | 3     | Registro destino (load) o fuente (store) |
| [12:10] | `rs`   | 3     | Registro base para el cálculo de dirección |
| [9:6]   | `funct`| 4     | Operación específica |
| [5:3]   | `off`  | 3     | Offset corto (0–7) |
| [2]     | `imm`  | 1     | Bandera de inmediato en el siguiente slot |
| [1:0]   | `opcode`| 2    | `01` = LOST |

**Forma de uso:** `<instr> rd, off(rs)` → `Reg[rd] ← Mem[Reg[rs] + off]`

Con inmediato (`imm = 1`): `<instr> rd, imm(rs)` → `Reg[rd] ← Mem[Reg[rs] + imm]`

#### Tabla de instrucciones LOST

| Instrucción | `funct` | `imm` | Descripción |
|-------------|---------|-------|-------------|
| `low`       | `0000`  | 0     | Carga palabra de 32 bits: `rd ← Mem[rs + off]` |
| `lowi`      | `0000`  | 1     | Carga palabra de 32 bits: `rd ← Mem[rs + imm]` |
| `lob`       | `0001`  | 0     | Carga byte con extensión de signo: `rd ← sext(Mem[rs + off])` |
| `lobi`      | `0001`  | 1     | Carga byte con extensión de signo: `rd ← sext(Mem[rs + imm])` |
| `lobu`      | `0010`  | 0     | Carga byte con extensión de ceros: `rd ← zext(Mem[rs + off])` |
| `lobui`     | `0010`  | 1     | Carga byte con extensión de ceros: `rd ← zext(Mem[rs + imm])` |
| `loh`       | `0011`  | 0     | Carga media palabra con signo: `rd ← sext(Mem[rs + off])` |
| `lohi`      | `0011`  | 1     | Carga media palabra con signo: `rd ← sext(Mem[rs + imm])` |
| `lohu`      | `0100`  | 0     | Carga media palabra con ceros: `rd ← zext(Mem[rs + off])` |
| `lohui`     | `0100`  | 1     | Carga media palabra con ceros: `rd ← zext(Mem[rs + imm])` |
| `stw`       | `0101`  | 0     | Almacena palabra: `Mem[rs + off] ← rd` |
| `stwi`      | `0101`  | 1     | Almacena palabra: `Mem[rs + imm] ← rd` |
| `stb`       | `0110`  | 0     | Almacena byte: `Mem[rs + off] ← rd[7:0]` |
| `stbi`      | `0110`  | 1     | Almacena byte: `Mem[rs + imm] ← rd[7:0]` |
| `sth`       | `0111`  | 0     | Almacena media palabra: `Mem[rs + off] ← rd[15:0]` |
| `sthi`      | `0111`  | 1     | Almacena media palabra: `Mem[rs + imm] ← rd[15:0]` |

**Notas:**

- `sext` = extensión de signo; `zext` = extensión de ceros.
- Los accesos deben respetar la alineación (Sec. 7.3).
- Un acceso desalineado genera `DIRECCION_INVALIDA`.

### Formato JUMP

#### Estructura interna (16 bits)

| Bits    | Campo  | Ancho | Descripción |
|---------|--------|-------|-------------|
| [15:13] | `rd`   | 3     | Registro evaluado (condicional) o dirección (jr) |
| [12:5]  | `off`  | 8     | Offset de salto (en bundles, múltiplo de 8 bytes) |
| [4:3]   | `funct`| 2     | Tipo de salto |
| [2]     | `imm`  | 1     | Bandera de inmediato en el siguiente slot |
| [1:0]   | `opcode`| 2    | `10` = JUMP |

**Forma de uso:** `<instr> rd, off` → modifica `PC` según la condición

Con inmediato (`imm = 1`): `<instr> rd, imm` → usa el inmediato de 16 bits del slot siguiente como offset.

#### Tabla de instrucciones JUMP

| Instrucción | `funct` | `imm` | Descripción |
|-------------|---------|-------|-------------|
| `j`         | `00`    | 0     | Salto incondicional relativo: `PC ← PC + off` |
| `ji`        | `00`    | 1     | Salto incondicional relativo: `PC ← PC + imm` |
| `jz`        | `01`    | 0     | Salto condicional si `rd == 0`: `PC ← PC + off` |
| `jzi`       | `01`    | 1     | Salto condicional si `rd == 0`: `PC ← PC + imm` |
| `jnz`       | `10`    | 0     | Salto condicional si `rd != 0`: `PC ← PC + off` |
| `jnzi`      | `10`    | 1     | Salto condicional si `rd != 0`: `PC ← PC + imm` |
| `jr`        | `11`    | 0     | Salto indirecto: `PC ← Reg[rd]` |

### Formato CRYPTO

#### Estructura interna (16 bits)

...

#### Tabla de instrucciones CRYPTO

| Instrucción | `funct` | Descripción |
|-------------|---------|-------------|
| `auth`      | `000`   | Envía el token en `rs1` a la bóveda. Si coincide con la contraseña almacenada, `AUTH ← 1`. |
| `write`     | `001`   | Almacena la subllave de 32 bits de `rs1` en la posición `k_idx` (llave 0–3), `sk_idx` (subllave 0–3). Requiere `AUTH = 1`. |
| `feistel`   | `010`   | Ejecuta una ronda Feistel4: recibe L en `rs1`, R en `rs2`, usa la subllave `rnd_idx` de la llave `k_idx`. Devuelve nuevo L en `rs1` y nuevo R en `rs2`. Requiere `AUTH = 1`. |
| `pwd`       | `011`   | Cambia la contraseña de la bóveda al valor de `rs1`. Requiere `AUTH = 1`. |
| `rvk`       | `100`   | Revoca la autenticación: `AUTH ← 0`. |

---

<div align="right">

<img src="https://markdownviewer.pages.dev/api/image/0vHRcN0FG_gpvkRPJEdgWxjp" alt="porygon" width="50" height="50">

</div>
