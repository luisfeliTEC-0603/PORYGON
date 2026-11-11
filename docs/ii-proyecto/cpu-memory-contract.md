# Contrato CPU–memoria

**Estado:** propuesta de diseño · **Fecha:** 2026-11-08

## 1. Propósito

Establece las señales, responsabilidades y reglas de comunicación entre el
núcleo y la jerarquía de memoria de datos: cómo se solicita un acceso, cómo se
entrega su resultado y cuándo se detiene o reanuda el pipeline.

El acceso ocurre en EX. Un hit L1 se resuelve en un ciclo; una espera de memoria
congela el pipeline completo, según la sección 3.3 del enunciado del Proyecto II.

## 2. Responsabilidades

| Parte | Responsabilidad |
| --- | --- |
| Núcleo / LSU | Calcular la dirección, validar alineación, preparar stores, conservar los metadatos del load y controlar el avance del pipeline. |
| Jerarquía / L1 | Aceptar la solicitud, resolver el acceso y entregar una respuesta. Conservar la operación mientras atiende un miss. |

La interfaz usa el reloj de CPU de 100 MHz y admite **una solicitud pendiente**.
Las direcciones son de 32 bits y se presentan alineadas a cuatro bytes. Los datos
son palabras de 32 bits, little endian. El segmento de datos es
`0x00010000–0x0001FFFF`.

Las [políticas de la jerarquía](hierarchy.md) establecen write-back en ambos
niveles, write-allocate en L1 y relación exclusiva entre L1 y L2.

La LSU mantiene la convención de [lost_unit.sv](../../rtl/core/lost_unit.sv):
forma la máscara y desplaza el dato del store a sus posiciones de byte. En loads,
recibe la palabra completa y selecciona/extiende el byte o media palabra usando
los metadatos conservados.

## 3. Interfaz

Los nombres y sufijos se expresan desde el núcleo. `valid` indica que hay una
solicitud o respuesta disponible; `ready`, que el receptor puede aceptarla.

| Señal | Bits | Dirección | Contenido |
| --- | --- | --- | --- |
| `dmem_req_valid_o` | 1 | CPU → L1 | Solicitud válida. |
| `dmem_req_ready_i` | 1 | L1 → CPU | Puede aceptar la solicitud. |
| `dmem_req_addr_o` | 32 | CPU → L1 | Dirección de palabra alineada. |
| `dmem_req_write_o` | 1 | CPU → L1 | `0`: lectura; `1`: escritura. |
| `dmem_req_wdata_o` | 32 | CPU → L1 | Dato del store con bytes posicionados. |
| `dmem_req_wstrb_o` | 4 | CPU → L1 | Bytes a escribir; cero para lecturas. |
| `dmem_rsp_valid_i` | 1 | L1 → CPU | Respuesta válida. |
| `dmem_rsp_ready_o` | 1 | CPU → L1 | Puede consumir la respuesta. |
| `dmem_rsp_rdata_i` | 32 | L1 → CPU | Palabra leída; cero en store o error. |
| `dmem_rsp_error_i` | 1 | L1 → CPU | El acceso terminó con error. |

## 4. Funcionamiento

### Ciclos y flancos

Las señales se calculan entre flancos y se transfieren en el flanco positivo.
`E0` coloca el bundle en EX; `C0` es su primer ciclo de acceso.

```text
             E0                         E1                         E2
Reloj         ↑---------- C0 ------------↑---------- C1 ------------↑
              |                         |
Núcleo        Captura bundle en EX      Captura respuesta y avanza,
              |                         o conserva el bundle si espera.
Durante C0:   |
  CPU / LSU   +--> Calcula req_addr, req_write, req_wdata y req_wstrb.
              +--> Presenta req_valid y disposición a recibir: rsp_ready.
  L1          +--> Consulta etiquetas: hit/miss.
              +--> Genera req_ready y rsp_valid; si responde, rdata/error.
                                        |
En E1:                                  +--> req_valid && req_ready: acepta.
                                        +--> rsp_valid && rsp_ready: responde.
```

Aceptar significa que L1 se hace responsable del acceso; responder significa que
el núcleo consume su resultado. En un hit ambos pueden ocurrir en el mismo
flanco. Cada solicitud aceptada recibe una sola respuesta.

Los ejemplos omiten `dmem_` y los sufijos. Las tablas muestran los valores
**antes del flanco** y su efecto en ese flanco. `rsp_ready=1` y `rsp_error=0`
en todos los casos; `—` indica un valor sin uso. L1 genera `rsp_valid` sin
esperar a `rsp_ready`, y acepta solicitudes independientemente del avance del
pipeline.

