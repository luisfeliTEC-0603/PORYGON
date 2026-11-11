# Jerarquía de memoria de datos

## 1. Propósito

Establece la configuración y las políticas de L1-D y L2. La comunicación con
el procesador se define en el [contrato CPU–memoria](cpu-memory-contract.md).
Los traslados internos se definen en [Movimiento de líneas](line-transfers.md).

## 2. Configuración

| Propiedad | L1-D | L2 |
| --- | --- | --- |
| Capacidad | 4 KiB | 16 KiB |
| Asociatividad | 2 vías | 4 vías |
| Tamaño de línea | 32 bytes | 32 bytes |
| Latencia de hit | 1 ciclo | 8 ciclos |
| Escritura | Write-back | Write-back |
| Reemplazo | LRU | Tree-PLRU |

L1 usa **write-allocate**. La relación es **exclusiva**: una línea válida reside
en L1 o en L2. Al trasladarla se conserva su estado dirty; los desalojos de L1
se envían a L2, también cuando la línea está limpia.

## 3. Selección de víctima

- Si el conjunto tiene una vía inválida, se utiliza antes de desalojar una línea.
- En L1, si ambas vías están ocupadas, se desaloja la menos recientemente usada.
  Un bit por conjunto identifica la víctima: acceder o instalar en vía 0 deja
  como víctima la vía 1, y viceversa.
- En L2 se usa tree-PLRU: tres bits por conjunto forman un árbol que aproxima
  cuál de las cuatro vías fue menos recientemente utilizada. Los 128 conjuntos
  requieren 384 bits (48 bytes) de estado de reemplazo.
- Lecturas, escrituras e instalaciones actualizan la información de uso una
  sola vez al hacerse efectivas. Los ciclos de espera no cuentan como accesos.
- La víctima elegida se conserva hasta completar su desalojo.

El reemplazo decide qué línea sale. Su traslado y la conservación del estado
dirty siguen las reglas de exclusividad y write-back.

## 4. Buffers

Ambos buffers presentan sus entradas para drenado en orden FIFO y su capacidad
es parametrizable en número de líneas. Cada entrada conserva dirección base,
32 bytes de datos y dirty. Tras aceptar una solicitud puede presentarse la
siguiente; las confirmaciones pueden consumirse fuera de orden, identificando
cada entrada sin alterar el orden relativo de las restantes.

| Buffer | Parámetro | Valor por defecto | Entrega completada |
| --- | --- | --- | --- |
| Write buffer L1 → L2 | `WRITE_BUFFER_DEPTH` | 4 entradas | Se consume la confirmación de instalación de L2, o L1 acepta la línea por forwarding. |
| Eviction buffer L2 → memoria | `EVICTION_BUFFER_DEPTH` | 8 entradas | Se consume la confirmación de escritura completa sin error. |

- **Write buffer:** forwarding de la línea completa hacia L1, conservando dirty.
  Permite buscar y retirar una entrada por dirección sin alterar el orden de las
  restantes. Si ya está en servicio hacia L2, se espera el consumo de su
  confirmación de instalación y se recupera desde allí, evitando una doble entrega.
- **Eviction buffer:** esperar el consumo de la confirmación de escritura sin
  error de la línea en conflicto antes de leerla de memoria. La búsqueda incluye
  entradas en servicio y no exige vaciar todo el buffer.

