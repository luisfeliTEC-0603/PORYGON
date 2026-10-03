# Guía de Implementación del Procesador VLIW (PORYGON)

Esta guía establece la hoja de ruta técnica, la arquitectura modular y el desglose de tareas para la implementación en SystemVerilog del procesador VLIW de 128 bits.

---

## 1. Introducción y Flujo de Datos

El procesador **PORYGON** es un procesador de arquitectura VLIW (Very Long Instruction Word) orientado a la aceleración de algoritmos de cifrado simétrico por bloques (Feistel4) y a la ejecución de código de propósito general. 

### Características Principales:
* **Ancho de Bundle:** 128 bits, dividido en **4 slots** de 32 bits cada uno.
* **Modelo de Ejecución:** Paralelismo a Nivel de Instrucción (ILP) estático. Las 4 instrucciones encapsuladas en un bundle se decodifican y ejecutan simultáneamente en unidades funcionales paralelas durante el mismo ciclo de reloj.
* **Pipeline:** Segmentado en 4 etapas principales: Fetch (IF), Decode/Dispatch (ID), Execute (EX) y Writeback (WB).

### Flujo de Datos al Procesar un Bundle ($W, X, Y, Z$):
Consideremos un bundle de 128 bits compuesto por 4 operaciones independientes:
`Bundle = [ Slot 0: W (MATH) | Slot 1: X (LOST) | Slot 2: Y (JUMP) | Slot 3: Z (CRYPTO) ]`

```
   +-----------------------------------------------------------------------+
   |                       FETCH STAGE (IF)                                |
   |  PC ---> Instruction Memory (128-bit) ---> Raw Bundle [127:0]          |
   +-----------------------------------++----------------------------------+
                                       ||
                                       \/
   +-----------------------------------------------------------------------+
   |                    DECODE & DISPATCH STAGE (ID)                       |
   |                                                                       |
   |   Raw Bundle [127:0] ---> [ Dispatcher / Decoder ]                    |
   |                               |                                       |
   |      +------------------------+-----------------------+               |
   |      |                        |                       |               |
   |  Slot 0 [127:96]          Slot 1 [95:64]          Slot 2 [63:32]      |
   |  (Instrucción W)          (Instrucción X)         (Instrucción Y)     |
   |      |                        |                       |               |
   |      v                        v                       v               |
   |  [Decodificador 0]        [Decodificador 1]       [Decodificador 2]   |
   |      |                        |                       |               |
   |      +------------------------+-----------------------+               |
   |                               |                                       |
   |                               v                                       |
   |                   Register File (8 x 32-bit)                          |
   |                   Lectura de Puertos Paralelos                        |
   +-----------------------------------++----------------------------------+
                                       ||
                                       \/
   +-----------------------------------------------------------------------+
   |                       EXECUTE STAGE (EX)                              |
   |                                                                       |
   |    Operandos W      Operandos X      Operandos Y     Operandos Z      |
   |         |                |                |               |           |
   |         v                v                v               v           |
   |    +---------+      +---------+      +---------+     +----------+     |
   |    |  ALU 1  |      |   LSU   |      |   BRU   |     | Crypto / |     |
   |    | (Math)  |      | (Load/  |      | (Jump/  |     | KeyVault |     |
   |    |         |      | Store)  |      | Branch) |     | (Feistel)|     |
   |    +----+----+      +----+----+      +----+----+     +----+-----+     |
   |         |                |                |               |           |
   +---------|----------------|----------------|---------------|-----------+
             |                |                |               |
             v                v                v               v
   +-----------------------------------------------------------------------+
   |                      WRITEBACK STAGE (WB)                             |
   |                                                                       |
   |   - Retorno de resultados hacia el Register File (Puertos de escritura)|
   |   - Acceso a Memoria de Datos (RAM) mediante la LSU                   |
   |   - Actualización de PC (dirección de salto desde la BRU)              |
   |   - Escritura/Consulta interna en la Bóveda de Llaves (Key Vault)     |
   +-----------------------------------------------------------------------+
```

