# Instrucciones para agentes — PORYGON

## 1. Alcance

El trabajo de Proyecto II corresponde a **CE4301: arquitectura de computadores**:
jerarquía de memoria, integración con el procesador y métricas. La base funcional
de la iteración 1 se considera terminada. Conserva el trabajo existente y limita
los cambios al issue o tarea solicitado; no aproveches para refactorizar otros
bloques, modificar la ISA o intervenir el compilador.

Antes de editar, revisa `git status`, los cambios locales y las instrucciones
aplicables a los archivos. No sobrescribas ni reviertas trabajo ajeno. Si necesitas
cambiar un módulo fuera del alcance acordado, explica la dependencia y consulta
antes de ampliarlo.

## 2. Fuentes obligatorias

Antes de diseñar una implementación:

1. Lee el issue vigente completo: objetivo, alcance, comportamiento esperado,
   verificación, dependencias y referencias. Si no puedes consultarlo, solicita
   su contenido; no lo reconstruyas desde el título ni desde `issue-map.md`,
   que es un borrador de planificación.
2. Lee los contratos de `docs/ii-proyecto/`: [Jerarquía](docs/ii-proyecto/hierarchy.md),
   [CPU–memoria](docs/ii-proyecto/cpu-memory-contract.md),
   [Movimiento de líneas](docs/ii-proyecto/line-transfers.md),
   [Interfaces](docs/ii-proyecto/interfaces.md),
   [Métricas](docs/ii-proyecto/metrics.md) y
   [Skeletons](docs/ii-proyecto/skeletons.md). Usa la tabla siguiente para profundizar
   en los contratos que afectan al issue, incluidos sus casos concretos.
3. Contrasta el alcance con la parte **CE4301** del
   [enunciado](../../proyecto-ii-grupal-perf-cache.pdf), incluidos los requisitos
   avanzados aplicables. El archivo está en el workspace, fuera de este repositorio;
   si no está disponible en otro checkout, solicita su ubicación o contenido.
4. Revisa `README.md`, [Microarquitectura](docs/microarchitecture.md),
   [Integración con el compilador](docs/compiler-integration.md),
   [Simulación](docs/simulation.md) y el RTL relacionado para distinguir el
   comportamiento implementado de los cambios previstos para Proyecto II.

| Issue | Contratos que requieren especial atención |
| --- | --- |
| P2-03: memoria y controlador | Jerarquía §6, Interfaces §§6–7, Skeletons §3 y Métricas §6. |
| P2-04: eviction buffer | Jerarquía §§4–5, Movimiento de líneas §§2–3, Interfaces §§5 y 7, Métricas §§5–6. |
| P2-05: write buffer | Jerarquía §§4–5, Movimiento de líneas §§2–3, Interfaces §§2 y 4, Métricas §5. |
| P2-06: L1-D | CPU–memoria, Jerarquía §§2–4, Movimiento de líneas, Interfaces §§2–3 y 8, Métricas §§4–5. |
| P2-07/P2-08: L2 | Jerarquía §§2–5, Movimiento de líneas, Interfaces §§3–7 y 9, Métricas §§5–6. |
| P2-09: LSU y núcleo | CPU–memoria completo, especialmente stalls, parada y temporizador; Métricas §§2–4 y RTL de las etapas y unidades con estado. |
| P2-10: contadores | Métricas completo, Skeletons §4 y contratos de los canales que originan cada evento. |
| P2-11: integración | CPU–memoria, Interfaces completo, Movimiento de líneas, Skeletons §§3–4 y Métricas §§2–4. |
| P2-12: referencia sin caché | CPU–memoria, Jerarquía §6, Interfaces §§6–7 y Métricas; la adaptación palabra/línea requiere diseño aprobado. |
| P2-13/P2-14: verificación y evaluación | Todos los contratos; especialmente tiempos de referencia, casos concretos, periodo de medición, indicadores y recuperación de resultados. |

