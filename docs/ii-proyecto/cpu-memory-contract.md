# Contrato CPU–memoria

**Estado:** núcleo implementado y verificado con referencia · **Fecha:** 2026-11-16

## 1. Propósito

Establece las señales, responsabilidades y reglas de comunicación entre el
núcleo y la jerarquía de memoria de datos: cómo se solicita un acceso, cómo se
entrega su resultado y cuándo se detiene o reanuda el pipeline.

El acceso ocurre en EX. Un hit L1 se resuelve en un ciclo; una espera de memoria
congela el pipeline completo, según la sección 3.3 del enunciado del Proyecto II.

IF usa una ROM síncrona de un ciclo: su salida registrada constituye los datos
de IF/ID y fetch registra el PC y la validez en paralelo. No hay otro registro
del bundle en fetch ni una etapa adicional. Los saltos ordinarios conservan
sus dos bundles de retardo. La lectura habilitada registra NOP y un diagnóstico
con su PC ante dirección inválida; sin lectura conserva el bundle. El control
global de retención, el cierre de admisión y la detección de vaciado por parada
ya están implementados en el núcleo.

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

`vliw_processor` usa estos nombres y los tipos de palabra, dirección y máscara
de `pkg_memory`. El tipo de acceso se expone en `dmem_req_write_o`; la preparación
de lectura se conserva como señal interna, sin un segundo habilitador externo.
En un store válido, `req_write=1` y la máscara selecciona sus bytes; una lectura
presenta `req_write=0`, máscara cero y dato de escritura cero.

La observación añade `dmem_rsp_origin_i` (`pkg_metrics::demand_origin_t`) y
`perf_events_o` (`pkg_metrics::cpu_events_t`). La procedencia se conserva junto
con la respuesta hasta su consumo; una respuesta fallida se etiqueta
`ORIGIN_ERROR`. `instruction_error_i` acompaña la salida registrada de ROM.
El núcleo conserva ese error si ID queda retenido y lo emite una vez al admitir
el bundle, con su PC; si el bundle se cancela por parada, se descarta el error.
`alignment_error.address` contiene la dirección efectiva de datos rechazada;
`instruction_error.address` contiene el PC. `invalid_address_pc_o` conserva el
PC del slot LSU y permite asociarlo también al `dmem_error_o` de su consumo.
Estas señales no modifican los handshakes ni el avance funcional.

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
  El temporizador de autenticación conserva su cuenta durante el congelamiento,
  según la regla siguiente; su reloj y los componentes de memoria siguen activos.
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

El núcleo expone `stop_done_o`, pulso combinacional que el entorno muestrea en
el último flanco de ejecución para generar `perf_stop` e incluir sus eventos.
`halted_o` registra la parada completa después de ese mismo flanco y permanece
activo hasta reset; desde entonces se inhibe el avance del núcleo. Los controles
de medición siguen perteneciendo al entorno: estas salidas no son contadores.

### Temporizador de autenticación

El temporizador cuenta **ciclos de avance del núcleo**, incluidos los bundles
NOP. Durante todas las esperas de memoria —aceptación, atención y consumo—
conserva su cuenta y no expira por el paso de esos ciclos reales. Mientras la
sesión está autenticada, cada flanco de avance sin actividad que la recargue
reduce en uno el tiempo restante; al pasar de uno a cero se revoca la
autenticación y se limpia la credencial temporal.

La bóveda conserva su reloj. `timer_tick_i`, conectado al permiso de avance,
habilita únicamente descuento y expiración; no condiciona reset ni los efectos
de instrucciones aceptadas. Esta cuenta es independiente de la ventana de
medición: los contadores de rendimiento y el timeout de memoria siguen contando
ciclos reales. Las esperas de la jerarquía no consumen la ventana de sesión.

Se conservan las reglas de la bóveda: `auth` exitoso carga 32 ciclos por defecto;
`write`, `feistel` y `lopw` aceptados durante una sesión autenticada recargan ese
valor. `rvk`, `pwd` exitoso y reset cierran la sesión. Una recarga aceptada tiene
prioridad sobre el decremento del mismo flanco. Sin recargas, una sesión expira
tras 32 avances posteriores a su carga; sin stalls, cargar en `E0` expira en `E32`.