1. **Fetch (IF):** El `PC` direcciona la Memoria de Instrucciones y recupera una palabra de 128 bits.
2. **Decode/Dispatch (ID):** El `Dispatcher` descuartiza el bundle en 4 slots de 32 bits. Identifica el `opcode` de cada slot y extrae las direcciones de los registros fuente (`rs1`, `rs2`). Lee en paralelo los valores desde el `Register File`.
3. **Execute (EX):** Cada unidad funcional procesa su correspondiente operación de forma paralela en el mismo ciclo:
   * **Slot 0 ($W$):** Ejecuta la operación aritmética/lógica en la `ALU 1`.
   * **Slot 1 ($X$):** La `LSU` calcula la dirección efectiva de memoria (`rs2 + off`).
   * **Slot 2 ($Y$):** La `BRU` evalúa las condiciones de salto (`jz`, `jnz`) para determinar el nuevo `PC`.
   * **Slot 3 ($Z$):** La `Crypto Unit` interactúa con la `Key Vault` para ejecutar una ronda de `Feistel4`.
4. **Writeback (WB):** Los resultados calculados se escriben concurrentemente en los registros destino del `Register File` y/o en la memoria RAM.

---

## 2. Desglose de Requisitos del Proyecto

### 2.1 Especificación del ISA (PORYGON ISA)
* **Descripción:** Definición del conjunto de instrucciones de 32 bits divididas en 4 formatos principales: `MATH` (`00`), `LOST` (`01`), `JUMP` (`10`) y `CRYPTO` (`11`).
* **Ejemplo:** `sumi rs1, rs2` (Suma con inmediato enviado en el slot adyacente del bundle).
* **Cómo y Por Qué:** Se implementa con un espacio de registros reducido (8 registros de 32 bits, con `r0 = 0`) para simplificar el decodificador y minimizar la lógica de selección en los puertos de lectura/escritura.

### 2.2 Unidades Funcionales (FUs)
* **Descripción:** Bloques de cómputo independientes diseñados para operar simultáneamente.
* **Componentes:**
  * **ALU 1 / ALU 2:** Operaciones aritméticas, lógicas, de comparación y desplazamientos.
  * **LSU (Load/Store Unit):** Gestión de lectura y escritura en la memoria de datos en formatos byte, media palabra y palabra completa (`low`, `stw`, `lob`, `stb`).
  * **BRU (Branch Unit):** Cálculo de direcciones de salto condicional e incondicional.
  * **Crypto Unit & Key Vault:** Motor de cifrado y bóveda segura de almacenamiento de llaves.

### 2.3 Unidad Criptográfica y Algoritmo Feistel4
* **Descripción:** Módulo de hardware acelerador que ejecuta la función de ronda Feistel sobre bloques de 64 bits (mitad izquierda $L$ de 32 bits en `rs1`, mitad derecha $R$ de 32 bits en `rs2`).
* **Función de Ronda:** $F(x, k) = \text{ROL32}((\text{ROL32}(x, 5) + k), 13)$.
* **Ejemplo:** `feistl rs1, rs2, k_idx, rnd_idx`.
* **Cómo y Por Qué:** En lugar de ejecutar las 4 rondas en una única instrucción monolítica (lo cual crearía una ruta crítica de propagación de reloj demasiado larga), se implementa una instrucción por ronda. Esto permite al compilador agendar 4 invocaciones consecutivas de `feistl` explotando la filosofía VLIW.

### 2.4 Bóveda de Llaves (Key Vault) y Control de Acceso
* **Descripción:** Memoria segura que almacena hasta 4 llaves de 128 bits (cada una compuesta por 4 subllaves de 32 bits).
* **Restricciones de Hardware:**
  * Las subllaves **nunca** pueden leerse hacia el `Register File` o la memoria de datos general (prevención de fugas de llaves).
  * Las operaciones sobre la bóveda requieren que la máquina de estados (FSM) esté en estado `AUTENTICADO`.
* **Manejo de Autenticación:** Instrucciones `auth rs1` (envía token de validación), `pwd rs1` (cambia contraseña), `rvk` (revoca permisos / logout).

### 2.5 Carga y Extracción de Archivos
* **Descripción:** Herramienta en software (`load_file.py` y `extract_data.py`) que lee archivos reales (texto, imágenes BMP, binarios), los empaqueta en formato ejecutable de memoria Verilog (`.mem`), e inyecta los bloques a cifrar/descifrar en las direcciones correspondientes de la RAM del procesador.
* **Integración con Feistel4:** El programa en ensamblador cargado en la Memoria de Instrucciones lee los bloques de datos desde la memoria RAM (inyectados por `load_file.py`), aplica las rondas de `feistl` utilizando las llaves de la `Key Vault`, y escribe el resultado cifrado de vuelta en la RAM para que `extract_data.py` extraiga el archivo procesado.

