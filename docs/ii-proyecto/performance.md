# Evaluación de rendimiento

**Estado:** resultados medidos sobre el sistema integrado.

## 1. Propósito

Compara la jerarquía de caché contra la referencia sin caché usando tres
patrones de acceso, y relaciona las métricas observadas con los mecanismos que
las producen. Las fórmulas y las reglas de conteo son las del
[contrato de métricas](metrics.md); la geometría es la de
[Jerarquía](hierarchy.md).

## 2. Metodología

Las seis mediciones usan la **misma imagen de programa**, el mismo número de
accesos y los mismos parámetros de memoria. Lo único que cambia entre las tres
primeras es el orden de los accesos, y entre esas y las otras tres, la presencia
de la jerarquía. Cualquier diferencia de métricas es por tanto atribuible al
patrón de acceso o a la jerarquía, no a la carga.

- La ventana de medición empieza antes del primer fetch, con cachés y buffers
  vacíos, e incluye la inicialización por software y el llenado del pipeline.
  Cierra cuando el marcador de terminación ha completado todas las operaciones
  anteriores, según [Métricas §2](metrics.md#2-periodo-de-medición).
- Los contadores crudos se exportan con `tests/support/metrics_export.svh` y se
  reducen a indicadores con `tools/metrics/indicators.py`. Las comparaciones se
  arman con `tools/metrics/compare.py`.
- Ninguna de las seis mediciones terminó con error ni con overflow, así que las
  seis son comparables.

## 3. Carga de trabajo

El programa recorre una **lista enlazada** de 4096 nodos de 4 B — 16 KiB en
total, exactamente el tamaño de L2 — donde cada nodo guarda la dirección
absoluta de su sucesor. El bucle son 12 bundles:

```text
low  r3, 0(r3)      ; r3 = mem[r3], el siguiente nodo
sum  r1, r3         ; acumula la dirección visitada
sum  r4, #-1        ; accesos restantes
jnz  r4, inicio     ; con sus dos bundles de retardo
```

Un solo acceso a memoria por iteración, y el puntero **depende del dato
cargado**, así que no existe forma de adelantar el acceso siguiente. El
acumulador `r1` da un resultado verificable.

Los tres patrones son **permutaciones del mismo conjunto**: los tres visitan los
4096 nodos exactamente una vez.

| Patrón | Orden de visita | Localidad esperada |
| --- | --- | --- |
| secuencial | 0, 1, 2, … 4095 | ocho nodos por línea de 32 B |
| stride | 0, 8, 16, … 4088, luego 1, 9, 17, … | un nodo por línea; 512 líneas |
| aleatorio | permutación con semilla 20261116 | mismo conjunto, sin orden aprovechable |

Como los tres recorren el conjunto completo, el resultado esperado es **idéntico
en los tres**: `r1 = 301981696` (`0x11FFE000`). Eso sirve de verificación
cruzada: una corrida que dé otro valor se descarrió y sus métricas no valen.

Las imágenes se generan con `tests/programs/benchmarks/gen_benchmarks.py`, que
fija la semilla y comprueba que cada orden sea una permutación antes de
escribirla.

## 4. Configuración medida

| Parámetro | Valor |
| --- | --- |
| L1-D | 4 KiB, 2 vías, línea de 32 B (128 líneas, 64 conjuntos) |
| L2 | 16 KiB, 4 vías, línea de 32 B (512 líneas, 128 conjuntos) |
| Relación entre niveles | exclusiva |
| Write buffer / eviction buffer | 4 / 8 entradas |
| Operaciones L2 en vuelo | 4 |
| Memoria | divisor de reloj 2, primera palabra 25 ciclos |
| CPU | 100 MHz |

De ahí, el tiempo de una línea completa es
`Tread = 25 + 7 × 2 = 39` ciclos de CPU.

## 5. Resultados

| Métrica | secuencial | stride | aleatorio | sin caché |
| --- | --- | --- | --- | --- |
| ciclos | 73 745 | 102 417 | 95 233 | 213 009 |
| instrucciones | 16 390 | 16 390 | 16 390 | 16 390 |
| ciclos de stall | 24 575 | 53 247 | 46 063 | 163 839 |
| IPC | 0,2223 | 0,1600 | 0,1721 | 0,0769 |
| hit rate L1 (lectura) | 0,8750 | 0,0000 | 0,2192 | N/A |
| hit rate L2 | 0,0000 | 0,8750 | 0,8399 | N/A |
| AMAT observado | 7,00 | 14,00 | 12,25 | 41,00 |
| AMAT de referencia | 6,875 | 13,875 | 12,12 | N/A |
| fallas L1 | 512 | 4096 | 3198 | 0 |
| demandas L2 | 512 | 4096 | 3198 | 0 |
| aciertos L2 | 0 | 3584 | 2686 | 0 |
| fallas L2 | 512 | 512 | 512 | 0 |
| lecturas a memoria | 512 | 512 | 512 | 4096 |
| palabras leídas | 4096 | 4096 | 4096 | 32 768 |
| utilización de ancho de banda | 0,1111 | 0,0800 | 0,0860 | 0,3077 |
| tiempo en transferencia | 0,2708 | 0,1950 | 0,2097 | 0,7499 |
| **speedup contra sin caché** | **2,888×** | **2,080×** | **2,237×** | 1,000× |

## 6. Análisis

### 6.1 La localidad explica todo el rango de ciclos

Las tres corridas con jerarquía ejecutan las **mismas 16 390 instrucciones**.
Toda la diferencia de ciclos está en los stalls por memoria: 24 575, 53 247 y
46 063. Es decir, el patrón de acceso no cambia el trabajo hecho, solo cuánto
espera el procesador.

El secuencial da exactamente **7/8 de aciertos en L1**. Con nodos de 4 B y
líneas de 32 B entran ocho nodos por línea: la primera referencia a cada línea
falla y las siete siguientes aciertan. El contador lo confirma: 512 fallas, una
por cada una de las 512 líneas del arreglo.

### 6.2 El stride es el peor caso, y no por casualidad

El stride da **cero aciertos en L1**. Cada acceso cae en una línea distinta y el
recorrido toca las 512 líneas del arreglo antes de volver a la primera, mientras
que en L1 solo caben 128. Cuando el recorrido regresa, la línea ya fue
desalojada. Es el caso patológico de una caché con reemplazo por recencia: el
conjunto de trabajo excede la capacidad y el orden de acceso garantiza que
ninguna línea sobreviva hasta su reuso.

L2 sí lo absorbe: con 512 líneas y capacidad para exactamente 512, el hit rate
de L2 es **0,875**, que es `3584/4096`. Las 512 fallas restantes son las
obligatorias de la primera pasada.

El aleatorio queda en medio con 0,2192 de aciertos en L1. Con 4096 accesos sobre
512 líneas, cada línea se toca ocho veces en promedio, y a veces dos de esas
visitas caen lo bastante cerca en el tiempo como para encontrarla todavía
residente. El stride nunca tiene esa suerte porque su distancia de reuso es
constante y máxima.

### 6.3 El desglose de stalls aísla dónde se fue el tiempo

Los ciclos de espera por miss se reparten según el nivel que resolvió cada
demanda:

| Origen | secuencial | stride | aleatorio |
| --- | --- | --- | --- |
| resuelto en L2 | 0 | 28 672 | 21 488 |
| resuelto en memoria | 24 575 | 24 575 | 24 575 |

La parte de memoria es **idéntica en los tres**, porque los tres hacen las mismas
512 lecturas de línea completa. Lo que separa al stride del secuencial son
exclusivamente los 28 672 ciclos que pasa esperando a L2, y eso es consecuencia
directa de haber perdido L1.

### 6.4 La fórmula analítica predice el AMAT medido

`metrics.md` §7 da una referencia sin forwarding ni contención:

```text
AMAT_referencia = 1 + MR_L1 × (8 + MR_L2 × Tread)
```

Contra el AMAT observado:

| Patrón | Predicho | Observado | Diferencia |
| --- | --- | --- | --- |
| secuencial | 6,875 | 7,000 | 0,125 |
| stride | 13,875 | 14,000 | 0,125 |
| aleatorio | 12,121 | 12,246 | 0,125 |

La diferencia es constante y de un octavo de ciclo. Corresponde al ciclo de
consumo de la respuesta, que la fórmula no modela: el AMAT observado mide de la
primera presentación en EX hasta consumir la respuesta, mientras que la fórmula
cuenta solo el tiempo de servicio. Que el error sea constante y menor a un
ciclo valida a la vez el hardware y la fórmula.

### 6.5 El costo de la relación exclusiva aparece sin una sola escritura

El programa no escribe memoria: `l1_writes` es 0 y `l1_evictions_dirty` también.
Y sin embargo `wb_enqueued` vale 384, 3968 y 3070. Son **víctimas limpias**
bajando de L1 al write buffer.

Eso es la exclusividad hecha visible: como una línea no puede residir en ambos
niveles, toda línea desalojada de L1 debe escribirse a L2 aunque esté limpia, o
se perdería. Una jerarquía inclusiva descartaría esas víctimas sin tráfico
alguno. El contrapeso está en `l2_promotions` — 0, 3584 y 2686 — que son las
líneas que suben de L2 a L1 y se retiran de L2 al promoverse.

### 6.6 La referencia sin caché paga ocho veces el tráfico

Las tres corridas sin caché dan **exactamente 213 009 ciclos**, idénticas entre
sí. Era lo esperable: sin caché no hay localidad que aprovechar, así que el
orden de los accesos deja de importar. Esa insensibilidad al patrón es en sí
misma la evidencia de que lo que mejora la jerarquía es precisamente la
explotación de la localidad.

El dato más revelador son las palabras transferidas: **32 768 contra 4096**. La
referencia hace 4096 lecturas de línea completa, una por cada palabra pedida, y
descarta las otras siete. De ahí que su fracción de tiempo en transferencia sea
0,75 contra 0,20–0,27 con jerarquía: tres cuartas partes de la ejecución están
ocupadas moviendo datos por el bus.

Y de ahí también la lectura correcta de la utilización de ancho de banda: la
referencia **usa más ancho de banda** (0,3077 contra 0,08–0,11) y aun así es dos
a tres veces más lenta. Mayor utilización no es mejor rendimiento cuando lo que
se transfiere se descarta.

## 7. Lo que esta carga no ejercita

Importa decirlo, porque limita las conclusiones:

- **Escrituras.** El programa es de solo lectura, así que no hay líneas sucias,
  el eviction buffer nunca se usa (`eb_enqueued = 0`) y el write buffer solo
  transporta víctimas limpias. Las políticas de escritura no están evaluadas.
- **Forwarding del write buffer.** `wb_forwarded = 0` en las tres: nunca se
  vuelve a leer una línea mientras espera en el buffer.
- **Presión de buffers y de L2.** `l2_inflight_max` es 2 de una capacidad de 4,
  y `l2_full_cycles` y `l2_get_wait_cycles` son 0. La LSU mantiene una sola
  demanda pendiente, así que la jerarquía nunca recibe suficientes operaciones
  simultáneas para saturarse. Medir esa dimensión exige una carga con varias
  demandas en vuelo, que la LSU actual no permite.

Un benchmark de escritura con reuso cerraría las dos primeras brechas con el
mismo esquema de lista enlazada.

## 8. Reproducción

```bash
python3 tests/programs/benchmarks/gen_benchmarks.py

for p in secuencial stride aleatorio; do
  ./tools/sim.sh tests/programs/benchmarks/patron.mem \
    --data tests/programs/benchmarks/${p}_datos.mem \
    --max-cycles 400000 --expect r1=301981696 --expect errors=0 \
    --out build/bench/${p}
  ./tools/sim.sh tests/programs/benchmarks/patron.mem \
    --data tests/programs/benchmarks/${p}_datos.mem --no-cache \
    --max-cycles 600000 --expect r1=301981696 --expect errors=0 \
    --out build/bench/${p}_sincache
done

python3 tools/metrics/compare.py \
  secuencial=build/bench/secuencial/indicators.json \
  stride=build/bench/stride/indicators.json \
  aleatorio=build/bench/aleatorio/indicators.json \
  sin-cache=build/bench/secuencial_sincache/indicators.json \
  --baseline sin-cache --format markdown
```

El generador fija la semilla, así que las imágenes de datos se reproducen
exactas. Los `--expect` hacen fallar la corrida antes de que sus métricas puedan
usarse si el programa no llegó al resultado correcto.
