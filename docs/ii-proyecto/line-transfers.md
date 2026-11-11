# Movimiento de líneas

**Estado:** propuesta de diseño.

## 1. Propósito

Establece cómo se trasladan las líneas de 32 bytes entre L1, L2 y memoria,
aplicando las [políticas de la jerarquía](hierarchy.md).

## 2. Transferencia y espacio disponible

Cada traslado entre cachés transporta **dirección base de línea, 32 bytes de
datos y dirty**. La dirección base tiene sus cinco bits inferiores en cero.
El receptor acepta la línea en un flanco cuando dispone de almacenamiento para
conservarla. En los traslados sin respuesta separada, ese handshake libera el
origen. En las solicitudes de instalación o escritura con confirmación separada,
aceptar inicia la operación: el buffer conserva la entrada hasta consumir su
confirmación. Hasta poder liberar el origen se conservan los datos y la víctima
seleccionada, sin repetir solicitudes ya aceptadas.

L1 dispone de un espacio de entrada de una línea, reservado antes de solicitarla
al nivel inferior. Permite recibirla aunque su vía destino todavía esté ocupada.
Si la vía está disponible, la línea puede instalarse directamente en el flanco
de entrega, sin un ciclo obligatorio adicional por ese espacio de entrada.

| Traslado | Almacenamiento que permite liberar el origen |
| --- | --- |
| L2 → L1 | Vía disponible o espacio de entrada reservado en L1. |
| L1 → L2 | Entrada aceptada en el write buffer. |
| L2 → memoria | Entrada aceptada en el eviction buffer; la vía de L2 queda libre y el buffer conserva la línea hasta consumir la confirmación de escritura sin error. |

Los buffers conservan la responsabilidad de los datos hasta consumir la
confirmación correspondiente, o hasta que L1 acepte un forwarding del write buffer.
Los conflictos se resuelven según el buffer:

- Antes de consultar L2, se comprueba si la línea está en el write buffer. Si
  coincide y todavía no está en servicio hacia L2, se reenvía completa al espacio de
  entrada de L1 y se retira del buffer al aceptarse, conservando dirty. L1 libera
  su vía destino según el recorrido 3 e instala la línea; después completa el
  load o store. Las entradas restantes mantienen su orden de drenado.
- Si esa entrada ya está en servicio hacia L2, se espera el consumo de su
  confirmación de instalación y después se recupera mediante el recorrido 1.
  El forwarding y el drenado nunca pueden entregar la misma entrada a ambos destinos.
- Antes de leer memoria, se comprueba el eviction buffer. Si coincide, se espera
  el consumo de la confirmación de escritura sin error de esa línea y después
  se solicita la lectura.

Una entrada está **en servicio** desde que se presenta para envío a L2 hasta
que el buffer consume su confirmación de instalación, incluso si L2 todavía no
acepta la transferencia.
Si forwarding y drenado compiten por una entrada que aún no está en servicio,
se prioriza el forwarding. Al aceptarlo L1, la entrada deja de ser válida en el
buffer y no se envía a L2.

| Caso | Comportamiento esperado |
| --- | --- |
| Write buffer contiene `[A, B, C]`; L1 solicita B, aún disponible | B vuelve a L1 con su dirty; quedan `[A, C]`, en ese orden. |
| L1 solicita B cuando ya está en servicio hacia L2 | Esperar el consumo de su confirmación de instalación y recuperarla desde L2. |
| L2 instaló B, pero su confirmación aún no se consume | B sigue ocupando una entrada del write buffer, en servicio y sin forwarding. |
| Memoria va a recibir A desde el eviction buffer y se solicita leer A | Esperar el consumo de la confirmación de escritura sin error de A; después emitir su lectura. |

La comparación usa la dirección base de línea e incluye entradas en servicio.
Durante la espera, los buffers continúan drenando; la solicitud bloqueada no
retiene recursos que necesite ese drenado.

## 3. Recorridos

### 1. Miss L1 y hit L2

1. L1 reserva el espacio de entrada y selecciona su vía destino: inválida o víctima LRU.
2. L2 encuentra la línea y la entrega con su dirty. Al aceptar L1, se invalida en L2.
3. Si la vía destino está ocupada, su víctima sigue el recorrido 3; la línea entrante puede esperar en el espacio reservado.
4. L1 instala la línea y la marca como recientemente usada. En un load devuelve la palabra; en un store aplica la máscara y marca dirty.

La CPU reanuda al consumir la respuesta. Sin contención, se conserva la
penalidad de ocho ciclos adicionales definida en el contrato CPU–memoria.

### 2. Miss en L1 y L2

1. L1 reserva espacio y selecciona su vía destino como en el recorrido 1.
2. Tras determinar su miss, L2 solicita al controlador la línea de memoria.
3. El controlador reúne internamente las ocho palabras del burst. Solo al completar la línea presenta una respuesta de 256 bits al espacio reservado de L1, por el camino de retorno y sin almacenar la línea en L2. No entrega palabras parciales a L1.
4. L1 la instala, inicialmente limpia. Si era un store, modifica los bytes indicados y marca dirty; después responde al núcleo.

La línea obtenida de memoria se instala únicamente en L1. L2 coordina la
petición sin conservar una copia válida de esa línea.

### 3. Desalojo de L1 hacia L2

1. L1 presenta su víctima completa al write buffer, también si está limpia.
2. Cuando el buffer la acepta, L1 invalida la vía y puede reutilizarla.
3. El buffer presenta la línea a L2. L2 usa una vía inválida o selecciona víctima con tree-PLRU; si necesita desalojarla, sigue el recorrido 4.
4. L2 instala la línea conservando dirty y actualiza su información de uso. Presenta la confirmación; solo `wb_done_valid && wb_done_ready` libera la entrada del buffer y el identificador de L2. Aceptar `wb_install` no los libera.

Si el write buffer está lleno, L1 conserva la víctima y espera. La selección
del conjunto de L2 usa la dirección de la víctima; no se supone que coincide
con el conjunto de la línea solicitada por la CPU.

### 4. Desalojo de L2 hacia memoria

1. L2 conserva la víctima elegida hasta poder liberar su vía.
2. Si está limpia, la invalida y reutiliza la vía: memoria ya contiene esos datos.
3. Si está sucia, entrega dirección y línea al eviction buffer. Al aceptarse, L2 invalida la vía y puede reutilizarla.
4. El controlador escribe la línea en memoria. Solo `mem_wr_rsp_valid && mem_wr_rsp_ready && !mem_wr_rsp_error` libera la entrada del eviction buffer. Hasta ese flanco, la línea sigue participando en la búsqueda de conflictos, aunque el burst ya haya terminado. Un error conserva la entrada y sigue la política de timeout.

Si el eviction buffer está lleno, L2 conserva la víctima. Los buffers y el
controlador siguen drenando durante la espera del núcleo.

## 4. Coordinación de los recorridos

Una promoción a L1 puede provocar un desalojo hacia L2 y este, otro hacia
memoria. El espacio de entrada de L1 evita exigir que su víctima ya esté
instalada en L2 para poder recibir la línea solicitada.

Las operaciones compiten según la
[política de avance y arbitraje](hierarchy.md#5-avance-y-arbitraje).

Aceptar una línea en un buffer permite reutilizar su vía de origen; no exige
esperar a que llegue a su destino final. Las solicitudes pendientes se conservan
y las transferencias se realizan una sola vez, aunque haya varios ciclos de espera.