Una instrucción criptográfica se acepta una sola vez, al avanzar efectivamente
desde EX. Mantenerla durante un stall no ejecuta su operación ni recarga el
temporizador. La autorización se evalúa al aceptarla: una sesión ya cerrada
rechaza la operación protegida con el diagnóstico existente, sin modificar
llaves ni producir un resultado autorizado. Una sesión vigente no caduca por
una espera de memoria. Los resultados de
operaciones ya aceptadas se conservan durante el congelamiento.

| Caso | Comportamiento esperado |
| --- | --- |
| Quedan 32 ciclos de sesión y comienza una espera de memoria de 47 ciclos, sin recargas | La sesión conserva los 32 ciclos restantes durante toda la espera. |
| Una instrucción protegida permanece en EX durante esa espera | No actúa ni recarga; al reanudar se valida con la sesión conservada. |
| La sesión está cargada y el núcleo avanza 32 ciclos sin recargas, incluidos NOPs | Sigue activa tras 31 avances y expira en el 32. |
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

## 6. Organización acordada de la LSU

El control usa dos estados: `OFFER`, disponible para presentar la operación
válida de EX, y `WAIT_RESPONSE`, solicitud aceptada cuya respuesta no se ha
consumido. Sin aceptación se conserva `OFFER`; aceptar sin consumir conduce a
`WAIT_RESPONSE`. Consumir tiene prioridad, por lo que un hit con aceptación y
respuesta en el mismo flanco permanece en `OFFER`, sin ciclo adicional.

Los campos de solicitud se derivan de la instrucción y operandos retenidos en
ID/EX; no se duplican en registros de solicitud de la LSU. El núcleo debe
conservar esos campos hasta completar la operación y avanzar EX en ese flanco.
`completion_ready_i` expresa disponibilidad interna para capturar la respuesta,
independiente del stall por memoria. `dmem_rsp_ready_o` requiere esa disponibilidad
y una demanda ya aceptada o aceptándose en ese flanco. `dmem_done_o` indica
exclusivamente el handshake de respuesta; no sustituye el diagnóstico local de
desalineación. Reset cancela el estado e inhibe ambos handshakes.

El formato del load es combinacional, usando función, destino y posición de
byte conservados en ID/EX. `load_valid_o` identifica el consumo de una respuesta
correcta de lectura; `load_rd_o` y `load_data_o` se entregan en ese mismo ciclo
para capturarse hacia WB en el flanco de consumo. Sin resultado válido, destino
y dato son cero. `dmem_error_o` indica una respuesta fallida consumida, tanto
para load como para store; una respuesta retenida todavía no emite el evento.
`execution_stage` captura el canal completo con PC e instrucción en `load_wb_q`.
`advance_i` habilita esa frontera: durante su desactivación se conserva el canal
completo. El control debe permitir avance en el mismo flanco de consumo de una
respuesta. Reset cancela el resultado pendiente; el consumidor debe inhibir la
escritura RF durante un stall. ALU0 también conserva su canal completo con
`advance_i`; su resultado anterior no se sustituye por la operación de EX mientras
esta espera memoria. SuperALU usa ese mismo permiso para sus dos etapas MUL,
los tags paralelos y su canal WB compartido, tanto para productos como resultados
rápidos. Datos, destino, selección de mitad y procedencia se conservan juntos.
Las latencias estáticas se mantienen en ciclos de avance, con reset prioritario.
CRYPTO acepta el slot solo con avance efectivo. `crypto_wb` y su tag conservan
resultados y eventos durante la espera; execution_stage califica los diagnósticos
con el avance para no repetirlos. La bóveda conserva su reloj y recibe
`timer_tick_i` desde ese permiso para pausar solo la cuenta de sesión durante
las esperas. La autorización se valida al aceptar la instrucción.

Fetch usa `advance_i` para habilitar tanto PC y metadatos IF/ID como la lectura
de ROM: con el permiso desactivado también se conserva el bundle registrado.
Writeback califica los cinco habilitadores RF con el mismo permiso, manteniendo
datos y destinos. La retención de resultados pertenece a los productores; estos
habilitadores ya reciben el permiso común desde `vliw_processor`.

