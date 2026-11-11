# Contrato de métricas

**Estado:** propuesta de diseño.

## 1. Propósito

Define eventos, contadores y reglas para medir CPU, cachés, buffers y memoria.
Complementa [Jerarquía](hierarchy.md), [Contrato CPU–memoria](cpu-memory-contract.md)
e [Interfaces](interfaces.md), y concreta el
[contrato de métricas P2-01](https://github.com/luisfeliTEC-0603/PORYGON/issues/28).

Los bloques exponen hechos observables. El módulo de métricas los cuenta en el
reloj de CPU y conserva los resultados; no controla solicitudes, `ready`,
reservas ni el avance de las FSM. Las fórmulas se calculan a partir de los
contadores exportados.

Los tipos de eventos y la instantánea se concretan en los
[skeletons RTL](skeletons.md).

## 2. Periodo de medición

| Control | Comportamiento |
| --- | --- |
| Reset | Borra contadores, estado de seguimiento y marcas de error; deja la medición inactiva. |
| `perf_start` | Pulso que borra resultados e inicia una medición antes del primer ciclo de fetch. Se acepta con medición inactiva y sin operaciones pendientes. |
| `perf_stop` | Pulso que incluye el último ciclo y sus eventos, y después congela los resultados. |
| `perf_running` | Indica que la ventana de medición está activa. No depende del stall de CPU. |

Si `perf_start` se acepta en `E0` y `perf_stop` en `EN`, se cuentan los `N`
ciclos entre ambos flancos y los eventos de `E1` a `EN`. Reset tiene prioridad;
el flanco de inicio solo prepara la medición. Un nuevo inicio requiere terminar
la medición anterior. Estos controles pertenecen al entorno de ejecución.

La medición de referencia comienza con cachés y buffers vacíos, y las mismas
imágenes de programa y datos. Incluye inicialización por software y llenado del
pipeline. El final se reconoce mediante el salto de terminación a sí mismo;
`perf_stop` se emite después de completar ese bundle y todas sus operaciones
anteriores. Los bundles posteriores al marcador quedan fuera del programa
medido. La parada y el vaciado siguen el
[contrato CPU–memoria](cpu-memory-contract.md#parada-del-programa-y-vaciado-del-pipeline):
al reconocer el marcador se detiene la admisión de bundles, se invalidan los
posteriores ya capturados y se permite completar el trabajo del programa.
Detectar el salto en EX no basta para cerrar los contadores.

Completar una operación significa haber aplicado su efecto arquitectónico o
emitido su diagnóstico de error: escritura de resultado al RF, respuesta de
store consumida, salto resuelto o instrucción criptográfica terminada. Los
bundles invalidados, incluidos los NOPs posteriores al marcador, no generan
eventos de finalización. Se siguen contando ciclos y eventos de las operaciones
del programa hasta su última finalización. `perf_stop` se
muestrea en ese último flanco, incluyendo sus eventos; si el marcador es la
última operación pendiente, puede cerrarse al completarlo. No se impone un
número fijo de ciclos adicionales ni se cambia el retardo de los saltos ordinarios.

Al cerrar pueden quedar desalojos o escrituras de fondo pendientes. Se conserva
su estado en el reporte. Recuperar datos desde líneas dirty o realizar un
drenado posterior conserva la instantánea de ejecución y se informa por
separado. Las comparaciones usan la misma política de inicio y cierre.

En la iteración 1, `tb_system` detiene su conteo al detectar el salto a sí mismo
en EX y observa las salidas tras `#1`, sin esperar explícitamente operaciones
anteriores pendientes. Para Proyecto II, el núcleo debe impedir la admisión y
ejecución de bundles posteriores al marcador; el entorno espera el vaciado
definido arriba y entonces emite `perf_stop`. Este
cambio está previsto para la integración; no está implementado por los skeletons.

## 3. Eventos y muestras

Un evento ocurre una vez y se muestrea en el flanco positivo. Las muestras de
estado describen el intervalo de CPU que termina en ese flanco. Los campos
están calificados por el evento; conservar `valid` sin handshake no lo repite.
Los nombres siguientes son lógicos para concretarlos en los skeletons.

| Evento o muestra | Origen | Campos y significado |
| --- | --- | --- |
| `cpu_done` | Núcleo | Incrementos de bundles y operaciones completados; NOPs y literales de los bundles completados. Admite varias finalizaciones en un flanco. |
| `cpu_stage` | Núcleo | Para IF, ID, EX y WB: etapa ocupada, transferencia válida y bloqueo por memoria. |
| `cpu_wait` | Control del núcleo | Congelamiento global y causa exclusiva: aceptación, miss pendiente o respuesta sin consumir. |
| `cpu_branch` | Núcleo | Operación de salto completada una vez, con indicador taken. |
| `cpu_delay` | Núcleo | Ciclo de avance de un bundle completamente NOP perteneciente a los dos bundles de retardo de un salto. |
| `dmem_begin` | LSU | Primera presentación de una demanda, antes de su aceptación; incluye lectura/escritura. |
| `dmem_done` | LSU | Consumo de respuesta; incluye error y origen final: L1, WB, L2, memoria o referencia sin caché. |
| `l1_access` | L1 | Handshake de solicitud; lectura/escritura y clasificación hit, miss o dirección inválida. |
| `l2_get_accept`, `l2_get_done`, `l2_lookup` | L2 | Aceptación y entrega del resultado a L1 con `id`; resultado de su búsqueda con el mismo `id` y hit/miss, una vez. |
| `line_move` | Caché o buffer emisor | Canal, dirección base, dirty y handshake de entrega de una línea. |
| `l2_clean_discard` | L2 | Base de una víctima limpia invalidada efectivamente, sin transferencia a EB. |
| `wb_install_accept`, `wb_install_done` | WB / L2 | Handshakes de instalación y de consumo de su confirmación, con `id`. |
| `buffer_state`, `l2_state` | Buffers / L2 | Ocupación, capacidad y solicitudes bloqueadas en sus interfaces. |
| `mem_accept` | Controlador | Handshake de solicitud; lectura/escritura, `id` y base. |
| `mem_word` | Controlador | Palabra de 32 bits transferida realmente en memoria, con tipo e identificador. |
| `mem_complete` | Controlador | Línea leída o escritura completa disponible por primera vez; tipo, `id` y error. |
| `mem_response_consumed` | Controlador | Handshake de consumo de respuesta, independiente en los canales de lectura y escritura. |
| `mem_state` | Controlador | Transferencia activa, solicitudes esperando arbitraje y respuestas disponibles sin consumir, por tipo. |
| `metric_error` | Bloque que detecta el error | Evento único de dirección, alineación, protocolo o timeout, con tipo y base/PC cuando corresponda. |

Las señales procedentes del dominio de memoria se entregan en el dominio CPU
sin pérdida ni duplicación; la medición del controlador incluye el cruce de
relojes acordado. `mem_complete` ocurre al estar disponible el resultado, aunque
su respuesta todavía espere `ready`.

Los identificadores de memoria se interpretan como `(lectura/escritura, id)`.
La LSU tiene una sola demanda pendiente, por lo que sus eventos de inicio y fin
no necesitan identificador adicional. El observador puede conservar tiempos
y asociaciones de eventos sin conocer los estados internos de los módulos.

## 4. CPU y latencia observada

| Contador | Regla de incremento |
| --- | --- |
| `cpu_cycles` | Uno por ciclo de la ventana, incluidos stalls y llenado/vaciado del pipeline. |
| `cpu_bundles` | Uno cuando un bundle completa todas sus operaciones. Incluye bundles NOP del programa medido. |
| `cpu_instructions` | Una por operación no-NOP completada. Incluye stores, saltos y criptografía; Feistel cuenta una operación aunque escriba dos registros. |
| `cpu_nop_slots`, `cpu_literal_slots` | Slots NOP y slots de literal, respectivamente, al completar su bundle. Un literal nunca cuenta como instrucción ni como NOP. |
| `cpu_stall_cycles` | Uno por ciclo de congelamiento global causado por memoria. |
| `cpu_wait_accept`, `cpu_wait_miss`, `cpu_wait_rsp` | Partición de `cpu_stall_cycles` según la causa indicada abajo. |
| `cpu_branches`, `cpu_branches_taken` | Operaciones de salto completadas y subconjunto tomado, respectivamente; una vez por operación. |
| `cpu_branch_delay_cycles` | Uno por `cpu_delay`, con avance efectivo y sin congelamiento global. |
| `stage_occupied`, `stage_transfers`, `stage_mem_stalls` | Por etapa: ciclos ocupados, transferencias válidas y ciclos ocupados bloqueados por memoria. |
| `dmem_completed`, `dmem_failed` | Respuestas consumidas correctas y fallidas, respectivamente. |
| `dmem_latency_sum` | Suma de ciclos de acceso de las demandas completadas correctamente, desglosada también por lectura/escritura. |
| `miss_stalls_wb`, `miss_stalls_l2`, `miss_stalls_mem` | Al terminar una demanda correcta, asigna sus ciclos de `cpu_wait_miss` al origen que resolvió el miss. |

La causa de un stall se elige en este orden: respuesta disponible sin consumir;
solicitud aún sin aceptar; demanda aceptada sin respuesta. El primer ciclo de
un miss aceptado que congela el núcleo pertenece a `cpu_wait_miss`. Cada ciclo
incrementa una sola causa. Las esperas de aceptación y consumo se reportan
separadas del desglose por origen del miss.

El tiempo de una demanda empieza en su primera presentación en EX y termina al
consumir su respuesta. Si ambos eventos ocurren en el mismo flanco, dura un
ciclo; en general, `latencia = flanco_fin - flanco_inicio + 1`. Incluye espera
de aceptación, atención y espera de consumo. El observador conserva el inicio
y los ciclos de miss hasta `dmem_done`.

Las finalizaciones corresponden a operaciones que completaron sus efectos o
su diagnóstico de error. Se cuenta también una operación cuyo destino sea
`r0`; los stores y saltos no requieren escritura al RF para contar. Mantener un
resultado o un bundle durante un stall conserva su identidad sin recontarlo.

Los dos bundles de retardo se identifican en el flujo dinámico después de cada
salto, tomado o no. Se cuenta como ciclo perdido por salto el avance de un
bundle de retardo enteramente NOP. Todos los slots NOP se contabilizan además
en `cpu_nop_slots`. El diseño actual conserva sus slots de retardo y no genera
ciclos de branch flush.

## 5. Cachés y buffers

| Contadores | Regla de incremento |
| --- | --- |
| `l1_reads`, `l1_writes` | Solicitudes aceptadas por L1, separadas por tipo. |
| `l1_read_hits`, `l1_read_misses`, `l1_write_hits`, `l1_write_misses` | Clasificación de cada solicitud válida aceptada, una vez. |
| `l1_invalid_reads`, `l1_invalid_writes` | Solicitudes aceptadas fuera del segmento; no generan hit/miss. La desalineación rechazada por LSU no llega a L1. |
| `l2_demands`, `l2_hits`, `l2_misses` | Demandas `l2_get` aceptadas y sus resultados de búsqueda. Las instalaciones de WB se cuentan aparte. |
| `l1_evictions_clean`, `l1_evictions_dirty` | Víctimas que WB acepta desde L1, según dirty. |
| `l2_evictions_clean`, `l2_evictions_dirty` | Descarte efectivo de víctima limpia o entrega de víctima sucia a EB. Una promoción a L1 tiene su contador separado `l2_promotions`. |
| `wb_enqueued`, `wb_forwarded`, `wb_sent`, `wb_installed` | Handshakes de `wb_push`, `wb_fwd`, `wb_install` y `wb_done`, respectivamente. |
| `eb_enqueued`, `eb_sent`, `eb_written` | Handshakes de `eb_push`, solicitud de escritura y confirmación de escritura correcta consumida. |
| `wb_occupancy_sum/max`, `eb_occupancy_sum/max` | Suma por ciclo y máximo de entradas ocupadas, incluidas las entradas en servicio. |
| `l2_inflight_sum/max` | Suma por ciclo y máximo de posiciones ocupadas hasta consumir su finalización. |
| `wb_full_cycles`, `eb_full_cycles`, `l2_full_cycles` | Ciclos en que la ocupación alcanza la capacidad configurada. |
| `wb_push_wait_cycles`, `eb_push_wait_cycles`, `l2_get_wait_cycles`, `wb_install_wait_cycles` | Ciclos con `valid && !ready` en el canal indicado. |
| `wb_raw_wait_cycles`, `eb_raw_wait_cycles` | Ciclos de consulta con coincidencia ocupada en WB, o coincidencia pendiente de escritura en EB, respectivamente. |

Un forwarding sigue siendo un miss L1 y evita una demanda nueva a L2. Un store
con miss genera una demanda de línea completa; la instalación desde WB conserva
su naturaleza de desalojo y no aumenta los hits/misses de demanda de L2.

Los ciclos de buffer lleno describen ocupación; los ciclos de espera describen
una solicitud bloqueada. Las esperas locales pueden coincidir entre sí y con
el stall global. Se reportan por separado y no se suman como ciclos perdidos de
CPU. La ocupación de L2 mide operaciones pendientes, sin implicar cuatro
búsquedas simultáneas.

## 6. Memoria principal

| Contador | Regla de incremento |
| --- | --- |
| `mem_reads`, `mem_writes` | Solicitudes aceptadas por el controlador, por tipo. |
| `mem_reads_complete`, `mem_writes_complete` | Transferencias correctas disponibles, por tipo, una vez. |
| `mem_read_words`, `mem_write_words` | Palabras realmente transferidas; una línea completa aporta ocho. |
| `mem_read_cycles`, `mem_write_cycles` | Ciclos de transferencia activa, desde aceptación hasta disponibilidad del resultado completo, separados por tipo. |
| `mem_read_wait_cycles`, `mem_write_wait_cycles` | Ciclos de oferta válida sin aceptación del controlador. |
| `mem_read_rsp_wait_cycles`, `mem_write_rsp_wait_cycles` | Ciclos con respuesta válida y `ready=0`, por canal. |
| `mem_timeouts`, `mem_errors` | Transferencias terminadas por timeout u otro error, categorías separadas. |

Con los valores por defecto, un burst correcto consume 39 ciclos de CPU,
incluye la latencia inicial y aporta ocho palabras. La espera previa de
arbitraje y la retención posterior de respuesta se observan aparte. El tiempo
de transferencia continúa durante el congelamiento del núcleo.

En la jerarquía completa, las lecturas de memoria atienden misses L2; las
escrituras corresponden al drenado de EB. Se exportan ambas y su suma. Una
transferencia fallida conserva los ciclos y palabras que efectivamente consumió.
Una transferencia activa al cerrar aporta sus ciclos y palabras hasta ese
momento, y queda señalada como pendiente.

## 7. Indicadores derivados

| Indicador | Cálculo |
| --- | --- |
| IPC | `cpu_instructions / cpu_cycles`. |
| Throughput de bundles | `cpu_bundles / cpu_cycles`. |
| Hit/miss rate L1 por tipo | Hits o misses de ese tipo divididos entre su suma; excluye solicitudes inválidas. |
| Hit/miss rate L2 | `l2_hits / (l2_hits + l2_misses)` y su complemento. |
| AMAT observado | `dmem_latency_sum / dmem_completed`, en ciclos de CPU por acceso. |
| Ocupación media de buffer o L2 | Su suma de ocupación dividida entre `cpu_cycles`. |
| Bytes transferidos | `4 * (mem_read_words + mem_write_words)`. |
| Ancho de banda observado | Bytes transferidos divididos entre `cpu_cycles / f_cpu`. |
| Utilización del ancho de banda | Ancho de banda observado dividido entre `4 * f_mem`. Equivale a `palabras * MEM_CLOCK_DIV / cpu_cycles`. |
| Fracción de tiempo de transferencia | `(mem_read_cycles + mem_write_cycles) / cpu_cycles`. Incluye la latencia inicial de los bursts. |

Un denominador cero se informa como `N/A`, conservando los contadores crudos.
Con memoria a 50 MHz, el ancho de banda teórico es 200 MB/s. La utilización de
datos transferidos y la fracción de tiempo de transferencia tienen significados
distintos: la latencia inicial ocupa tiempo sin transferir una palabra por ciclo.

Como referencia sin forwarding ni contención:

```text
AMAT_referencia = 1 + MR_L1 * (8 + MR_L2 * Tread)
Tread = MEM_READ_FIRST_WORD_CYCLES + 7 * MEM_CLOCK_DIV
```

El AMAT observado incorpora forwarding, espera por buffers, arbitraje y consumo
de respuesta. Los ciclos de transferencias de fondo pueden coincidir con trabajo
de CPU; no equivalen directamente a stalls.

## 8. Resultados y errores

Los contadores y acumuladores usan 64 bits sin signo. Si una suma excede su
capacidad, se satura y activa `perf_overflow`, conservado hasta reset o nuevo
inicio. Los incrementos simultáneos se acumulan en el mismo flanco.

La salida ofrece una instantánea con contadores crudos, configuración utilizada,
estado de terminación, errores, overflow y trabajo pendiente al cierre:
ocupaciones WB/EB, posiciones L2 ocupadas, transferencias aceptadas aún sin
finalización disponible y respuestas disponibles sin consumir. Las unidades y
nombres se conservan en la exportación.

Un error de dirección, alineación, protocolo o timeout marca la ejecución como
fallida y conserva evidencia parcial. Los resultados de rendimiento comparables
corresponden a programas completados correctamente, con el resultado esperado y
sin overflow. Las métricas de la referencia sin caché mantienen las mismas
reglas de CPU y memoria; los indicadores de caché se informan como `N/A`.

## 9. Casos de referencia

| Caso | Conteo esperado |
| --- | --- |
| Bundle con dos operaciones, un literal y un NOP | Un bundle, dos instrucciones, un literal y un NOP al completar el trabajo. |
| Load hit L1, aceptación y respuesta en `E1` | Un read, un hit, una respuesta correcta, latencia de un ciclo y cero stalls. |
| Store miss L1, hit L2, respuesta en `E9` | Un write y un miss L1, una demanda y un hit L2, latencia de nueve ciclos y ocho stalls de miss. |
| Load miss L1/L2, respuesta en `E48` | Una demanda en cada nivel, un miss en cada uno, una lectura de memoria, latencia de 48 ciclos y 47 stalls sin contención. Memoria consume 39 ciclos y ocho palabras. |
| Forwarding de WB | Un miss L1 y un forwarding; conserva dirty y no genera una demanda a L2 por ese acceso. |
| Línea sucia drena por EB mientras la CPU trabaja | Una escritura y ocho palabras al completar; incrementa tiempo de memoria y solo cuenta stalls si el núcleo realmente se congela. |
| Respuesta de memoria disponible y retenida cinco ciclos | Un `mem_complete` y cinco ciclos de espera de respuesta en su canal; el tiempo de transferencia termina al estar disponible. La espera de consumo no prolonga el timeout. |
| Dos bundles NOP de retardo, uno congelado tres ciclos | Dos ciclos de retardo por sus avances; los tres ciclos congelados se atribuyen a espera de memoria. |

En una ejecución correcta con todas las demandas completadas se cumple
`l1_misses = wb_forwarded + l2_demands`, sumando reads y writes, y
`l2_demands = l2_hits + l2_misses`. Las instalaciones de WB y sus escrituras
posteriores se conservan en sus contadores de tráfico.