### Caso 1: CPU quiere hacer load y hay hit

Leer una palabra de `0x00010020`, cuyo contenido es `42`:
`req_addr=0x00010020`, `req_write=0`, `req_wstrb=0000`.

| Flanco | req_valid | req_ready | rsp_valid | rsp_rdata | Efecto |
| --- | --- | --- | --- | --- | --- |
| E1 | 1 | 1 | 1 | 42 | L1 acepta; CPU captura el dato y avanza. |

Cero stalls. El dato capturado continúa hacia WB con los metadatos del load.

### Caso 2: CPU quiere hacer load y hay miss

La misma lectura falla en L1 y acierta en L2:

| Flanco | req_valid | req_ready | rsp_valid | rsp_rdata | Efecto |
| --- | --- | --- | --- | --- | --- |
| E1 | 1 | 1 | 0 | — | L1 acepta la solicitud; CPU se congela. |
| E2–E8 | 0 | — | 0 | — | L1 atiende el miss; CPU conserva el bundle. |
| E9 | 0 | — | 1 | 42 | CPU captura el dato y reanuda el pipeline. |

Tras aceptar, el núcleo marca la operación pendiente y baja `req_valid`, aunque
el bundle siga en EX. Así evita volver a solicitarla durante los ocho stalls.
Si también falla L2, la espera se extiende hasta completar el acceso a memoria.

### Caso 3: CPU quiere hacer store y hay hit

Escribir `0xAABBCCDD` en `0x00010020`, con recursos de escritura disponibles:
`req_addr=0x00010020`, `req_write=1`, `req_wdata=0xAABBCCDD`, `req_wstrb=1111`.

| Flanco | req_valid | req_ready | rsp_valid | rsp_rdata | Efecto |
| --- | --- | --- | --- | --- | --- |
| E1 | 1 | 1 | 1 | 0 | L1 actualiza la palabra y marca la línea sucia; CPU avanza. |

Cero stalls. La modificación permanece en L1 hasta el desalojo de la línea.
Las lecturas posteriores deben observar el dato actualizado.

### Caso 4: CPU quiere hacer store y hay miss

La misma escritura falla en L1 y acierta en L2. Primero se traslada la línea
de L2 a L1 y después se aplica el store.

| Flanco | req_valid | req_ready | rsp_valid | rsp_rdata | Efecto |
| --- | --- | --- | --- | --- | --- |
| E1 | 1 | 1 | 0 | — | L1 conserva dirección, dato y máscara; CPU se congela. |
| E2–E8 | 0 | — | 0 | — | La jerarquía obtiene la línea; CPU conserva el bundle. |
| E9 | 0 | — | 1 | 0 | L1 completa el store y marca la línea sucia; CPU avanza. |

El store se acepta y se aplica una sola vez. L2 invalida la línea cuando L1
acepta su entrega, en la vía destino o en su espacio de entrada. Si tampoco
estaba en L2, se obtiene de memoria principal.

### Esperas y errores

- **Forwarding del write buffer:** un miss L1 puede recuperar la línea desde
  ese buffer y completar el acceso sin consultar L2, según el
  [protocolo de traslado](line-transfers.md). Conserva la misma interfaz de respuesta.
- **Buffer lleno:** si L1 no puede aceptar, mantiene `req_ready=0`. La CPU
  conserva `req_valid=1` y los campos de la solicitud hasta su aceptación.
- **Respuesta sin consumir:** con `rsp_valid=1` y `rsp_ready=0`, L1 conserva
  valid, dato y error hasta que la CPU pueda capturarlos.
- **Pipeline detenido:** se conservan PC, registros, resultados y metadatos;
  se inhiben escrituras al RF, saltos y aceptación de instrucciones criptográficas.
  La lógica de solicitud pendiente, las cachés y los buffers siguen funcionando.
  El temporizador de autenticación y su expiración siguen activos, según la
  regla siguiente.
- **Acceso inválido:** la LSU rechaza desalineación; L1 responde con error a
  direcciones fuera de rango. Se emite un diagnóstico único y se suprime el WB
  del load. Los otros slots continúan al avanzar.