El núcleo genera `pipeline_advance` combinacionalmente: con reset inactivo,
avanza si no hay acceso alineado preparado en EX o si se consume su respuesta.
La operación activa se reconoce por lectura o máscara de escritura preparada,
no por `req_valid`, que baja después de aceptar. El permiso habilita fetch,
las cinco operaciones ID/EX, las etapas/tags MUL, los registros WB de
ALU0/SuperALU/load/CRYPTO y los cinco puertos RF. CRYPTO también conserva su tag.
Una desalineación permite avanzar sin solicitud; una respuesta con error también
reanuda. `completion_ready_i` está activo fuera de reset: el canal WB anterior
puede escribir en el mismo flanco en que se captura el nuevo, sin una cola ni
un consumidor independiente que bloquee la salida. Aceptar una solicitud sigue
siendo independiente del avance. El retorno no añade una burbuja obligatoria.

**Estado de implementación:** la FSM y el formato/error de respuesta se verifican
aisladamente con `tests/unit/tb_lost_handshake.sv`. `tests/unit/tb_load_wb.sv`
comprueba captura y retención de ALU0 y load en execution_stage, sin RF: una suma
anterior conserva valor, destino y procedencia durante la espera del load. Al
reanudar se captura el nuevo canal; reset cancela también ALU0 con avance detenido.
La misma prueba pausa MUL/MULH consecutivos en EX1, EX2 y WB, comprobando valor,
destino, PC e instrucción, la salida posterior sin duplicados, una operación
rápida retenida y cancelación por reset. `tb_super_alu.sv` mantiene la verificación
aritmética sin stalls con el permiso habilitado continuamente.
La prueba EX/WB autentica, acepta Feistel y conserva sus dos resultados durante
47 ciclos con WRITE retenido: la cuenta sigue en 32 y la llave no se modifica.
Al reanudar acepta el WRITE y lo aplica. Después de 31 avances sin recargas la
sesión sigue activa y expira en el 32; un WRITE posterior se rechaza, conserva
el PC de su error durante otro stall y emite el diagnóstico una vez. Verifica reset con
un diagnóstico pendiente y sin avance. Las pruebas crypto_unit/crypto_wb previas
se ejecutan con avance continuo.
`tests/unit/tb_pipeline_hold.sv` verifica ROM/fetch y cuenta efectos de los cinco
puertos WB durante una espera y su reanudación, sin integrar un banco RF.
`tests/unit/tb_core_memory_wait.sv` comprueba en el núcleo retención de PC e ID/EX,
aceptación única y reanudación por respuesta fallida, con dobles de protocolo.
La interfaz externa del núcleo ya usa `dmem_req_*`/`dmem_rsp_*`, con tipo de acceso
explícito. Los nombres `memory_*` permanecen solo en la preparación interna de
LSU/execution_stage. `make sim-core-memory-wait` verifica además los campos de
lectura y de un store byte con dirección alineada y máscara desplazada.
Las conexiones del wrapper de RAM todavía no usan el protocolo nuevo; su
integración con la jerarquía real corresponde a P2-11. Los eventos del núcleo
ya están disponibles en `perf_events_o`.

El modelo de pruebas `tests/support/cpu_memory_reference.sv` implementa datos y
protocolo CPU–L1 de una demanda, sin etiquetas ni reemplazo de caché. Su arreglo
de bytes se inicializa en cero o desde imagen existente; lee palabras little
endian y aplica stores por máscara. Los helpers rechazan rango inválido o
desalineación sin indexar el arreglo; el protocolo devuelve error y dato cero.
`accept_enable_i` permite forzar espera de aceptación. `RESPONSE_CYCLES` fija el
flanco de respuesta contando la aceptación como E1: los perfiles 1/9/48 responden
en E1/E9/E48 sin depender del avance del núcleo. La demanda aceptada conserva
dirección, tipo, dato y máscara; la respuesta se retiene hasta su consumo.
El store se aplica una vez al terminar servicio, incluso si se demora el consumo.
Reset cancela demanda/respuesta pendientes, conserva datos y no revierte stores
ya completados. `make sim-reference-storage` verifica datos y helpers;
`make sim-reference-timing` verifica esos tres perfiles, esperas de aceptación y
consumo, campos retenidos, store único, error de rango y reset. Aún no constituye
una prueba integrada de jerarquía real.