La selección entre forwarding y drenado se define en
[Movimiento de líneas](line-transfers.md#2-transferencia-y-espacio-disponible).

## 5. Avance y arbitraje

L2 puede atender operaciones independientes mientras un miss espera memoria.
El pipeline del núcleo permanece congelado hasta consumir la respuesta de su
acceso. El temporizador de autenticación sigue contando ciclos reales de CPU,
según el [contrato CPU–memoria](cpu-memory-contract.md#temporizador-de-autenticación).

| Parámetro | Valor por defecto | Rango |
| --- | --- | --- |
| `L2_MAX_INFLIGHT` | 4 operaciones | 1–4 |

Cada solicitud aceptada por L2 ocupa una posición hasta consumir la entrega de
su resultado o la confirmación de instalación de su línea. El límite incluye
solicitudes de L1 e instalaciones del write buffer; las entradas aún encoladas
y no aceptadas por L2 no lo consumen. El núcleo mantiene una sola solicitud de
demanda pendiente.

Al alcanzar el límite, L2 deja de aceptar solicitudes nuevas. Las operaciones
ya aceptadas y las respuestas pendientes continúan avanzando según sus recursos
y dependencias.

Cuando varias solicitudes compiten por un recurso, se atiende **la más antigua
que pueda avanzar**. La antigüedad se toma desde que solicita ese recurso por
primera vez y se conserva durante las esperas. En llegadas simultáneas se prioriza
el drenado de buffers, salvo el forwarding ya definido para una misma entrada.

- Una operación puede avanzar si dispone de los datos y recursos necesarios,
  el receptor puede aceptarla y no hay conflicto de línea o vía reservada.
- Una operación bloqueada conserva su estado y antigüedad; permite avanzar a
  otras independientes. No retiene recursos que impidan resolver su espera.
- Las reservas se respetan hasta completar su uso. Dos operaciones no pueden
  apropiarse de la misma vía o entrada de buffer.
- Los buffers conservan el orden FIFO de drenado. El forwarding puede retirar
  una entrada del write buffer según [Movimiento de líneas](line-transfers.md).
- La política se aplica tanto a los recursos compartidos de L2 como a las
  lecturas y escrituras que solicitan memoria. Un burst iniciado termina antes
  de comenzar otra transferencia en esa interfaz.

| Caso | Comportamiento esperado |
| --- | --- |
| L1 solicita A antes de que el write buffer solicite instalar B; ambas pueden avanzar | Atender A primero. |
| A espera memoria y B puede usar L2 sin conflicto | B avanza mientras A sigue pendiente; B puede terminar primero. |
| L2 tiene cuatro operaciones pendientes con la configuración por defecto | Esperar a que una termine antes de aceptar otra; conservar el progreso de las pendientes. |
| A necesita desalojar una línea sucia y el eviction buffer está lleno | A espera; el buffer continúa drenando y otras operaciones independientes pueden avanzar. |
| Dos operaciones necesitan la misma vía reservada | La segunda espera hasta que termine la reserva. |
| Una lectura y una escritura de líneas distintas esperan memoria | Elegir la más antigua que pueda avanzar; una transferencia ya iniciada completa su burst. |
| Una lectura coincide con una línea del eviction buffer | Consumir la confirmación de escritura sin error de esa línea antes de emitir la lectura. |

## 6. Memoria principal

La memoria tiene 64 KiB. La CPU opera a 100 MHz y cada burst transfiere una
línea de ocho palabras de 32 bits, a una palabra por ciclo de memoria.

| Parámetro | Valor por defecto | Significado |
| --- | --- | --- |
| `MEM_CLOCK_DIV` | 2 | Ciclos de CPU por ciclo de memoria; determina una frecuencia de 50 MHz. |
| `MEM_READ_FIRST_WORD_CYCLES` | 25 | Ciclos de CPU hasta la primera palabra de lectura. |
| `MEM_WRITE_FIRST_WORD_CYCLES` | 25 | Ciclos de CPU hasta almacenar la primera palabra de escritura. |
| `MEM_TIMEOUT_CYCLES` | 128 | Máximo de ciclos de CPU para completar una transferencia aceptada. |

La relación de relojes y ambas latencias son parametrizables; las latencias de
lectura y escritura se configuran independientemente. El divisor debe producir
una frecuencia de memoria dentro del rango de 20–50 MHz del enunciado.

```text
Tread  = MEM_READ_FIRST_WORD_CYCLES  + 7 × MEM_CLOCK_DIV
Twrite = MEM_WRITE_FIRST_WORD_CYCLES + 7 × MEM_CLOCK_DIV
```

Con los valores por defecto, el modelo es simétrico: ambas operaciones duran
39 ciclos de CPU y transfieren palabras en los ciclos
`25, 27, 29, 31, 33, 35, 37, 39`.

Los tiempos se cuentan desde la aceptación de la transferencia por el controlador
e incluyen el cruce de relojes. Las esperas previas por arbitraje o recursos se
contabilizan aparte. La lectura queda disponible al completar la línea; la
escritura se confirma cuando sus ocho palabras quedan almacenadas. Consumir
esa confirmación sin error libera la entrada correspondiente del eviction buffer.

### Timeout

El enunciado exige timeouts realistas en la sección 3.2.5. Se usa
`MEM_TIMEOUT_CYCLES`, con valor por defecto de 128 y mayor que
`max(Tread, Twrite)` para la configuración elegida.

El conteo comienza al aceptar la transferencia y continúa aunque el núcleo esté
congelado. Termina cuando está disponible la línea completa o la confirmación
de escritura. Excluye la espera previa por arbitraje y el tiempo que el receptor
tarde en consumir una respuesta ya disponible.

Si se alcanza el límite sin finalización disponible, se informa error y se
detiene la simulación con dirección, tipo de operación y ciclos transcurridos.
Una escritura fallida conserva su entrada en el eviction buffer.

| Caso | Resultado |
| --- | --- |
| Transferencia completa en 39 ciclos con la configuración por defecto | Finalización normal. |
| Solicitud todavía esperando turno | El timeout de transferencia no ha comenzado. |
| Transferencia incompleta al alcanzar 128 ciclos | Timeout y diagnóstico de error. |