### 2.6 Ensamblador Propio
* **Descripción:** Script independiente en Python que lee un archivo en ensamblador (.asm) estructurado en bundles de 4 slot y produce la representación hexadecimal binaria para inicializar la memoria de instrucciones mediante `$readmemh`.

---

## 3. Diseño Modular Nivel 5 del Procesador

El procesador se estructura en 5 niveles de abstracción jerárquica:

```
[Nivel 1] top_system (Sistema Completo: Procesador + Memorias)
   └── [Nivel 2] vliw_processor (Datapath y Control)
        ├── [Nivel 3] fetch_stage
        │    └── PC Module + Instruction Memory Interface
        ├── [Nivel 3] dispatch_stage
        │    ├── bundle_decoder (Separador de Slots)
        │    └── [Nivel 4] slot_decoder (x4)
        ├── [Nivel 3] register_file (8 Regs x 32b, Multi-puerto)
        ├── [Nivel 3] execution_stage
        │    ├── [Nivel 4] alu_unit (Math Engine)
        │    │    └── [Nivel 5] adder_subtractor, logic_unit, shifter
        │    ├── [Nivel 4] lsu_unit (Load/Store Engine)
        │    │    └── [Nivel 5] address_calculator, byte_enable_logic
        │    ├── [Nivel 4] bru_unit (Branch Engine)
        │    │    └── [Nivel 5] comparator_unit, target_pc_calculator
        │    └── [Nivel 4] crypto_unit
        │         ├── [Nivel 5] feistel_round_logic (ROL32 + ADD + ROL32)
        │         └── [Nivel 5] key_vault (Secure Memory + Auth FSM)
        └── [Nivel 3] writeback_stage
             └── Multiplexores de Selección de Resultado por Slot
```

### Detalle del Interior de las Unidades Funcionales Principal:

#### 1. `register_file.sv`
* **Función:** Almacena los 8 registros de 32 bits. `r0` está permanentemente conectado a cero (`32'h0`).
* **Puertos:**
  * 8 Puertos de Lectura de 3 bits (`r_addr_0` a `r_addr_7`).
  * 4 Puertos de Escritura de 3 bits (`w_addr_0` a `w_addr_3`), habilitados por `w_en`.
* **Ejemplo de Uso:** Al ejecutar un bundle con 4 instrucciones que leen 2 registros cada una, los 8 puertos de lectura devuelven los operandos a las 4 FUs de forma simultánea.

#### 2. `key_vault.sv` y `crypto_unit.sv`
* **Función:** Administra el almacenamiento seguro de llaves y computa la función de ronda Feistel4.
* **FSM Interna (`key_vault.sv`):**
  * Estado `LOCKED`: Bloquea cualquier operación `write` o `feistl`.
  * Estado `UNLOCKED`: Se activa cuando `auth_token_in == internal_password`. Permite escribir subllaves y ejecutar rondas.
* **Logica Combinacional (`crypto_unit.sv`):**
  * Recibe $L$ (`rs1`), $R$ (`rs2`), $K_{idx}$ (0-3) y $Rnd_{idx}$ (0-3).
  * Extrae la subllave $K$ de 32 bits de la Bóveda.
  * Realiza: $T = \text{ROL32}(R, 5) + K$.
  * $F\_out = \text{ROL32}(T, 13)$.
  * Nuevo $L = R$, Nuevo $R = L \oplus F\_out$.

---

## 4. Archivos SystemVerilog y Estructura de Proyecto

A continuación se detalla la estructura completa del repositorio y los archivos que deben crearse:

```
vliw_processor/
├── docs/
│   ├── isa.md
│   ├── microarchitecture.md
│   ├── simulation.md
│   └── compiler-integration.md
├── hardware/
│   ├── src/
│   │   ├── pkg_vliw.sv            # Tipos de datos, structs, enums y constantes globales
│   │   ├── fetch_stage.sv         # Manejo del PC e interfaz de Memoria de Instrucciones
│   │   ├── dispatch_stage.sv      # Decodificación paralela de los 4 slots de 32 bits
│   │   ├── register_file.sv       # Banco de 8 registros x 32 bits multi-puerto
│   │   ├── alu_unit.sv            # Módulo ALU (Suma, resta, lógicas, desplazamientos)
│   │   ├── lsu_unit.sv            # Módulo de acceso a memoria de datos (Load/Store)
│   │   ├── bru_unit.sv            # Módulo de saltos condicionales e incondicionales
│   │   ├── key_vault.sv           # Memoria segura de llaves y FSM de autenticación
│   │   ├── crypto_unit.sv         # Circuitería combinacional para ronda Feistel4
│   │   ├── execution_stage.sv     # Wrapper que agrupa las 4 unidades funcionales
│   │   ├── writeback_stage.sv     # Lógica de arbitraje y escritura en RegFile / RAM
│   │   ├── memory_sp_ram.sv       # Modelo de Memoria RAM de datos (64 KB mínimo)
│   │   └── vliw_processor.sv      # Módulo Top del Procesador (Datapath + Pipeline Regs)
│   └── tb/
│       ├── tb_pkg.sv              # Utilidades de simulación
│       ├── tb_alu.sv              # Pruebas unitarias de la ALU
│       ├── tb_crypto.sv           # Pruebas unitarias de Feistel4 y Bóveda
│       ├── tb_lsu.sv              # Pruebas unitarias de lecturas/escrituras en RAM
│       └── tb_top.sv              # Testbench de integración completa del procesador
├── tools/
│   ├── assembler/
│   │   └── asm.py                 # Ensamblador propio (ASM -> Hexadecimal .mem)
│   └── data_loader/
│       ├── load_file.py           # Inyector de archivos reales (texto/imágenes) a .mem
│       └── extract_data.py        # Extractor de memoria dump a archivo binario
├── Makefile                       # Automatización de compilación con Icarus Verilog y Verilator
└── README.md                      # Manual de uso y documentación principal
```

### Descripción de los Módulos Clave:

1. **`pkg_vliw.sv`**: Define los enums `opcode_e`, `math_func_e`, `crypto_func_e`, structs para los slots codificados y constantes globales como `BUNDLE_WIDTH = 128` y `SLOT_WIDTH = 32`.
2. **`asm.py` (Ensamblador Propio)**: Lee sintaxis de ensamblador VLIW en líneas agrupadas de 4 slots. Ejemplo de sintaxis de entrada:
   ```asm
   { sum rs1, rs2 | low rs3, 0(rs4) | jz rs1, 8 | feistl rs5, rs6, 0, 0 }
   ```
   Produce la salida hexadecimal en palabras de 128 bits para `$readmemh("instructions.mem", inst_mem)`.
3. **`load_file.py`**:
   * Convierte un archivo de entrada (ej: `imagen.bmp`) en una secuencia de bytes hexadecimales formateados para cargarse en la RAM desde una dirección base (`--address 0x1000`).

---

## 5. Matriz de Tareas e Issues del Proyecto

Para la gestión del proyecto en GitHub/GitLab, a continuación se presenta la lista estandarizada de Issues ordenados cronológicamente:

### [Issue #01] - Definición del Paquete Global de SystemVerilog (`pkg_vliw.sv`)
* **Orden:** 1
* **Especificación:** Crear el archivo de definición de constantes, tipos `enum` para los opcodes (`MATH`, `LOST`, `JUMP`, `CRYPTO`), funciones `funct`, y estructuras de datos para decodificación de slots.
* **Resultado Esperado:** Archivo `pkg_vliw.sv` compilable sin advertencias en Icarus Verilog.

### [Issue #02] - Diseño del Banco de Registros Multi-Puerto (`register_file.sv`)
* **Orden:** 2
* **Especificación:** Implementar el módulo de 8 registros de 32 bits. Debe contar con 8 puertos de lectura asíncrona y 4 puertos de escritura síncrona. Garantizar que la lectura de `r0` devuelva siempre `32'h00000000`.
* **Resultado Esperado:** Testbench `tb_regfile.sv` que verifique lecturas/escrituras simultáneas y la inmutabilidad de `r0`.

### [Issue #03] - Unidad Aritmético-Lógica (`alu_unit.sv`)
* **Orden:** 3
* **Especificación:** Implementar operaciones para las instrucciones `cln`, `sum`, `sumi`, `diff`, `diffi`, `and`, `andi`, `or`, `ori`, `xor`, `gtn`, `ltn`, `eq`, `sll`, `slr`, `mul`.
* **Resultado Esperado:** Testbench `tb_alu.sv` verificando cada flag y resultado aritmético contra valores de referencia.