`make sim-core-reference` conecta el modelo, la ROM síncrona y el núcleo con la
imagen existente `top_integration.mem`. Ejecuta perfiles E1/E9/E48 con aceptación
inmediata o dos flancos iniciales de bloqueo. Comprueba seis demandas completas,
un diagnóstico de rango, avance en el mismo flanco de respuesta, inhibición de
los cinco puertos RF durante stalls y valores finales de loads, MUL, ALU y
stores por máscara. Verifica que el load fallido conserva su destino anterior
y que el slot ALU concurrente termina. La imagen también contiene saltos y RVK.
Las pasadas de esa imagen terminan desde el testbench después de 45 avances.
Los escenarios integrados adicionales de autenticación, retención y reset se
describen al final de esta sección, junto con su observación de métricas.

`vliw_processor` implementa `stop_fire`:
requiere un salto válido tomado al propio PC y avance efectivo. En ese mismo
flanco `stop_admission` inhibe la lectura ROM, invalida IF/ID y sustituye lo que
entraría desde ID a EX por burbujas inválidas. `stop_requested_q` conserva el
cierre hasta reset. Fetch recibe `stop_i` con prioridad reset, parada, avance;
conserva PC/metadatos e invalida el bundle. Ejecución y WB siguen avanzando bajo
el permiso habitual de memoria, por lo que completan operaciones del marcador
y anteriores. El cierre completo se conecta mediante la previsión descrita abajo.

La prueba integrada verifica marcador solo, load/MUL, ALU, error CRYPTO, store,
load fallido y operaciones ALU/MUL hacia `r0`, en los tres perfiles. Bloquea aceptación de memoria dos flancos
y verifica que no se registre la parada durante esa espera; comprueba ID/EX
vacío, PC retenido y ausencia de efectos de una suma y un store posteriores al
marcador. Reinicia entre casos para verificar reapertura.

Para reconocer el vaciado, el núcleo usa
`execution_stage.work_after_advance_o`: previsión combinacional del trabajo que
permanecería después de un flanco con `advance_i=1`. Incluye nuevas salidas de
ALU/load hacia WB y las dos etapas MUL; el WB actual se consume en ese flanco
y no añade otro ciclo de espera. No filtra destinos `r0`. Saltos, stores y
errores LSU terminan en EX; una espera de memoria sigue impidiendo el avance.
La previsión no indica vacío durante un stall: solo puede interpretarse al
avanzar, y reset la lleva a cero.

CRYPTO entrega su propia previsión: Feistel conserva una finalización en WB,
incluso con ambos destinos `r0`, y los errores de autenticación/acceso esperan
la emisión de su diagnóstico registrado. Las operaciones correctas de bóveda
terminan al aplicar su efecto en EX, sin prolongar el vaciado por su tag.
`make sim-load-wb` verifica la previsión antes del flanco para ALU0, load,
MUL/MULH, operaciones rápidas, bóveda correcta, errores y Feistel con destinos
`r0`, manteniendo las comprobaciones anteriores de resultados y retención.
El núcleo conecta esa previsión al cierre:
`stop_done_o = stop_admission && pipeline_advance && !work_after_advance`.
`stop_admission` incluye el propio reconocimiento del marcador, por lo que un
marcador sin trabajo futuro puede cerrar en su flanco de EX. El WB que termina
en ese flanco no prolonga el vaciado. `halted_q` se registra al muestrear el pulso
e inhibe avances posteriores; reset limpia tanto esa marca como la solicitud
de parada. La LSU no puede cerrar anticipadamente: una demanda que aún espera
su respuesta mantiene el avance inhibido.

La prueba usa `halted_o` en lugar de un margen fijo para observar resultados.
Verifica un único pulso en el ciclo exacto: marcador solo, store y load fallido
cierran al avanzar el marcador; ALU y diagnóstico CRYPTO un avance después;
load/MUL tres avances después, coincidiendo con el RF del producto. Confirma
resultados y diagnósticos del último flanco, persistencia de parada y reapertura
por reset. `perf_events_o` incluye los eventos de ese último flanco; el entorno
puede usar `stop_done_o` como `perf_stop`. La integración con los contadores
de P2-10 y con la jerarquía real pertenece a P2-11.

La prueba del núcleo ahora autentica mediante cuatro loads y LOPW y ejecuta un
bundle con Feistel y MUL seguido de load y WRITE. Durante la espera conserva
la cuenta de sesión en 32, no modifica la llave y retiene los dos canales
Feistel completos y el tag MUL con PC/instrucción. Al reanudar verifica los
resultados RF, la palabra cargada, el producto y el WRITE autorizado. Cuenta
las escrituras de cada puerto RF y commits de bóveda para exigir que sucedan
exactamente una vez. Después repite la preparación y aplica reset con EX1/WB
retenidos y la LSU en oferta bloqueada (E1) o demanda aceptada (E9/E48).
El nuevo programa termina desde reset sin accesos: después de esperar más que
la latencia anterior no deben reaparecer respuestas, credenciales, llaves ni
resultados antiguos. Estos casos pasan para los tres perfiles de la referencia.

