# Skeletons de la jerarquía

## 1. Estructura

Los skeletons concretan [Interfaces](interfaces.md) y [Métricas](metrics.md)
mediante parámetros, puertos y comentarios `/** ... */` estilo JavaDoc/Doxygen.
Los cuerpos de los componentes quedan pendientes de sus issues; sus salidas
todavía no tienen comportamiento funcional. El wrapper contiene conexiones y
metadatos constantes de configuración.

| Archivo | Contrato | Issue |
| --- | --- | --- |
| [pkg_memory.sv](../../rtl/memory/pkg_memory.sv) | Tipos de dirección, palabra y línea; fuentes de retorno, valores por defecto y cálculo de anchos. | P2-02 |
| [pkg_metrics.sv](../../rtl/metrics/pkg_metrics.sv) | Eventos, estados, contadores crudos e instantánea. | P2-02 |
| [cache_l1.sv](../../rtl/memory/cache_l1.sv) | CPU–L1, víctimas, consulta WB, demandas L2 y recepción de línea. | P2-06 |
| [write_buffer.sv](../../rtl/memory/write_buffer.sv) | Encolado, forwarding y drenado con confirmación identificada. | P2-05 |
| [cache_l2.sv](../../rtl/memory/cache_l2.sv) | Demandas, instalaciones, desalojos y observación del retorno de memoria. | P2-07, P2-08 |
| [eviction_buffer.sv](../../rtl/memory/eviction_buffer.sv) | Víctimas sucias, búsqueda RAW y escritura hasta confirmación. | P2-04 |
| [memory_controller.sv](../../rtl/memory/memory_controller.sv) | Bursts, arbitraje, tiempos, cruce de relojes y timeout. | P2-03 |
| [main_memory.sv](../../rtl/memory/main_memory.sv) | Almacenamiento por palabra de 32 bits en el dominio de memoria. | P2-03 |
| [line_return.sv](../../rtl/memory/line_return.sv) | Selección WB/L2/memoria y propagación de `ready` hacia el origen. | P2-11 |
| [performance_counters.sv](../../rtl/metrics/performance_counters.sv) | Observación de eventos y conservación de contadores. | P2-10 |
| [data_memory_hierarchy.sv](../../rtl/memory/data_memory_hierarchy.sv) | Conexión estructural de los componentes anteriores. | P2-11 |

`porygon_system`, el núcleo y las memorias existentes conservan su implementación.
La conexión de la CPU al wrapper nuevo corresponde a los issues de integración.
Los archivos nuevos quedan fuera del flujo de construcción actual.

## 2. Paquetes y parámetros

El orden de dependencias de fuentes es `pkg_vliw.sv`, `pkg_memory.sv`,
`pkg_metrics.sv`, componentes y finalmente el wrapper. Los puertos usan tipos
calificados de paquete y nombres explícitos con `_i` y `_o` desde cada módulo.

`pkg_memory` conserva la dirección y palabra del paquete del procesador. La
línea tiene 256 bits y el byte `base+k` ocupa `[8*k +: 8]`. `id_width(N)` calcula
`max(1, ceil(log2(N)))`; se usa con `L2_MAX_INFLIGHT` para lecturas e
instalaciones, y con `EVICTION_BUFFER_DEPTH` para escrituras.

El wrapper propaga las profundidades, el límite L2 y los parámetros de memoria
a todos sus consumidores. Los tamaños, vías y políticas de las cachés siguen
[Jerarquía](hierarchy.md). La configuración exportada describe esta jerarquía
con ambas cachés; la referencia sin caché se prepara en P2-12.

## 3. Conexiones y relojes

`data_memory_hierarchy` conecta las siete interfaces acordadas. El retorno de
memoria llega a `line_return` y L1; L2 observa los mismos `valid`, `ready`, `id`,
base y error para finalizar su demanda. El selector conserva los campos del
origen; fija id/error a cero para WB y dirty a cero para memoria.

La frontera interna controlador–almacenamiento usa dirección física alineada,
habilitador de lectura, máscara de escritura de cuatro bytes, dato de 32 bits,
respuesta de lectura síncrona y diagnóstico de rango. El arreglo atiende una
palabra por ciclo de memoria. La escritura se hace efectiva en el flanco con
máscara activa; no necesita confirmación adicional del arreglo.

El controlador genera `ram_clk` y `ram_rst_n` para `main_memory`, programa las
palabras del burst y realiza el cruce de dominios. Los 25 ciclos iniciales y
los 39 ciclos de línea completa incluyen esta frontera y el CDC. Una respuesta
inválida del arreglo se trata en el controlador antes de completar el burst.
El almacenamiento puede reutilizar `memory_sp_ram` al implementar P2-03.

## 4. Concreción de métricas

Cada componente entrega una estructura `perf_events_o` con eventos independientes
y muestras de estado. El núcleo adaptado entrega `cpu_events_i` al wrapper.
`dmem_rsp_origin_o` es un sideband de observación para que ese productor pueda
etiquetar la finalización de una demanda; no modifica el contrato funcional de
palabra CPU–L1. `line_return` expone su error local por separado.

`fill_source_t` mantiene la codificación de retorno de `interfaces.md`.
`demand_origin_t` identifica el origen de la respuesta CPU y añade L1,
referencia sin caché y error; ambas enumeraciones tienen funciones distintas.

| Estructura | Campos principales |
| --- | --- |
| `cpu_events_t` | Deltas `done_*`, máscaras de IF/ID/EX/WB, stall y causa, saltos, retardo, inicio y fin de demanda. |
| `l1_events_t` | Aceptación y clasificación, víctima entregada a WB y error local. |
| `l2_events_t` | `get_accept`, `get_done`, resultado de búsqueda, promociones, descartes, víctimas y ocupación. |
| `wb_events_t` | Encolado, forwarding, aceptación y confirmación de instalación, ocupación y esperas. |
| `eb_events_t` | Encolado, aceptación y confirmación de escritura, ocupación y esperas. |
| `mem_events_t` | Aceptación, palabra y disponibilidad de resultado, consumo de respuestas, estados y operaciones pendientes. |

Los identificadores funcionales conservan su ancho derivado. Los campos de
eventos los extienden con ceros a 32 bits. Las ocupaciones usan 32 bits; los
deltas de finalización CPU usan ocho bits para admitir varias finalizaciones
en un flanco. Los contadores y acumuladores de la instantánea usan 64 bits.

`snapshot_t` agrupa configuración, contadores `cpu`, `dmem`, `l1`, `l2`, `wb`,
`eb`, `mem`, errores y trabajo pendiente. Por ejemplo, `cpu.cycles` corresponde
a `cpu_cycles` y `mem.read_words` a `mem_read_words` de `metrics.md`. Las
latencias y los conteos de demandas correctas tienen también desglose por tipo.

`get_done` concreta la entrega de resultado a L1; los indicadores de consumo de
respuesta concretan los handshakes de retorno del controlador. Permiten
determinar el trabajo pendiente después de incorporar los eventos de cierre.
La propagación de un error de respuesta no genera otro error de detección:
cada bloque emite `error_event_t` para los fallos que detecta localmente.
