# Evaluación de rendimiento de PORYGON

## Método

Se compararon seis ejecuciones de la misma imagen VLIW, [mem_microbenchmark.mem](../tests/programs/benchmarks/mem_microbenchmark.mem): tres patrones de lectura, cada uno con la jerarquía L1-D/L2 y con la referencia sin caché. El programa visita una vez cada uno de los 4096 nodos de 4 bytes de una lista enlazada. Se varió el orden de visita: consecutivo, salto de ocho palabras (*stride*) y permutación aleatoria con semilla `20261116`.

La CPU opera a 100 MHz y la RAM a 50 MHz. Una línea de 32 bytes tarda 39 ciclos de CPU en transferirse. Cada corrida comienza con cachés vacías y se mide desde el arranque hasta completar el marcador de terminación y las operaciones anteriores. Las seis finalizaron con `r1 = 0x11FFE000`, sin errores ni saturación de contadores. [Configuración de la jerarquía](memory-hierarchy.md) · [Contadores exportados por la simulación](../tests/support/metrics_export.svh)

## Procesador

| Configuración | Ciclos | Instrucciones | IPC | Espera por memoria (ciclos) | Aceleración |
|---|---:|---:|---:|---:|---:|
| Secuencial con caché | 73 745 | 16 390 | 0,2223 | 24 575 | 2,888× |
| Stride con caché | 102 417 | 16 390 | 0,1600 | 53 247 | 2,080× |
| Aleatorio con caché | 95 233 | 16 390 | 0,1721 | 46 063 | 2,237× |
| Sin caché, cada patrón | 213 009 | 16 390 | 0,0769 | 163 839 | 1,000× |

El programa ejecuta **49 168 bundles** en cada configuración (15 de inicio, 12 por iteración y uno de terminación). De ellos, **8192** son bundles NOP de retardo de salto, dos por iteración. Estos valores se derivan del [generador del microbenchmark de memoria](../tests/programs/benchmarks/mem_microbenchmark.py). El IPC divide instrucciones completadas entre ciclos totales. La aceleración divide los ciclos sin caché entre los ciclos con caché para el mismo patrón.

## Cachés y memoria principal

Cada corrida realiza 4096 lecturas de datos y cero escrituras. Con caché, L1-D registra 4096 accesos de lectura y cero accesos, hits y misses de escritura. Las tasas de escritura quedan sin denominador. L2 recibe una demanda por cada miss de L1-D en estas pruebas.

| Patrón con caché | L1 hits / misses | L1 hit / miss (%) | Demandas L2 | L2 hits / misses | L2 hit / miss (%) |
|---|---:|---:|---:|---:|---:|
| Secuencial | 3584 / 512 | 87,5 / 12,5 | 512 | 0 / 512 | 0,0 / 100,0 |
| Stride | 0 / 4096 | 0,0 / 100,0 | 4096 | 3584 / 512 | 87,5 / 12,5 |
| Aleatorio | 898 / 3198 | 21,9 / 78,1 | 3198 | 2686 / 512 | 84,0 / 16,0 |

| Configuración | AMAT observado (ciclos/acceso) | RAM: lecturas / escrituras | Ciclos de transferencia¹ | Utilización del ancho de banda máximo |
|---|---:|---:|---:|---:|
| Secuencial con caché | 7,00 | 512 / 0 | 19 968 | 11,11 % |
| Stride con caché | 14,00 | 512 / 0 | 19 968 | 8,00 % |
| Aleatorio con caché | 12,25 | 512 / 0 | 19 968 | 8,60 % |
| Sin caché, cada patrón | 41,00 | 4096 / 0 | 159 744 | 30,77 % |

¹ Accesos a RAM × 39 ciclos por línea. El AMAT incluye la espera observada por la LSU. La utilización expresa las palabras transferidas como porcentaje de las que el bus podría mover durante la ejecución.

**Resultado.** El recorrido secuencial aprovecha ocho palabras por línea y obtiene la mayor aceleración. El stride pierde todos los accesos en L1, pero L2 resuelve 3584 de esas demandas. Ambos patrones leen 512 líneas de RAM. Los **28 672 ciclos** adicionales del stride corresponden a esas 3584 consultas resueltas en L2 a ocho ciclos cada una. La carga de solo lectura permite evaluar localidad y reemplazo; el costo de escribir líneas sucias queda fuera de esta medición.

## Impacto del compilador en el procesador

En una prueba independiente se mantuvo fija la jerarquía y se compiló el mismo programa con PIPER (`1711309`). El bucle sumó los enteros de 0 a 4, conservó una asignación sin uso en el fuente y pasó la suma a una rutina de seis argumentos. Cada variante ejecutable devolvió `r1 = 25`. El scheduler estuvo activo en todas las corridas y se permitió spilling, necesario para esta llamada.

| Configuración | Ciclos | Bundles | Instrucciones | IPC | Espera por memoria (ciclos) | AMAT (ciclos/acceso) |
|---|---:|---:|---:|---:|---:|---:|
| Base | 710 | 517 | 287 | 0,404 | 191 | 3,62 |
| DCE | 702 | 511 | 284 | 0,405 | 189 | 3,63 |
| Unrolling ×2 | 656 | 463 | 254 | 0,387 | 191 | 3,73 |
| Unrolling ×2 + DCE | 642 | 451 | 248 | 0,386 | 189 | 3,82 |

La combinación redujo el tiempo un **9,6 %** respecto a la base. De los 68 ciclos ahorrados, 2 corresponden a espera por memoria. Las cuatro configuraciones tuvieron cuatro misses de L1 y cuatro de L2.

## Reproducción de los patrones de acceso

Desde la raíz de PORYGON, `make bench` genera las entradas, ejecuta las seis simulaciones, comprueba el resultado y presenta la comparación. Cada corrida guarda sus contadores en `build/bench/<caso>/metrics.txt` y sus indicadores en `indicators.json`.