El enunciado establece requisitos y los Markdown recogen las decisiones acordadas.
El issue delimita el trabajo; los skeletons concretan interfaces y todavía no
demuestran comportamiento funcional. No elijas silenciosamente una fuente ante
una contradicción entre ellas o con el RTL: cita las secciones, explica el
conflicto y consulta. Tampoco reduzcas requisitos avanzados al mínimo funcional;
por ejemplo, pipeline interno de caché y non-blocking son requisitos distintos.

## 3. Diseño y aprobación humana

**Antes de implementar RTL, presenta la solución interna y espera aprobación
humana explícita.** La autorización para trabajar un issue no aprueba por sí sola
una organización interna que todavía no se ha presentado. No reabras decisiones
ya aprobadas en la conversación: identifica esa aprobación y continúa dentro
de sus límites. Aprobar el diseño no elimina las pausas de comprensión de la
sección siguiente.

La propuesta debe ser breve y concreta:

- Issue, archivos afectados y correspondencia entre comportamiento esperado,
  secciones de los contratos y requisitos CE4301 del enunciado.
- Organización interna propuesta: almacenamiento, estados, etapas, reservas,
  identificadores y arbitraje que correspondan. Explica con un recorrido cómo
  se acepta, espera y completa una operación, incluidos reset y errores.
- Decisiones aún no fijadas por los contratos, motivo de la opción propuesta,
  alternativas relevantes e impacto sobre latencia, recursos e integración.
- Casos del testbench que verificarán el comportamiento y comandos previstos.

La elección de FSM, puertos de almacenamiento, etapas internas o mecanismo de
cruce de relojes también es una decisión de diseño, aunque no cambie los puertos
externos. Sométela a aprobación antes de implementarla. Ajustes de formato,
comentarios y correcciones que respeten el diseño aprobado no requieren volver
a aprobarlo.

Si falta información, no sabes justificar una solución o surge una ambigüedad
entre etapas o módulos, **pregunta antes de suponer o implementar esa parte**.
Expón el caso concreto, las interpretaciones posibles y su efecto observable.
Puedes continuar con lectura y trabajo independiente ya aprobado; no fijes el
comportamiento dudoso mediante código, tests, valores por defecto o stubs.

Todo cambio al diseño aprobado, a interfaces, políticas o tiempos requiere una
nueva aprobación específica. Después actualiza los Markdown correspondientes
para que el código y los contratos mantengan el mismo comportamiento. No cambies
un contrato para justificar retrospectivamente una implementación.

## 4. Implementación gradual y comprensión

El objetivo es que la persona entienda y pueda estudiar lo implementado.
**No generes una solución completa de una sola vez ni acumules código para
explicarlo al final.** Una solicitud de implementar un issue completo no elimina
este proceso.

Antes de comenzar, divide el diseño aprobado en incrementos pequeños y ordenados
por dependencia. Cada incremento desarrolla una sola unidad de comportamiento
que pueda explicarse por separado: por ejemplo, captura de una solicitud,
actualización de una entrada, una transición de control o un evento de métricas.
Incluye solo los cambios de soporte y pruebas necesarios para esa unidad.

Como límite, cada incremento añade o modifica **como máximo 100 líneas de código**
en total entre RTL, testbenches y otros archivos de código, sin contar comentarios
ni líneas en blanco. Es un máximo, no un objetivo: reduce el tamaño si el concepto
es complejo. No compactes código para cumplir el límite. Si una unidad requiere
más, divídela; si no puedes separarla coherentemente, explica el motivo y solicita
aprobar una excepción de tamaño antes de escribirla.

Aplica este ciclo obligatorio a cada incremento, incluidas correcciones y pruebas:

1. Indica qué comportamiento vas a incorporar y cómo se conecta con lo ya
   comprendido. Si introduce una decisión nueva, obtén primero su aprobación.
2. Implementa únicamente ese incremento y realiza las comprobaciones permitidas
   correspondientes. No adelantes otros incrementos en archivos, herramientas
   o tareas de fondo mientras esperas una respuesta.
