# PORYGON

<div align="center">

<img src="docs/imgs/porygon.png" alt="porygon" width="200" height="200">

[![VLIW](https://img.shields.io/badge/Architecture-VLIW-fa646b?style=for-the-badge&logoColor=white)]()
[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-2026-5fa69f?style=for-the-badge&logoColor=white)]()
[![Cipher](https://img.shields.io/badge/Cipher-Feistel4-fa646b?style=for-the-badge&logoColor=white)]()

**Procesador VLIW con ISA propia y una unidad criptográfica Feistel4**

</div>

PORYGON es un procesador VLIW de 32 bits implementado en SystemVerilog. Su ISA propia organiza las instrucciones en bundles de 64 bits, con cuatro slots de 16 bits y asignación flexible de unidades funcionales.

Incluye un pipeline de cuatro etapas, ocho registros de propósito general, unidades aritméticas, acceso a memoria, saltos y una unidad criptográfica Feistel4 con bóveda de llaves. El repositorio reúne el RTL, las memorias de instrucciones y datos, los testbenches y las herramientas para cargar archivos y recuperar los resultados de la simulación.

Se integra con [PIPER-COMPILER](https://github.com/luisfeliTEC-0603/PIPER-COMPILER), que genera, ensambla y calendariza los programas para su ejecución en PORYGON.

## Estructura

| Ruta | Contenido |
|------|-----------|
| `rtl/` | Paquete compartido y conexión del sistema |
| `rtl/core/` | Pipeline, registros, unidades funcionales, decode y criptografía |
| `rtl/memory/` | Memorias de instrucciones y datos |
| `tests/unit/` | Testbenches de componentes |
| `tests/integration/` | Testbenches del sistema completo |
| `tests/programs/` | Programas, datos de entrada y resultados de referencia |
| `tests/tools/` | Pruebas de carga y extracción |
| `tools/` | Script de simulación y herramientas de memoria en `memory/` |
| `docs/` | ISA, microarquitectura, simulación e integración con el compilador |
| `build/` | Simuladores, ondas y resultados generados |
| `Makefile` | Compilación, ejecución y limpieza |

## Instalación

Requiere **Icarus Verilog** (`iverilog` y `vvp`), **GNU Make**, **Bash** y **Python 3**. GTKWave es opcional para visualizar las ondas de simulación.

Desde la raíz del repositorio, con las herramientas instaladas, compilar el sistema:

```bash
make elaborate
```

Los programas `.mem` incluidos se pueden ejecutar sin instalar el compilador Piper.

## Ejecución

Ejecutar las pruebas básicas de ALU, SuperALU e integración del procesador:

```bash
make sim
```

Para ejecutar un programa, indicar su imagen de instrucciones y, opcionalmente, su imagen de datos:

```bash
make sim PROG=programa.mem DATA=datos.mem
```

Por ejemplo, el caso Feistel4 de texto corto incluido en el repositorio:

```bash
make sim PROG=tests/programs/feistel4/kit_texto_corto.mem \
  DATA=tests/programs/feistel4/kit_texto_corto_datos.mem
```

Los registros finales, el volcado de memoria, las ondas y los logs se guardan en `build/sim/<programa>/`. El script `tools/sim.sh` permite configurar límites de ciclos, directorios de salida y valores esperados.

### Carga y extracción de archivos

Convertir un archivo a una imagen de memoria de datos:

```bash
mkdir -p build
python3 tools/memory/load_file.py --input archivo.bin \
  --output build/datos.mem --address 0x10000
```

Después de ejecutar el ejemplo Feistel4, recuperar el texto descifrado:

```bash
./tools/memory/extract.sh kit_texto_corto 0x14000 21 texto_recuperado.txt
```

El archivo queda en `build/sim/kit_texto_corto/`. `make clean` elimina el contenido generado en `build/`.

## Documentación

- [Descripción del proyecto](docs/project-description.md)
- [ISA](docs/isa.md)
- [Microarquitectura](docs/microarchitecture.md)
- [Guía de simulación](docs/simulation.md)
- [Integración con PIPER-COMPILER](docs/compiler-integration.md)
- [Programas y ejemplos Feistel4](tests/programs/feistel4/README.md)

## TODO — Proyecto 2: implementación de jerarquía de memoria

- [ ] Diseñar la jerarquía de memoria y definir sus parámetros e interfaces.
- [ ] Implementar los módulos y controladores de memoria caché.
- [ ] Integrar la jerarquía con el procesador y adaptar el manejo de las latencias de acceso.
- [ ] Incorporar pruebas para verificar el funcionamiento del sistema de memoria.
- [ ] Evaluar el rendimiento y documentar la arquitectura y los resultados.