- **Reset activo:** no hay transferencias y se cancelan operaciones pendientes.
- **Timeout de memoria:** se informa error y se detiene la simulación según la
  [política de timeout](hierarchy.md#timeout).

### Parada del programa y vaciado del pipeline

La condición de parada es un salto tomado hacia el PC del propio salto. Se
reconoce una sola vez, en el flanco en que el bundle avanza efectivamente desde
EX. Un salto retenido por un stall no activa la parada hasta poder avanzar.

- En ese mismo flanco se detienen el fetch y la admisión de bundles nuevos.
  Los bundles posteriores al marcador que ya estén en IF o ID se invalidan;
  no llegan a ejecutarse, emitir solicitudes de memoria ni producir efectos
  o eventos de finalización, incluidos los NOPs de retardo del salto final.
- El bundle del marcador y todos los anteriores continúan hasta completar
  todas sus operaciones. El pipeline recibe burbujas inválidas en lugar de
  bundles nuevos; no se congela globalmente por haber solicitado la parada.
  Si una operación pendiente espera memoria, se aplican los stalls habituales
  y se reanuda al recibir su respuesta.
- El pipeline termina de vaciarse cuando no quedan bundles válidos del programa,
  resultados por escribir ni solicitudes del núcleo por completar. Esta condición
  se evalúa incluyendo las finalizaciones del flanco actual y determina el cierre
  de medición definido en [Métricas](metrics.md#2-periodo-de-medición).
- La admisión permanece deshabilitada hasta reset del núcleo. Los buffers y el
  controlador pueden seguir drenando; no es necesario escribir todas las líneas
  dirty a memoria para considerar terminado el programa.

Esta parada es propia del marcador de terminación. Los demás saltos conservan
sus dos bundles de retardo y su comportamiento actual.

| Caso | Comportamiento esperado |
| --- | --- |
| Se reconoce el marcador y hay bundles posteriores en IF e ID | Se invalidan y no se admite otro bundle, tampoco en ese flanco. |
| Una multiplicación anterior todavía tiene un resultado pendiente | Continúa hasta escribirlo; la medición sigue activa hasta incluir esa finalización. |
| El bundle del marcador tiene otra operación aún pendiente | Se completa también esa operación antes de declarar el pipeline vacío. |

### Temporizador de autenticación

El temporizador cuenta **ciclos reales del reloj de CPU**, incluidos todos los
ciclos de congelamiento por memoria. No se pausa con el pipeline ni con los
contadores de rendimiento. Mientras la sesión está autenticada, cada flanco
sin actividad que la recargue reduce en uno el tiempo restante; al pasar de uno
a cero se revoca la autenticación y se limpia la credencial temporal, aunque el
núcleo esté detenido.

Se conservan las reglas de la bóveda: `auth` exitoso carga 32 ciclos por defecto;
`write`, `feistel` y `lopw` aceptados durante una sesión autenticada recargan ese
valor. `rvk`, `pwd` exitoso y reset cierran la sesión. Una recarga aceptada tiene
prioridad sobre el decremento del mismo flanco. Sin recargas, una sesión cargada
en `E0` expira en `E32`.

Una instrucción criptográfica se acepta una sola vez, al avanzar efectivamente
desde EX. Mantenerla durante un stall no ejecuta su operación ni recarga el
temporizador. La autorización se evalúa al aceptarla: si expiró durante la
espera, una operación que la requiere se rechaza con el diagnóstico existente
y sin modificar llaves ni producir un resultado autorizado. Los resultados de
operaciones ya aceptadas se conservan durante el congelamiento.

| Caso | Comportamiento esperado |
| --- | --- |
| Quedan 32 ciclos de sesión y comienza una espera de memoria de 47 ciclos, sin recargas | La sesión expira durante la espera, tras 32 ciclos reales. |
| Una instrucción protegida permanece en EX durante esa espera | No actúa ni recarga la sesión; al reanudar se valida con la autorización vigente. |
| Queda un ciclo y se acepta una operación que recarga la sesión | Se acepta con la autorización previa al flanco y se recarga; no expira en ese flanco. |

## 5. Tiempos de referencia

| Caso | Aceptación | Respuesta y avance | Stalls adicionales |
| --- | --- | --- | --- |
| Hit L1 sin contención | `E1` | `E1` | 0 |
| Miss L1, hit L2 | `E1`; el núcleo se congela | `E9` | 8 |
| Miss L1 y L2 | `E1`; el núcleo se congela | `E(9 + Tmem)` | `8 + Tmem` |
| Espera de aceptación por buffer lleno | `E(N + 1)`; solicitud estable | Según el acceso | N, además de su atención |

Las latencias de misses suponen ausencia de contención y respuesta con la línea
completa. `Tmem = MEM_READ_FIRST_WORD_CYCLES + 7 × MEM_CLOCK_DIV` incluye todo
el burst y usa los [parámetros de memoria](hierarchy.md#6-memoria-principal).
Con los valores por defecto, memoria a 50 MHz: `Tmem=39`, 47 stalls y reanudación
en `E48`.

Los accesos se cuentan al aceptarse, una vez; las esperas se cuentan por ciclo.
Mantener un bundle o una solicitud durante un stall no genera accesos nuevos.