## 7. Observación del núcleo y verificación P2-09

`core_metrics.sv` genera `cpu_events_t` sin retroalimentar el control funcional.
`bundle_completions.sv` conserva metadatos de finalización, no dependencias de
registros ni disponibilidad de unidades. Su validez distingue un bundle NOP
del programa de una burbuja de llenado o cancelación.

| Operación | Flanco de finalización, con avance continuo |
| --- | --- |
| Store/respuesta fallida LSU, desalineación, salto, bóveda correcta, bundle NOP | EX efectivo |
| ALU0, ALU1 rápida, load correcto, Feistel y diagnóstico CRYPTO | Un avance después de EX |
| MUL/MULH | Tres avances después de EX: EX2, captura WB y consumo RF |

Las instrucciones se contabilizan en su propia finalización. El bundle y sus
NOPs/literales se contabilizan al finalizar su última operación. Puede terminar
un bundle joven antes que otro con MUL y pueden coincidir varias finalizaciones
en un flanco. Los destinos `r0` también cuentan; Feistel cuenta una operación
aunque escriba dos registros o ninguno. Los tags diferidos se conservan durante
stalls y se cancelan con reset, sin duplicar eventos ni extender las latencias.

El observador emite inicio de demanda en su primera presentación, incluso con
`req_ready=0`, y fin solo al consumir la respuesta. Las esperas se clasifican
por reloj real con prioridad consumo, aceptación y miss pendiente. El flanco
que acepta un miss se atribuye a `WAIT_MISS`. `branch_done` incluye saltos no
tomados; los dos siguientes bundles dinámicos identifican el retardo y solo
un NOP completo que avance genera `branch_delay`. Las máscaras de ocupación
describen el intervalo anterior al flanco, incluidas etapas jóvenes que se
cancelan en ese flanco; sus transferencias sí quedan inhibidas al cancelar.
EX incluye las etapas MUL en drenaje y WB incluye diagnósticos/resultados sin
escritura RF. Después de `halted_o` y durante reset no se emiten eventos.

`make test-p2-09` ejecuta las pruebas dirigidas de ROM, fronteras, LSU, ejecución,
referencia, finalizaciones, observador y núcleo completo. El núcleo consume
respuestas inmediatamente fuera de reset porque WB siempre puede drenar en
su avance. La espera de consumo se verifica aisladamente en LSU, referencia
y observador, sin introducir backpressure artificial en el núcleo.

La integración compara todos los campos retenidos de IF/ID, las cinco
operaciones ID/EX, los cinco canales WB y dirección/dato/máscara/tipo de la
solicitud antes/después de cada flanco congelado. Comprueba los siguientes
totales calculados a partir de las imágenes y su recorrido dinámico:

| Escenario | Bundles | Instrucciones | Slots NOP | Literales |
| --- | ---: | ---: | ---: | ---: |
| Imagen base, 45 avances | 43 | 17 | 144 | 11 |
| Autenticación, Feistel hacia r0, Feistel/MUL y load/WRITE | 33 | 19 | 104 | 9 |
| Nuevo programa de parada tras reset | 1 | 1 | 3 | 0 |

Los totales incluyen el último flanco y excluyen bundles posteriores al salto
final. También se comprueban procedencias L1/L2/memoria/error, cantidades de
demandas, causas de espera y retardo de saltos. Una prueba del observador cubre
procedencia WB, diagnóstico ROM retenido/cancelado y ausencia de eventos en
stall/reset/parada. La integración añade una desalineación real sin solicitud
y un salto a texto inválido cuyo diagnóstico queda retenido por un segundo
load pendiente; exige dirección/PC correcto y emisión única.

El wrapper de RAM anterior necesita adaptar su protocolo antes de ejecutarse;
esta etapa no constituye una integración funcional con la jerarquía real.
`tb_lost.sv` ya usa un doble de hit E1 y conserva sus 102 comprobaciones de
formato, máscaras y alineación. `make test` vuelve a ejecutarlas con el API actual.
