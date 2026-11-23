# PORYGON

<img src="docs/imgs/porygon.png" alt="PORYGON" width="140">

PORYGON es un procesador VLIW de 32 bits con ISA propia, implementado en SystemVerilog para el curso CE4301 Arquitectura de Computadores I. Ejecuta *bundles* de 64 bits con cuatro slots de 16 bits en un pipeline de cuatro etapas. Cuenta con ocho registros de propósito general, unidades aritméticas, de saltos y de acceso a memoria, y una unidad Feistel4 con bóveda de llaves.

El Proyecto II incorpora una jerarquía exclusiva de datos con L1-D de 4 KiB, L2 de 16 KiB y RAM de 64 KiB. Los contadores permiten medir cómo cambia el tiempo de ejecución al variar el patrón de acceso y comparar el mismo programa con una referencia sin caché.

## Requisitos y compilación

Se necesitan Icarus Verilog (`iverilog` y `vvp`), GNU Make, Bash y Python 3. GTKWave es opcional para ver las formas de onda. Las imágenes de instrucciones incluidas se pueden ejecutar directamente. Todos los comandos siguientes parten de la raíz de PORYGON.

```bash
make elaborate   # Compila y elabora el sistema con Icarus Verilog
make sim         # Ejecuta la prueba de integración predeterminada
```

## Ejecutar un benchmark

El microbenchmark recorre 4096 nodos de una lista enlazada y acumula sus direcciones. La imagen de instrucciones define el recorrido y la imagen de datos determina el orden de las visitas. El siguiente comando ejecuta el patrón secuencial con caché y comprueba que el registro `r1` contenga la suma esperada.

```bash
bench=tests/programs/benchmarks
./tools/sim.sh "$bench/mem_microbenchmark.mem" \
  --data "$bench/secuencial_datos.mem" --out build/sim/secuencial \
  --max-cycles 400000 --expect r1=301981696 --expect errors=0
```

La evaluación completa se reproduce con el siguiente comando.

```bash
make bench
```

Este comando regenera las imágenes y ejecuta seis simulaciones. Prueba los recorridos secuencial, con salto de ocho palabras y aleatorio, cada uno con y sin caché. Comprueba la misma suma final en las seis corridas, imprime una tabla comparativa y guarda los resultados por caso en `build/bench/`. La [evaluación de rendimiento](docs/performance.md) explica los patrones y los resultados.

## Ejecutar un programa propio

El simulador recibe una imagen hexadecimal de instrucciones (`PROG`, un bundle por línea). Si el programa necesita datos iniciales, se agrega una segunda imagen (`DATA`, organizada por bytes).

```bash
make sim PROG=programa.mem DATA=datos.mem MAX_CYCLES=400000
```

Se puede omitir `DATA` si el programa inicializa sus datos. La opción `NO_CACHE=1` selecciona la referencia sin caché. Por defecto, las salidas quedan en `build/sim/<nombre-del-programa>/`.

