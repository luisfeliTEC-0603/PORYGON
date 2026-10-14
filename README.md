# PORYGON




<div align="center">

<img src="https://markdownviewer.pages.dev/api/image/0vHRcN0FG_gpvkRPJEdgWxjp" alt="porygon" width="200" height="200">

[![VLIW](https://img.shields.io/badge/Architecture-VLIW-fa646b?style=for-the-badge&logoColor=white)]()
[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-2026-5fa69f?style=for-the-badge&logoColor=white)]()
[![Cipher](https://img.shields.io/badge/Cipher-Feistel4-fa646b?style=for-the-badge&logoColor=white)]()

**Procesador VLIW con ISA propia y una unidad criptográfica Feistel4**

</div>

## Alcance y estado actual

Proyecto académico CE4301, desarrollado **100% por simulación** con Icarus
Verilog o Verilator. No requiere síntesis ni implementación en FPGA.

El repositorio contiene el procesador, sus memorias de simulación, testbenches,
ensamblador, scheduler y herramientas de carga y extracción. El `Makefile`
permite ejecutar pruebas unitarias y de sistema con Icarus Verilog; `sim.sh`
ofrece la interfaz corta para cargar programas externos y conservar evidencia.

La ISA define bundles de 64 bits, compuestos por cuatro slots de 16 bits,
con asignación flexible de unidades funcionales.

## Simulación rápida

La interfaz habitual del proyecto evita escribir directamente los plusargs de
Verilog:

```bash
make sim PROG=programa.mem
make sim PROG=hardware/tb/programs/crypto_integration.mem \
  DATA=hardware/tb/programs/crypto_data.mem CYCLES=180
```

`CYCLES` vale 200 por defecto y `DATA` es opcional. Cada programa conserva
`memory.dump.mem`, `waves.vcd`, `simulation.log` y `results.txt` en
`sim_output/<programa>/`; al terminar se imprimen las rutas absolutas de esos
archivos. `make sim` sin `PROG` ejecuta la regresión predeterminada de ALU,
SUPER-ALU y procesador completo (`sim-top`).

`top_integration.mem` pertenece a una prueba negativa que accede fuera del rango
de datos de manera intencional. Para validar ese caso se usa `make sim` sin
`PROG`; ejecutarlo directamente con `PROG` informa correctamente el evento como
un error arquitectónico.

Para validaciones reproducibles con resultados esperados se usa directamente
el runner avanzado:

```bash
./sim.sh programa.mem
./sim.sh programa.mem 300 --data datos.mem
./sim.sh programa.mem 300 --expect r1=10 --expect errors=0
```

El segundo argumento es el presupuesto de ciclos. `--out directorio` cambia la
ubicación de los artefactos. Sin expectativas se informa una ejecución
completada, pero no se afirma corrección funcional.

## Extracción rápida

Después de `make sim`, el wrapper local recupera un rango del volcado sin pedir
su ruta completa:

```bash
./extract.sh programa 0x10000 32 resultado.bin
```

El comando lee `sim_output/programa/memory.dump.mem` y guarda la salida como
`sim_output/programa/resultado.bin`. El cuarto argumento es opcional y vale
`resultado.bin` por defecto. También se puede pasar como primer argumento la
ruta explícita a cualquier dump `.mem`.

## Estructura

| Ruta | Contenido |
|------|-----------|
| `hardware/src/` | Paquete compartido, etapas del pipeline, unidades funcionales, banco de registros y modelo de memoria |
| `hardware/src/crypto/` | Interfaces de la unidad CRYPTO, decodificador, bóveda, ronda Feistel y registro EX/WB |
| `hardware/tb/` | Archivos reservados para testbenches unitarios y de integración |
| `tools/assembler/` | Ensamblador propio pendiente de implementación |
| `tools/data_loader/` | Herramienta de carga y extracción de archivos (implementada) |
| `docs/` | Enunciado, ISA, guía y documentación técnica |
| `Makefile` | Archivo reservado para automatizar la simulación |
| `agents.md` | Directrices de trabajo y codificación para agentes |

## Referencias

- [Enunciado del proyecto](docs/EnunciadoArqui.md): requisitos oficiales.
- [ISA](docs/isa.md): formatos, instrucciones y codificación.
- [Guía de implementación](docs/GUIA.md): planificación auxiliar del desarrollo.
- [Microarquitectura](docs/microarchitecture.md): pendiente de documentar.
- [Simulación](docs/simulation.md): pendiente de documentar.
- [Integración con CE1108](docs/compiler-integration.md): pendiente de documentar.
- [Directrices para agentes](agents.md): autorización, alcance y convenciones.

En caso de conflicto, las instrucciones del usuario prevalecen sobre el enunciado,
y el enunciado sobre la ISA. La guía es material auxiliar.

## Herramienta de carga y extracción de archivos

Inyecta archivos de cualquier formato (texto, imágenes, binarios) en la memoria de
la simulación y recupera los datos procesados. Requiere únicamente Python 3.8 o
superior, sin dependencias externas.

| Archivo | Función |
|---------|---------|
| `tools/data_loader/load_file.py` | Convierte un archivo en una imagen `.mem` para `$readmemh` |
| `tools/data_loader/extract_data.py` | Recupera un rango de un volcado de `$writememh` como archivo binario |
| `tools/data_loader/memimage.py` | Empaquetado, renderizado y parseo del formato `.mem`, compartido por ambos |

### Carga

```bash
python tools/data_loader/load_file.py --input archivo.txt --output memory.mem --address 0x8000
```

| Opción | Default | Descripción |
|--------|---------|-------------|
| `--input` | — | Archivo de entrada, de cualquier formato |
| `--output` | — | Imagen `.mem` de salida |
| `--address` | `0x0` | Dirección de carga |
| `--width` | `8` | Bits por palabra del `.mem`; debe coincidir con el ancho del arreglo de `memory_sp_ram.sv` |
| `--endian` | `little` | Orden de bytes dentro de la palabra |
| `--mem-base` | `0x0` | Dirección que corresponde a la posición 0 del arreglo |
| `--mem-bytes` | `65536` | Tamaño del arreglo en bytes; coincide con `MEMORY_BYTES` de `pkg_vliw.sv` |
| `--block` | `8` | Rellena con ceros hasta múltiplo de N bytes (los 64 bits de un bloque Feistel4) |
| `--no-pad` | — | No rellenar el último bloque |
| `--append` | — | Agrega el bloque a un `.mem` existente en lugar de sobrescribirlo |

La salida arranca con una directiva `@`, de modo que `$readmemh` deposita los datos
en la posición correcta sin necesidad de emitir las posiciones previas. El reporte
indica el tamaño original, el relleno aplicado, el rango de direcciones ocupado y
los argumentos exactos que hay que pasarle después a `extract_data.py`.

### Extracción

```bash
python tools/data_loader/extract_data.py --memory memory_dump.mem --address 0x8000 --size 1024 --output resultado.bin
```

| Opción | Default | Descripción |
|--------|---------|-------------|
| `--memory` | — | Volcado generado por `$writememh` |
| `--address` | — | Dirección inicial del rango |
| `--size` | — | Cantidad de bytes a extraer |
| `--output` | — | Archivo binario de salida |
| `--width` | `8` | Bits por palabra del volcado |
| `--endian` | `little` | Orden de bytes dentro de la palabra |
| `--mem-base` | `0x0` | Dirección que corresponde a la posición 0 del arreglo |

Acepta comentarios `//` y `/* */`, directivas `@` y posiciones marcadas con `x` o
`z`, que se interpretan como cero. Las palabras ausentes del volcado se rellenan con
cero y se reporta cuántas fueron.

### Ejemplo completo

Cargar un archivo, cifrarlo en la simulación y recuperar el resultado:

```bash
# 1. Inyectar el archivo en el segmento de datos
python tools/data_loader/load_file.py --input imagen.bmp --output data.mem --address 0x8000
#    tamano original : 70 bytes
#    relleno         : 2 bytes de ceros
#    para extraer    : --address 0x00008000 --size 70

# 2. Ejecutar la simulación: lee data.mem con $readmemh y vuelca memory_dump.mem con $writememh

# 3. Recuperar el resultado con el tamaño original que reportó la carga
python tools/data_loader/extract_data.py --memory memory_dump.mem --address 0x8000 --size 70 --output cifrado.bmp
```

Varios archivos en una misma imagen de memoria:

```bash
python tools/data_loader/load_file.py --input texto.txt  --output data.mem --address 0x8000
python tools/data_loader/load_file.py --input imagen.bmp --output data.mem --address 0x8100 --append
```

## Cobertura prevista de testbenches

Todos los archivos siguientes son placeholders vacíos; esta tabla describe
la cobertura por implementar, no pruebas ya ejecutadas.

| Archivo | Cobertura prevista |
|---------|--------------------|
| `tb_pkg.sv` | Utilidades compartidas de simulación |
| `tb_alu.sv` | Operaciones aritméticas y lógicas de la ISA |
| `tb_regfile.sv` | Lecturas y escrituras simultáneas e inmutabilidad de `r0` |
| `tb_lost.sv` | Cargas, almacenamientos, alineación y extensiones de signo/ceros |
| `tb_bruh.sv` | Saltos condicionales e incondicionales, destino y `branch_taken` |
| `tb_crypto.sv` | Ronda Feistel4 y bóveda: cuatro llaves, autenticación válida/fallida, escritura, cambio de contraseña, revocación y rechazo de accesos no autorizados; aislamiento de llaves frente a registros y memoria generales |
| `tb_top.sv` | Integración del procesador, bundles mixtos y cifrado/descifrado completo contra la referencia |
