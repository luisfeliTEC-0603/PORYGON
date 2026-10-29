# PORYGON

<div align="center">

<img src="docs/imgs/porygon.png" alt="porygon" width="200" height="200">

[![VLIW](https://img.shields.io/badge/Architecture-VLIW-fa646b?style=for-the-badge&logoColor=white)]()
[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-2026-5fa69f?style=for-the-badge&logoColor=white)]()
[![Cipher](https://img.shields.io/badge/Cipher-Feistel4-fa646b?style=for-the-badge&logoColor=white)]()

**Procesador VLIW con ISA propia y una unidad criptográfica Feistel4**

</div>

El repositorio contiene el procesador, sus memorias de referencia, testbenches y herramientas de simulación, carga y extracción de datos. El compilador, el ensamblador y el scheduler se mantienen en **PIPER-COMPILER**; PORYGON recibe las imágenes `.mem` que producen y ejecuta el hardware con Icarus Verilog.

La ISA define bundles de 64 bits, compuestos por cuatro slots de 16 bits, con asignación flexible de unidades funcionales.

## Simulación rápida

```bash
make sim PROG=programa.mem
make sim PROG=programa.mem DATA=datos.mem
```

La simulación termina cuando BRUH ejecuta un salto tomado hacia el PC de esa misma instrucción, convención usada por el codegen para representar `halt`. Cada programa conserva `memory.dump.mem`, `waves.vcd`, `simulation.log` y `results.txt` en `build/sim/<programa>/`; al terminar se imprimen las rutas absolutas de esos archivos.

Existe también un script de simulación avanzado:

```bash
./tools/sim.sh programa.mem
./tools/sim.sh programa.mem --data datos.mem
./tools/sim.sh programa.mem --max-cycles 200000 --expect r1=10 --expect errors=0
```

`--max-cycles` cambia el watchdog solo cuando el programa necesita un límite mayor. `--out directorio` cambia la ubicación de los artefactos. Sin expectativas se informa una ejecución completada, pero no se afirma corrección funcional.

`make clean` elimina `build/`, incluidos los resultados de simulación. Para conservar una ejecución, usar `--out` con una carpeta fuera de `build/` o copiar sus resultados antes de limpiar.

## Extracción rápida

Después de `make sim`, el wrapper local recupera un rango del volcado sin pedir su ruta completa:

```bash
./tools/memory/extract.sh programa 0x10000 32 resultado.bin
```

El comando lee `build/sim/programa/memory.dump.mem` y guarda la salida como `build/sim/programa/resultado.bin`. El cuarto argumento es opcional y vale `resultado.bin` por defecto. También se puede pasar como primer argumento la ruta explícita a cualquier dump `.mem`.

## Estructura

| Ruta | Contenido |
|------|-----------|
| `rtl/` | Paquete compartido y sistema que conecta el núcleo con las memorias |
| `rtl/core/` | Pipeline, unidades funcionales y banco de registros |
| `rtl/core/decode/` | Separación de bundles, inmediatos y despacho a unidades |
| `rtl/core/crypto/` | Unidad CRYPTO, bóveda de llaves y ronda Feistel |
| `rtl/memory/` | Memorias de instrucciones y datos usadas por el sistema actual |
| `tests/unit/` | Testbenches de unidades, banco de registros y decode |
| `tests/integration/` | Regresión del sistema y testbench para programas externos |
| `tests/programs/` | Programas, imágenes de memoria y generadores agrupados por caso |
| `tests/tools/` | Pruebas de las herramientas de memoria |
| `tools/sim.sh` | Ejecución de programas y comprobación opcional de resultados |
| `tools/memory/` | Carga de archivos en memoria y extracción de volcados |
| `docs/` | Enunciado, ISA, guía y documentación técnica |
| `build/` | Binarios de simulación, ondas y resultados generados; no se versiona |

Los fuentes Piper y la implementación de su toolchain pertenecen a PIPER-COMPILER. Los programas incluidos en `tests/programs/` sirven para verificar PORYGON. La ISA y el contrato de integración se documentan aquí; las convenciones del lenguaje y del codegen se mantienen en el compilador.

## Pruebas existentes

Desde la raíz del repositorio:

```bash
make elaborate elaborate-core
make sim
make sim-regfile sim-lost sim-bruh sim-crypto
sh tests/tools/test_loader.sh
```

`make sim` sin `PROG` ejecuta ALU, SuperALU y la regresión `tb_top`; los demás comandos ejecutan los grupos indicados. Los testbenches IDD se conservan en `tests/unit/`, aunque todavía no tienen un target en el Makefile. Estos comandos no representan cobertura completa de la ISA.

Hay un fallo previo a esta reorganización en `sim-crypto-unit`: la comprobación `timeout propagates persistent locked state` falla en 1 de 607 checks. Se reproduce en el commit original `ee38a8e`; su revisión queda para la etapa de pruebas.

## Referencias

- [Enunciado del proyecto](docs/project-description.md): requisitos oficiales.
- [ISA](docs/isa.md): formatos, instrucciones y codificación.
- [Microarquitectura](docs/microarchitecture.md): módulos, pipeline y señales.
- [Simulación](docs/simulation.md): modelo de ejecución, memoria y herramientas.
- [Integración con CE1108](docs/compiler-integration.md): contrato con PIPER-COMPILER y evidencia de factorial.

## Herramienta de carga y extracción de archivos

Inyecta archivos de cualquier formato (texto, imágenes, binarios) en la memoria de la simulación y recupera los datos procesados. Requiere únicamente Python 3.8 o superior, sin dependencias externas.

| Archivo | Función |
|---------|---------|
| `tools/memory/load_file.py` | Convierte un archivo en una imagen `.mem` para `$readmemh` |
| `tools/memory/extract_data.py` | Recupera un rango de un volcado de `$writememh` como archivo binario |
| `tools/memory/memimage.py` | Empaquetado, renderizado y parseo del formato `.mem`, compartido por ambos |
| `tools/memory/extract.sh` | Acceso corto al volcado de una simulación por nombre |

### Carga

```bash
python3 tools/memory/load_file.py --input archivo.txt --output memory.mem --address 0x10000
```

| Opción | Default | Descripción |
|--------|---------|-------------|
| `--input` | — | Archivo de entrada, de cualquier formato |
| `--output` | — | Imagen `.mem` de salida |
| `--address` | Requerido | Dirección física de carga |
| `--width` | `8` | Bits por palabra del `.mem`; debe coincidir con el ancho del arreglo de `memory_sp_ram.sv` |
| `--endian` | `little` | Orden de bytes dentro de la palabra |
| `--mem-base` | `0x10000` | Dirección que corresponde a la posición 0 del arreglo |
| `--mem-bytes` | `65536` | Tamaño del arreglo en bytes; coincide con `MEMORY_BYTES` de `pkg_vliw.sv` |
| `--block` | `8` | Rellena con ceros hasta múltiplo de N bytes (los 64 bits de un bloque Feistel4) |
| `--no-pad` | — | No rellenar el último bloque |
| `--append` | — | Agrega el bloque a un `.mem` existente en lugar de sobrescribirlo |

La salida arranca con una directiva `@` relativa a la base del arreglo: cargar en `0x10020` emite `@00000020`. El loader comprueba que el rango y el relleno quepan en RAM, y avisa si invaden la pila Piper (`0x1F000`–`0x1FFFF`). El reporte indica el tamaño original, el relleno aplicado, el rango ocupado y los argumentos para extraer los datos.

### Extracción

```bash
python3 tools/memory/extract_data.py --memory memory_dump.mem --address 0x10000 --size 1024 --output resultado.bin
```

| Opción | Default | Descripción |
|--------|---------|-------------|
| `--memory` | — | Volcado generado por `$writememh` |
| `--address` | — | Dirección inicial del rango |
| `--size` | — | Cantidad de bytes a extraer |
| `--output` | — | Archivo binario de salida |
| `--width` | `8` | Bits por palabra del volcado |
| `--endian` | `little` | Orden de bytes dentro de la palabra |
| `--mem-base` | `0x10000` | Dirección que corresponde a la posición 0 del arreglo |
| `--mem-bytes` | `65536` | Tamaño del arreglo en bytes; limita el rango extraíble |
| `--allow-uninitialized` | Desactivado | Permite rellenar posiciones ausentes con cero; sigue rechazando `x/z` |

Acepta comentarios `//` y `/* */` y directivas `@`. La extracción falla si el rango solicitado contiene posiciones ausentes o bits `x/z`. `--allow-uninitialized` permite completar únicamente posiciones ausentes con cero y reporta cuántas fueron; los valores `x/z` siempre se rechazan.

### Ejemplo completo

Cargar un archivo, cifrarlo en la simulación y recuperar el resultado:

```bash
# 1. Inyectar el archivo en el segmento de datos
python3 tools/memory/load_file.py --input imagen.bmp --output data.mem --address 0x10000
#    tamano original : 70 bytes
#    relleno         : 2 bytes de ceros
#    para extraer    : --address 0x00010000 --size 70

# 2. Ejecutar un programa que procese los datos
make sim PROG=programa.mem DATA=data.mem

# 3. Recuperar el resultado con el tamaño original que reportó la carga
python3 tools/memory/extract_data.py \
  --memory build/sim/programa/memory.dump.mem \
  --address 0x10000 --size 70 --output cifrado.bmp
```

Varios archivos en una misma imagen de memoria:

```bash
python3 tools/memory/load_file.py --input texto.txt  --output data.mem --address 0x10000
python3 tools/memory/load_file.py --input imagen.bmp --output data.mem --address 0x10100 --append
```