3. Muestra el fragmento relevante o diff con enlaces a los archivos y explica
   el código bloque por bloque: propósito, entradas y salidas, registros y
   condiciones, recorrido de una operación y cambios en cada flanco. Justifica
   las construcciones de SystemVerilog usadas cuando ayuden a entenderlo.
   Incluye reset, stalls, prioridades y casos límite que afecten a esa unidad,
   su relación con el contrato y lo que todavía queda pendiente. Una lista de
   archivos modificados o un resumen de funcionalidad no sustituye esta explicación.
4. Cierra preguntando explícitamente si la persona entiende el código o la
   función recién implementada y qué necesita repasar. Por ejemplo:
   «¿Entendés cómo este bloque conserva la solicitud durante la espera y cuándo
   la libera? ¿Hay alguna parte del código que querás revisar antes de seguir?».
5. **Detente y espera una confirmación explícita de comprensión antes de escribir
   más código.** Preguntar y continuar en el mismo turno no cumple la regla.
   El silencio, la aprobación inicial del issue o una aprobación de diseño no
   sustituyen esta confirmación. Si hay dudas, explícalas con un ejemplo concreto
   y vuelve a comprobar la comprensión antes de avanzar.

Si una aclaración requiere corregir código, limita el cambio a la misma unidad,
explica la corrección y repite la pausa. La aprobación de una excepción de tamaño
tampoco elimina la explicación ni la confirmación de comprensión. No delegues
ni generes por adelantado el resto de la solución para eludir este ciclo.

## 5. RTL legible y documentado

- Usa SystemVerilog y las convenciones existentes: nombres descriptivos, tipos
  de paquete, sufijos `_i`/`_o` y distinción clara entre estado registrado y siguiente.
  Deriva anchos y límites de los parámetros; evita números mágicos y duplicar
  constantes compartidas.
- Separa lógica secuencial y combinacional con `always_ff` y `always_comb`.
  Da valores por defecto completos, evita latches involuntarios y deja claros
  reset, habilitadores, prioridades y propietario de cada registro o reserva.
- Mantén visibles aceptación, espera y finalización. La retención de campos,
  liberación de recursos e identificación de respuestas deben poder relacionarse
  directamente con el contrato. No añadas ciclos de latencia por comodidad.
- Usa comentarios en español `/** ... */` estilo JavaDoc/Doxygen, como los
  skeletons: propósito, parámetros, grupos de puertos y referencias al contrato.
  Explica estados y transiciones, invariantes, arbitraje, CDC y casos límite donde
  sean relevantes. Comenta el motivo y el comportamiento temporal; evita narrar
  asignaciones evidentes o dejar comentarios desactualizados.
- Prefiere bloques cortos con una responsabilidad clara. Los comentarios deben
  permitir estudiar el flujo de una operación sin reconstruir todas las FSM.
  Marca los dobles de prueba como tales y mantenlos fuera del RTL funcional.

## 6. Verificación y entrega

En tareas de diseño, auditoría o documentación, haz lectura estática: no ejecutes
el proyecto, compilaciones, simulaciones ni pruebas. En tareas de implementación,
prepara un testbench autochecking que cubra el comportamiento esperado del issue:
casos normales, esperas, conflictos, reset y errores que correspondan. Los
resultados esperados deben proceder del contrato, no copiar la implementación.

Ejecuta las comprobaciones acordadas cuando la tarea permita verificación.
Una prohibición de ejecución vigente en la conversación requiere autorización
explícita antes de ejecutar. No exijas formas de onda como evidencia rutinaria;
usa diagnósticos claros y resume los casos verificados. No reejecutes la base
completa de la iteración 1 sin una necesidad de integración dentro del alcance.

Al entregar, indica qué comportamiento se implementó, archivos y contratos
afectados, decisiones aprobadas, comprobaciones ejecutadas y limitaciones
pendientes. Si solo hubo revisión estática, dilo. No presentes stubs, pruebas no
ejecutadas o dependencias incompletas como funcionalidad verificada. No incluyas
al agente como coautor en commits, issues ni mensajes.