La variable `PIPER` debe apuntar al repositorio local de [PIPER-COMPILER](https://github.com/luisfeliTEC-0603/PIPER-COMPILER). Una vez compiladas las herramientas, se utiliza uno de los dos comandos según el formato del archivo fuente. Los programas Piper se compilan con `pipoc` y los programas en ASM lineal se procesan con `porygon-schedule`.

```bash
PIPER=/ruta/a/PIPER-COMPILER
make -C "$PIPER" all
mkdir -p build
# Desde Piper
"$PIPER/bin/pipoc" mem programa.rwt -o build/programa.mem
# Desde ASM lineal
"$PIPER/bin/porygon-schedule" programa.asm build/programa.bundles build/programa.mem
```

En ambos casos, la imagen generada se ejecuta con `make sim PROG=build/programa.mem`.

### Cargar datos y recuperar memoria

La herramienta `load_file.py` convierte un archivo binario en una imagen de datos para la dirección inicial que espera el programa. En este ejemplo, la entrada se carga en `0x10000`. Tras la simulación, se extraen cuatro bytes a partir de esa dirección y se muestran en hexadecimal.

```bash
mkdir -p build
python3 tools/memory/load_file.py --input entrada.bin --output build/datos.mem --address 0x10000
make sim PROG=build/programa.mem DATA=build/datos.mem
python3 tools/memory/extract_data.py --memory build/sim/programa/memory.dump.mem \
  --address 0x10000 --size 4 --output build/resultado.bin
od -An -tx1 build/resultado.bin
```

La dirección de extracción y la cantidad de bytes dependen de la ubicación y del tamaño del resultado en memoria. Si el programa devuelve el resultado en un registro, su valor final se puede consultar en `results.txt`.

## Leer los resultados

Al finalizar una simulación exitosa, la terminal muestra el estado y los registros, seguidos de un cuadro con los ciclos, las instrucciones completadas, el IPC, los ciclos de espera por memoria, las tasas de acierto y el AMAT observado. Las tasas se muestran como porcentajes y los valores que no aplican aparecen como `N/A`.

| Archivo de cada corrida | Qué consultar |
| --- | --- |
| `results.txt` | Estado de terminación, errores y valores finales de los registros. |
| `memory.dump.mem` | Imagen final de la memoria de datos, incluidas las modificaciones pendientes en la jerarquía. |
| `metrics.txt` | Contadores en formato `clave=valor`, entre ellos ciclos, instrucciones, esperas y accesos a memoria. |
| `indicators.json` | Indicadores derivados, incluidos IPC, tasas de acierto y AMAT (latencia media observada por acceso a datos). |
| `waves.vcd` | Señales de la simulación para inspeccionar en GTKWave. |

El siguiente comando muestra en la terminal los indicadores del ejemplo secuencial.

```bash
python3 tools/metrics/indicators.py --input build/sim/secuencial/metrics.txt --format texto
```

A igual frecuencia, la corrida con menos ciclos termina antes. El IPC indica cuántas instrucciones se completaron por ciclo. Las esperas por memoria y el AMAT ayudan a explicar la diferencia entre las corridas con y sin caché.

## Estructura del repositorio

| Ruta | Contenido |
| --- | --- |
| [rtl/core/](rtl/core/) | Pipeline, registros y unidades funcionales. |
| [rtl/memory/](rtl/memory/) | Memoria de instrucciones, cachés, buffers, controlador y RAM. |
| [rtl/metrics/](rtl/metrics/) | Eventos y contadores de rendimiento. |
| [rtl/porygon_system.sv](rtl/porygon_system.sv) | Integración del procesador con el subsistema de memoria. |
| [tests/](tests/) | Pruebas unitarias y de integración, programas, datos y benchmarks. |
| [tools/](tools/) | Simulación, conversión de imágenes de memoria y análisis de métricas. |
| [Makefile](Makefile) | Compilación, simulación, pruebas y benchmarks. |
| [docs/](docs/) | Documentación de diseño y resultados. |

## Documentación

| Documento | Pregunta que responde |
| --- | --- |
| [Organización y microarquitectura](docs/microarchitecture.md) | ¿Cómo se conectan el pipeline, las unidades funcionales y la memoria? |
| [Jerarquía de memoria](docs/memory-hierarchy.md) | ¿Cómo se resuelven aciertos, fallos, reemplazos y escrituras pendientes? |
| [Evaluación de rendimiento](docs/performance.md) | ¿Cómo cambian los ciclos, el IPC y el AMAT según el patrón de acceso? |
| [Guías por módulo](docs/modulos/) | ¿Cómo funcionan internamente L1-D, L2, los buffers y el controlador? |
| [ISA](docs/isa.md) | ¿Cómo se codifican y agrupan las instrucciones? |
| [Simulación](docs/simulation.md) | ¿Cómo se modela y verifica el sistema? |
| [Integración con el compilador](docs/compiler-integration.md) | ¿Cómo llega un programa Piper al procesador? |
| [Ejemplos Feistel4](tests/programs/feistel4/README.md) | ¿Cómo se procesan y recuperan archivos con la unidad criptográfica? |