### [Issue #04] - Unidad de Acceso a Memoria (`lsu_unit.sv`)
* **Orden:** 4
* **Especificación:** Diseñar la lógica de cálculo de dirección efectiva (`rs2 + off`) y habilitadores de byte/half-word/word para operaciones `low`, `stw`, `lob`, `lobu`, `loh`, `lohu`, `stb`, `sth`.
* **Resultado Esperado:** Simulación en GTKWave que demuestre la alineación de bytes y extensión de signo/ceros según la especificación del ISA.

### [Issue #05] - Bóveda de Llaves y FSM Criptográfica (`key_vault.sv`)
* **Orden:** 5
* **Especificación:** Implementar el arreglo de $4 \times 128$ bits para subllaves. Crear la FSM con estados `LOCKED` y `UNLOCKED`. Implementar la lógica para las instrucciones `auth`, `write`, `pwd`, `rvk`. Asegurar que los datos de la bóveda no se conecten a los buses del RegFile.
* **Resultado Esperado:** Demostración de que la bóveda rechaza llamadas `write` sin previa autenticación y que `rvk` bloquea los accesos.

### [Issue #06] - Acelerador de Ronda Feistel4 (`crypto_unit.sv`)
* **Orden:** 6
* **Especificación:** Implementar la lógica de rotación de bits y suma modular $2^{32}$: $F(x, k) = \text{ROL32}((\text{ROL32}(x, 5) + k), 13)$. Conectar las entradas $L, R$ y la subllave obtenida de la `key_vault`.
* **Resultado Esperado:** Validación de una ronda Feistel4 comparando el valor calculado contra el valor producido por la función C de referencia (`feistel4_F`).

### [Issue #07] - Unidad de Control de Flujo (`bru_unit.sv`)
* **Orden:** 7
* **Especificación:** Implementar la lógica de evaluación de saltos (`j`, `ji`, `jz`, `jzi`, `jnz`, `jnzi`, `jr`) y cálculo del nuevo `PC`.
* **Resultado Esperado:** Generación correcta del vector del nuevo `PC` y bandera `branch_taken`.

### [Issue #08] - Decodificador y Despachador de Bundles (`dispatch_stage.sv`)
* **Orden:** 8
* **Especificación:** Diseñar el módulo que recibe la palabra de 128 bits, extrae los 4 slots de 32 bits, decodifica los opcodes y extrae las direcciones de registros para el `register_file.sv`.
* **Resultado Esperado:** Desglose correcto de 4 instrucciones simuladas en paralelo dentro del mismo ciclo.

### [Issue #09] - Integración del Pipeline y Módulo Top (`vliw_processor.sv`)
* **Orden:** 9
* **Especificación:** Conectar las etapas IF, ID, EX, WB mediante registros de pipeline (`IF_ID`, `ID_EX`, `EX_WB`). Unificar los módulos con la memoria RAM de datos e instrucciones.
* **Resultado Esperado:** Procesador funcional capaz de ejecutar programas simples de prueba en un archivo `tb_top.sv`.

### [Issue #10] - Desarrollo del Ensamblador Propio (`asm.py`)
* **Orden:** 10
* **Especificación:** Crear la herramienta en Python que traduzca código ensamblador VLIW orientado a slots hacia el formato binario/hexadecimal en palabras de 128 bits.
* **Resultado Esperado:** Conversión exitosa de un programa test de ensamblador a un archivo `.mem` consumible por `$readmemh`.

### [Issue #11] - Desarrollo de la Herramienta de Carga y Extracción de Archivos (`load_file.py` / `extract_data.py`)
* **Orden:** 11
* **Especificación:** Crear los scripts CLI en Python para inyectar archivos genéricos en las direcciones de la RAM y extraer la memoria procesada tras la simulación.
* **Resultado Esperado:** Inyección de un archivo `texto.txt` o `imagen.bmp` a la memoria, simulación de cifrado, extracción y verificación del archivo resultado.

### [Issue #12] - Pruebas de Integración y Cifrado Completo de Feistel4
* **Orden:** 12
* **Especificación:** Ejecutar un programa completo en ensamblador VLIW que autentique la bóveda, guarde una llave de 128 bits, ejecute las 4 rondas de cifrado Feistel4 sobre un bloque de datos cargado mediante `load_file.py`, y ejecute la rutina de descifrado en orden inverso.
* **Resultado Esperado:** Coincidencia byte por byte entre los datos descifrados por el procesador VLIW y el archivo original.