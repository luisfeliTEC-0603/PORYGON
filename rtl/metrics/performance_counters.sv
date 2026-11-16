/**
 * @brief Observador independiente de eventos y contadores.
 * @param L2_MAX_INFLIGHT Capacidad compartida; se conserva por compatibilidad.
 * @param EVICTION_BUFFER_DEPTH Capacidad compartida; se conserva por compatibilidad.
 * @input clk_i, rst_ni Reloj CPU continuo y reset activo bajo.
 * @details Reset borra seguimiento y resultados. start con medicion inactiva
 * y sin operaciones pendientes prepara E0; se cuentan intervalos E0..EN y
 * eventos E1..EN, incluido stop. Un stall no detiene el observador. Las sumas
 * de 64 bits saturan y activan overflow. No se calculan cocientes en hardware.
 * @see docs/ii-proyecto/metrics.md
 */
module performance_counters #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT,
    parameter integer EVICTION_BUFFER_DEPTH = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /**
     * @brief Control del entorno y configuracion de la medicion.
     * @input perf_stop_error_i Marca fin fallido externo, como un watchdog.
     * @details stop incluye el ultimo flanco; el entorno espera terminar el
     * programa y sus operaciones anteriores. El drenado posterior queda fuera.
     */
    input logic perf_start_i,
    input logic perf_stop_i,
    input logic perf_stop_error_i,
    input pkg_metrics::configuration_t configuration_i,

    /** @brief Eventos/muestras sin backpressure, calificados por sus campos. */
    input pkg_metrics::cpu_events_t cpu_events_i,
    input pkg_metrics::l1_events_t l1_events_i,
    input pkg_metrics::l2_events_t l2_events_i,
    input pkg_metrics::wb_events_t wb_events_i,
    input pkg_metrics::eb_events_t eb_events_i,
    input pkg_metrics::mem_events_t mem_events_i,
    input pkg_metrics::error_event_t return_error_i,

    /**
     * @brief Estado y vista de contadores; snapshot_valid califica cierre.
     * @details Al cerrar se incluyen eventos del flanco y trabajo pendiente
     * resultante. Los contadores e instantanea permanecen hasta nuevo inicio
     * o reset. Una instantanea valida tambien puede representar fin fallido.
     */
    output logic perf_running_o,
    output logic perf_snapshot_valid_o,
    output logic perf_overflow_o,
    output logic perf_failed_o,
    output pkg_metrics::snapshot_t perf_snapshot_o
);

    /**
     * @brief Identificadores de los contadores acumulativos.
     * @details Un solo arreglo y una sola suma saturada sirven a todos los
     * grupos, de modo que el desbordamiento se trata en un unico lugar.
     * Cada grupo de metricas agrega aqui sus entradas.
     * @see docs/ii-proyecto/metrics.md seccion 8
     */
    typedef enum int {
        C_CPU_CYCLES, C_CPU_BUNDLES, C_CPU_INSTRUCTIONS,
        C_CPU_NOP_SLOTS, C_CPU_LITERAL_SLOTS,
        C_CPU_STALL, C_CPU_WAIT_ACCEPT, C_CPU_WAIT_MISS, C_CPU_WAIT_RSP,
        C_CPU_BRANCHES, C_CPU_BRANCHES_TAKEN, C_CPU_BRANCH_DELAY,
        C_IF_OCCUPIED, C_IF_TRANSFERS, C_IF_STALLS,
        C_ID_OCCUPIED, C_ID_TRANSFERS, C_ID_STALLS,
        C_EX_OCCUPIED, C_EX_TRANSFERS, C_EX_STALLS,
        C_WB_OCCUPIED, C_WB_TRANSFERS, C_WB_STALLS,
        C_DM_COMPLETED, C_DM_FAILED, C_DM_READS, C_DM_WRITES,
        C_DM_LATENCY, C_DM_READ_LATENCY, C_DM_WRITE_LATENCY,
        C_DM_MISS_WB, C_DM_MISS_L2, C_DM_MISS_MEM,
        C_L1_READS, C_L1_WRITES,
        C_L1_READ_HITS, C_L1_READ_MISSES, C_L1_WRITE_HITS, C_L1_WRITE_MISSES,
        C_L1_INVALID_READS, C_L1_INVALID_WRITES,
        C_L1_EVICT_CLEAN, C_L1_EVICT_DIRTY,
        C_L2_DEMANDS, C_L2_HITS, C_L2_MISSES, C_L2_PROMOTIONS,
        C_L2_EVICT_CLEAN, C_L2_EVICT_DIRTY,
        C_L2_INFLIGHT_SUM, C_L2_FULL, C_L2_GET_WAIT,
        C_WBUF_ENQUEUED, C_WBUF_FORWARDED, C_WBUF_SENT, C_WBUF_INSTALLED,
        C_WBUF_OCC_SUM, C_WBUF_FULL,
        C_WBUF_PUSH_WAIT, C_WBUF_INSTALL_WAIT, C_WBUF_RAW_WAIT,
        C_EB_ENQUEUED, C_EB_SENT, C_EB_WRITTEN,
        C_EB_OCC_SUM, C_EB_FULL, C_EB_PUSH_WAIT, C_EB_RAW_WAIT,
        C_MEM_READS, C_MEM_WRITES, C_MEM_READS_DONE, C_MEM_WRITES_DONE,
        C_MEM_READ_WORDS, C_MEM_WRITE_WORDS,
        C_MEM_READ_CYCLES, C_MEM_WRITE_CYCLES,
        C_MEM_READ_WAIT, C_MEM_WRITE_WAIT,
        C_MEM_READ_RSP_WAIT, C_MEM_WRITE_RSP_WAIT,
        C_MEM_TIMEOUTS, C_MEM_ERRORS,
        C_ERROR_EVENTS,
        C_TOTAL
    } counter_id_e;

    localparam int NUM_COUNTERS = int'(C_TOTAL);

    /**
     * @brief Estado de la ventana de medicion y contadores.
     * @details running_q distingue medicion activa de inactiva y
     * snapshot_valid_q marca que hay resultados congelados. Los contadores
     * solo avanzan con running_q, asi que al cerrar quedan quietos y la vista
     * viva es la instantanea; no se guarda una copia aparte.
     */
    logic running_q;
    logic snapshot_valid_q;
    logic failed_q;
    logic overflow_q;
    /** @brief Configuracion de la ejecucion, capturada al aceptar start. */
    pkg_metrics::configuration_t configuration_q;
    pkg_metrics::counter_t counters_q [NUM_COUNTERS];

    /** @brief Incremento de cada contador en el flanco actual. */
    wire [63:0] delta [NUM_COUNTERS];

    /** @brief Demanda CPU que termino sin error en este flanco. */
    wire demand_ok;

    /** @brief Suma de 65 bits; el bit alto delata el desbordamiento. */
    logic [64:0] wide_sum;

    /**
     * @brief Seguimiento de la demanda CPU en vuelo.
     * @details La LSU mantiene una sola demanda pendiente, asi que basta un
     * registro y no una tabla. El tiempo arranca en la primera presentacion
     * en EX y termina al consumir la respuesta; los ciclos de espera por miss
     * se guardan hasta el cierre para repartirlos segun el origen.
     * @see docs/ii-proyecto/metrics.md seccion 4
     */
    logic demand_active_q;
    logic demand_write_q;
    pkg_metrics::counter_t demand_cycles_q;
    pkg_metrics::counter_t demand_miss_q;

    logic demand_is_write;
    logic demand_miss_cycle;
    pkg_metrics::counter_t demand_cycles_now;
    pkg_metrics::counter_t demand_miss_now;

    /**
     * @brief Errores detectados localmente por los bloques observados.
     * @details Cada bloque emite su propio error_event_t; el controlador de
     * memoria informa el suyo en el resultado de la transferencia. Cualquiera
     * de los dos marca la ejecucion como fallida y conserva la evidencia.
     * @see docs/ii-proyecto/metrics.md seccion 8
     */
    wire [63:0] error_pulses;
    logic memory_failure;
    logic run_failure;

    /** @brief Trabajo pendiente capturado en el flanco de cierre. */
    pkg_metrics::pending_t pending_q;
    pkg_metrics::pending_t pending_after;

    /**
     * @brief Seguimiento agregado de memoria en espacios de lectura/escritura.
     * @details accept inicia una transferencia; complete, incluso con error,
     * la convierte en respuesta pendiente. Solo su consumo retira la respuesta.
     * No se requieren tablas de ids para estos totales: cada pulso ya identifica
     * el tipo de operacion. El entorno inicia la ventana sin trabajo previo.
     */
    typedef struct packed {
        pkg_metrics::occupancy_t reads;
        pkg_metrics::occupancy_t writes;
        pkg_metrics::occupancy_t read_responses;
        pkg_metrics::occupancy_t write_responses;
    } memory_pending_t;
    memory_pending_t memory_pending_q;
    memory_pending_t memory_pending_after;

    /** @brief Maximos de ocupacion; se actualizan por comparacion, no por suma. */
    pkg_metrics::counter_t l2_inflight_max_q;
    pkg_metrics::counter_t wb_occupancy_max_q;
    pkg_metrics::counter_t eb_occupancy_max_q;

    /** @brief Ciclo de congelamiento global atribuible a un miss en curso. */
    assign demand_miss_cycle = cpu_events_i.stall &&
        (cpu_events_i.wait_reason == pkg_metrics::WAIT_MISS);

    /**
     * @details Si la presentacion y el consumo caen en el mismo flanco la
     * demanda dura un ciclo; en general la latencia es
     * flanco_fin - flanco_inicio + 1.
     */
    assign demand_cycles_now = (cpu_events_i.dmem_begin && !demand_active_q)
        ? 64'd1 : demand_cycles_q + 64'd1;
    assign demand_miss_now = demand_miss_q + (demand_miss_cycle ? 64'd1 : 64'd0);
    assign demand_is_write = (cpu_events_i.dmem_begin && !demand_active_q)
        ? cpu_events_i.dmem_write : demand_write_q;

    /**
     * @brief Aceptacion de los controles del entorno.
     * @details start solo exige medicion inactiva: la ausencia de operaciones
     * pendientes la garantiza el entorno. Un cierre por watchdog termina la
     * ventana igual que stop y ademas marca la ejecucion como fallida.
     * @see docs/ii-proyecto/metrics.md seccion 2
     */
    logic start_accepted;
    logic stop_accepted;

    assign start_accepted = perf_start_i && !running_q;
    assign stop_accepted = running_q && (perf_stop_i || perf_stop_error_i);

    /**
     * @brief Estado de memoria despues de los eventos del flanco actual.
     * @details Las muestras reads_pending/writes_pending del controlador
     * conservan tambien operaciones cuya respuesta ya esta disponible. Por eso
     * estos dos grupos se reconstruyen con aceptacion, disponibilidad y consumo,
     * sin confundir tiempo activo con espera de respuesta ni sumar dos veces
     * una finalizacion que coincide con su consumo.
     */
    assign memory_pending_after.reads = memory_pending_q.reads
        + pkg_metrics::occupancy_t'(mem_events_i.accept.valid && !mem_events_i.accept.write)
        - pkg_metrics::occupancy_t'(mem_events_i.complete.valid && !mem_events_i.complete.write);
    assign memory_pending_after.writes = memory_pending_q.writes
        + pkg_metrics::occupancy_t'(mem_events_i.accept.valid && mem_events_i.accept.write)
        - pkg_metrics::occupancy_t'(mem_events_i.complete.valid && mem_events_i.complete.write);
    assign memory_pending_after.read_responses = memory_pending_q.read_responses
        + pkg_metrics::occupancy_t'(mem_events_i.complete.valid && !mem_events_i.complete.write)
        - pkg_metrics::occupancy_t'(mem_events_i.read_rsp_consumed);
    assign memory_pending_after.write_responses = memory_pending_q.write_responses
        + pkg_metrics::occupancy_t'(mem_events_i.complete.valid && mem_events_i.complete.write)
        - pkg_metrics::occupancy_t'(mem_events_i.write_rsp_consumed);

    /**
     * @brief Convierte las muestras del intervalo en pendientes posteriores.
     * @details Aceptar una instalacion/escritura no libera el buffer. WB se
     * retira por forwarding o confirmacion; EB solo por escritura correcta.
     * En L2 se usan los handshakes fisicos de hit, retorno de memoria e
     * instalacion: get_done puede serializar varias finalizaciones y llegar
     * despues de que las posiciones se liberaron. En la referencia sin cache
     * consumir una lectura de memoria no corresponde a ninguna posicion L2.
     * Las sumas/maximos de ocupacion siguen usando la muestra del intervalo.
     */
    assign pending_after.wb_entries = wb_events_i.state.occupancy
        + pkg_metrics::occupancy_t'(wb_events_i.enqueued.valid)
        - pkg_metrics::occupancy_t'(wb_events_i.forwarded.valid)
        - pkg_metrics::occupancy_t'(wb_events_i.install_done.valid);
    assign pending_after.eb_entries = eb_events_i.state.occupancy
        + pkg_metrics::occupancy_t'(eb_events_i.enqueued.valid)
        - pkg_metrics::occupancy_t'(eb_events_i.write_done.valid && !eb_events_i.write_error);
    assign pending_after.l2_inflight = configuration_q.reference_without_cache ? '0
        : l2_events_i.inflight
        + pkg_metrics::occupancy_t'(l2_events_i.get_accept.valid)
        + pkg_metrics::occupancy_t'(wb_events_i.install_accept.valid)
        - pkg_metrics::occupancy_t'(l2_events_i.promotion.valid)
        - pkg_metrics::occupancy_t'(mem_events_i.read_rsp_consumed)
        - pkg_metrics::occupancy_t'(wb_events_i.install_done.valid);
    assign pending_after.mem_reads = memory_pending_after.reads;
    assign pending_after.mem_writes = memory_pending_after.writes;
    assign pending_after.mem_read_responses = memory_pending_after.read_responses;
    assign pending_after.mem_write_responses = memory_pending_after.write_responses;

    /** @brief El seguimiento avanza durante stalls e incorpora el propio stop. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            memory_pending_q <= '0;
        end else if (start_accepted) begin
            memory_pending_q <= '0;
        end else if (running_q) begin
            memory_pending_q <= memory_pending_after;
        end
    end

    /**
     * @brief Incremento de cada contador en el flanco actual.
     * @details Cada contador recibe su delta por asignacion continua. Mantener
     * estas lecturas fuera de un proceso evita que el simulador tenga que
     * inferir una lista de sensibilidad campo por campo sobre las estructuras
     * de eventos.
     */
    assign delta[C_CPU_CYCLES] = 64'd1;
    assign delta[C_CPU_BUNDLES] = {56'd0, cpu_events_i.done_bundles};
    assign delta[C_CPU_INSTRUCTIONS] = {56'd0, cpu_events_i.done_instructions};
    assign delta[C_CPU_NOP_SLOTS] = {56'd0, cpu_events_i.done_nop_slots};
    assign delta[C_CPU_LITERAL_SLOTS] = {56'd0, cpu_events_i.done_literal_slots};

    // La causa del stall llega resuelta y es exclusiva: un ciclo congelado
    // incrementa el total y exactamente una de las tres causas.
    assign delta[C_CPU_STALL] = (cpu_events_i.stall) ? 64'd1 : 64'd0;
    assign delta[C_CPU_WAIT_ACCEPT] =
        (cpu_events_i.stall && cpu_events_i.wait_reason == pkg_metrics::WAIT_ACCEPT) ? 64'd1 : 64'd0;
    assign delta[C_CPU_WAIT_MISS] =
        (cpu_events_i.stall && cpu_events_i.wait_reason == pkg_metrics::WAIT_MISS) ? 64'd1 : 64'd0;
    assign delta[C_CPU_WAIT_RSP] =
        (cpu_events_i.stall && cpu_events_i.wait_reason == pkg_metrics::WAIT_RESPONSE) ? 64'd1 : 64'd0;

    // Un salto se cuenta una vez al completarse; el tomado es subconjunto.
    assign delta[C_CPU_BRANCHES] = (cpu_events_i.branch_done) ? 64'd1 : 64'd0;
    assign delta[C_CPU_BRANCHES_TAKEN] =
        (cpu_events_i.branch_done && cpu_events_i.branch_taken) ? 64'd1 : 64'd0;
    assign delta[C_CPU_BRANCH_DELAY] = (cpu_events_i.branch_delay) ? 64'd1 : 64'd0;

    // Mascaras de etapa: bit 0 IF, 1 ID, 2 EX, 3 WB.
    assign delta[C_IF_OCCUPIED] = (cpu_events_i.stage_occupied[0]) ? 64'd1 : 64'd0;
    assign delta[C_IF_TRANSFERS] = (cpu_events_i.stage_transfers[0]) ? 64'd1 : 64'd0;
    assign delta[C_IF_STALLS] = (cpu_events_i.stage_mem_stalls[0]) ? 64'd1 : 64'd0;
    assign delta[C_ID_OCCUPIED] = (cpu_events_i.stage_occupied[1]) ? 64'd1 : 64'd0;
    assign delta[C_ID_TRANSFERS] = (cpu_events_i.stage_transfers[1]) ? 64'd1 : 64'd0;
    assign delta[C_ID_STALLS] = (cpu_events_i.stage_mem_stalls[1]) ? 64'd1 : 64'd0;
    assign delta[C_EX_OCCUPIED] = (cpu_events_i.stage_occupied[2]) ? 64'd1 : 64'd0;
    assign delta[C_EX_TRANSFERS] = (cpu_events_i.stage_transfers[2]) ? 64'd1 : 64'd0;
    assign delta[C_EX_STALLS] = (cpu_events_i.stage_mem_stalls[2]) ? 64'd1 : 64'd0;
    assign delta[C_WB_OCCUPIED] = (cpu_events_i.stage_occupied[3]) ? 64'd1 : 64'd0;
    assign delta[C_WB_TRANSFERS] = (cpu_events_i.stage_transfers[3]) ? 64'd1 : 64'd0;
    assign delta[C_WB_STALLS] = (cpu_events_i.stage_mem_stalls[3]) ? 64'd1 : 64'd0;

    /**
     * @details La latencia solo se acumula si la demanda termino
     * correctamente, y sus ciclos de espera por miss se cargan al origen que
     * la resolvio. Una demanda fallida conserva su conteo pero no su tiempo.
     */
    assign demand_ok = cpu_events_i.dmem_done && !cpu_events_i.dmem_error;

    assign delta[C_DM_COMPLETED] = (demand_ok) ? 64'd1 : 64'd0;
    assign delta[C_DM_FAILED] = (cpu_events_i.dmem_done && cpu_events_i.dmem_error) ? 64'd1 : 64'd0;
    assign delta[C_DM_READS] = (demand_ok && !demand_is_write) ? 64'd1 : 64'd0;
    assign delta[C_DM_WRITES] = (demand_ok && demand_is_write) ? 64'd1 : 64'd0;
    assign delta[C_DM_LATENCY] = demand_ok ? demand_cycles_now : 64'd0;
    assign delta[C_DM_READ_LATENCY] =
        (demand_ok && !demand_is_write) ? demand_cycles_now : 64'd0;
    assign delta[C_DM_WRITE_LATENCY] =
        (demand_ok && demand_is_write) ? demand_cycles_now : 64'd0;
    assign delta[C_DM_MISS_WB] =
        (demand_ok && cpu_events_i.dmem_origin == pkg_metrics::ORIGIN_WB) ? demand_miss_now : 64'd0;
    assign delta[C_DM_MISS_L2] =
        (demand_ok && cpu_events_i.dmem_origin == pkg_metrics::ORIGIN_L2) ? demand_miss_now : 64'd0;
    assign delta[C_DM_MISS_MEM] =
        (demand_ok && cpu_events_i.dmem_origin == pkg_metrics::ORIGIN_MEMORY) ? demand_miss_now : 64'd0;

    // L1: una solicitud invalida se cuenta como acceso pero no clasifica
    // hit ni miss.
    assign delta[C_L1_READS] = (l1_events_i.access_valid && !l1_events_i.access_write) ? 64'd1 : 64'd0;
    assign delta[C_L1_WRITES] = (l1_events_i.access_valid && l1_events_i.access_write) ? 64'd1 : 64'd0;
    assign delta[C_L1_READ_HITS] = (l1_events_i.access_valid && !l1_events_i.access_write && l1_events_i.access_result == pkg_metrics::ACCESS_HIT) ? 64'd1 : 64'd0;
    assign delta[C_L1_READ_MISSES] = (l1_events_i.access_valid && !l1_events_i.access_write && l1_events_i.access_result == pkg_metrics::ACCESS_MISS) ? 64'd1 : 64'd0;
    assign delta[C_L1_WRITE_HITS] = (l1_events_i.access_valid && l1_events_i.access_write && l1_events_i.access_result == pkg_metrics::ACCESS_HIT) ? 64'd1 : 64'd0;
    assign delta[C_L1_WRITE_MISSES] = (l1_events_i.access_valid && l1_events_i.access_write && l1_events_i.access_result == pkg_metrics::ACCESS_MISS) ? 64'd1 : 64'd0;
    assign delta[C_L1_INVALID_READS] = (l1_events_i.access_valid && !l1_events_i.access_write && l1_events_i.access_result == pkg_metrics::ACCESS_INVALID) ? 64'd1 : 64'd0;
    assign delta[C_L1_INVALID_WRITES] = (l1_events_i.access_valid && l1_events_i.access_write && l1_events_i.access_result == pkg_metrics::ACCESS_INVALID) ? 64'd1 : 64'd0;
    assign delta[C_L1_EVICT_CLEAN] = (l1_events_i.eviction.valid && !l1_events_i.eviction.dirty) ? 64'd1 : 64'd0;
    assign delta[C_L1_EVICT_DIRTY] = (l1_events_i.eviction.valid && l1_events_i.eviction.dirty) ? 64'd1 : 64'd0;

    // L2: la demanda y su busqueda son eventos distintos; las instalaciones
    // de WB no entran en hits ni misses de demanda.
    assign delta[C_L2_DEMANDS] = (l2_events_i.get_accept.valid) ? 64'd1 : 64'd0;
    assign delta[C_L2_HITS] = (l2_events_i.lookup.valid && l2_events_i.lookup_hit) ? 64'd1 : 64'd0;
    assign delta[C_L2_MISSES] = (l2_events_i.lookup.valid && !l2_events_i.lookup_hit) ? 64'd1 : 64'd0;
    assign delta[C_L2_PROMOTIONS] = (l2_events_i.promotion.valid) ? 64'd1 : 64'd0;
    assign delta[C_L2_EVICT_CLEAN] = (l2_events_i.clean_discard.valid) ? 64'd1 : 64'd0;
    assign delta[C_L2_EVICT_DIRTY] = (l2_events_i.dirty_eviction.valid) ? 64'd1 : 64'd0;
    assign delta[C_L2_INFLIGHT_SUM] = {32'd0, l2_events_i.inflight};
    assign delta[C_L2_FULL] = (l2_events_i.capacity != 0 && l2_events_i.inflight == l2_events_i.capacity) ? 64'd1 : 64'd0;
    assign delta[C_L2_GET_WAIT] = (l2_events_i.get_wait) ? 64'd1 : 64'd0;

    // Write buffer: send_wait del estado describe la espera de instalacion.
    assign delta[C_WBUF_ENQUEUED] = (wb_events_i.enqueued.valid) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_FORWARDED] = (wb_events_i.forwarded.valid) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_SENT] = (wb_events_i.install_accept.valid) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_INSTALLED] = (wb_events_i.install_done.valid) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_OCC_SUM] = {32'd0, wb_events_i.state.occupancy};
    assign delta[C_WBUF_FULL] = (wb_events_i.state.capacity != 0 && wb_events_i.state.occupancy == wb_events_i.state.capacity) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_PUSH_WAIT] = (wb_events_i.state.push_wait) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_INSTALL_WAIT] = (wb_events_i.state.send_wait) ? 64'd1 : 64'd0;
    assign delta[C_WBUF_RAW_WAIT] = (wb_events_i.state.raw_wait) ? 64'd1 : 64'd0;

    // Eviction buffer: solo se cuenta como escrita la confirmacion correcta.
    assign delta[C_EB_ENQUEUED] = (eb_events_i.enqueued.valid) ? 64'd1 : 64'd0;
    assign delta[C_EB_SENT] = (eb_events_i.write_accept.valid) ? 64'd1 : 64'd0;
    assign delta[C_EB_WRITTEN] = (eb_events_i.write_done.valid && !eb_events_i.write_error) ? 64'd1 : 64'd0;
    assign delta[C_EB_OCC_SUM] = {32'd0, eb_events_i.state.occupancy};
    assign delta[C_EB_FULL] = (eb_events_i.state.capacity != 0 && eb_events_i.state.occupancy == eb_events_i.state.capacity) ? 64'd1 : 64'd0;
    assign delta[C_EB_PUSH_WAIT] = (eb_events_i.state.push_wait) ? 64'd1 : 64'd0;
    assign delta[C_EB_RAW_WAIT] = (eb_events_i.state.raw_wait) ? 64'd1 : 64'd0;

    // Memoria principal: solo las transferencias correctas cuentan como
    // completas; el timeout y el resto de errores van en categorias separadas
    // y conservan los ciclos y palabras ya consumidos.
    assign delta[C_MEM_READS] = (mem_events_i.accept.valid && !mem_events_i.accept.write) ? 64'd1 : 64'd0;
    assign delta[C_MEM_WRITES] = (mem_events_i.accept.valid && mem_events_i.accept.write) ? 64'd1 : 64'd0;
    assign delta[C_MEM_READS_DONE] = (mem_events_i.complete.valid && !mem_events_i.complete.write && mem_events_i.complete_error == pkg_metrics::ERROR_NONE) ? 64'd1 : 64'd0;
    assign delta[C_MEM_WRITES_DONE] = (mem_events_i.complete.valid && mem_events_i.complete.write && mem_events_i.complete_error == pkg_metrics::ERROR_NONE) ? 64'd1 : 64'd0;
    assign delta[C_MEM_READ_WORDS] = (mem_events_i.word.valid && !mem_events_i.word.write) ? 64'd1 : 64'd0;
    assign delta[C_MEM_WRITE_WORDS] = (mem_events_i.word.valid && mem_events_i.word.write) ? 64'd1 : 64'd0;
    assign delta[C_MEM_READ_CYCLES] = (mem_events_i.read_active) ? 64'd1 : 64'd0;
    assign delta[C_MEM_WRITE_CYCLES] = (mem_events_i.write_active) ? 64'd1 : 64'd0;
    assign delta[C_MEM_READ_WAIT] = (mem_events_i.read_wait) ? 64'd1 : 64'd0;
    assign delta[C_MEM_WRITE_WAIT] = (mem_events_i.write_wait) ? 64'd1 : 64'd0;
    assign delta[C_MEM_READ_RSP_WAIT] = (mem_events_i.read_rsp_wait) ? 64'd1 : 64'd0;
    assign delta[C_MEM_WRITE_RSP_WAIT] = (mem_events_i.write_rsp_wait) ? 64'd1 : 64'd0;
    assign delta[C_MEM_TIMEOUTS] = (mem_events_i.complete.valid && mem_events_i.complete_error == pkg_metrics::ERROR_TIMEOUT) ? 64'd1 : 64'd0;
    assign delta[C_MEM_ERRORS] = (mem_events_i.complete.valid && mem_events_i.complete_error != pkg_metrics::ERROR_NONE && mem_events_i.complete_error != pkg_metrics::ERROR_TIMEOUT) ? 64'd1 : 64'd0;

    // Varios bloques pueden fallar en el mismo flanco, asi que los pulsos se
    // suman en lugar de tratarse como una sola bandera.
    assign error_pulses =
        ((cpu_events_i.instruction_error.valid) ? 64'd1 : 64'd0) +
        ((cpu_events_i.alignment_error.valid) ? 64'd1 : 64'd0) +
        ((l1_events_i.error.valid) ? 64'd1 : 64'd0) +
        ((l2_events_i.error.valid) ? 64'd1 : 64'd0) +
        ((wb_events_i.error.valid) ? 64'd1 : 64'd0) +
        ((eb_events_i.error.valid) ? 64'd1 : 64'd0) +
        ((return_error_i.valid) ? 64'd1 : 64'd0);

    assign delta[C_ERROR_EVENTS] = error_pulses;


    assign memory_failure = mem_events_i.complete.valid &&
        (mem_events_i.complete_error != pkg_metrics::ERROR_NONE);
    assign run_failure = (error_pulses != 64'd0) || memory_failure;

    /**
     * @details El flanco que acepta start es E0 y solo prepara la medicion:
     * no suma ciclo. Cada flanco posterior con running_q activo aplica los
     * deltas, de modo que entre E0 y EN se cuentan N ciclos. En EN running_q
     * todavia vale 1, asi que ese ciclo y sus eventos entran antes de cerrar.
     * Reset tiene prioridad y start gana sobre stop en el mismo flanco.
     * Cada suma se hace con un bit extra: si se desborda, el contador se
     * satura en su maximo y overflow_q queda activo hasta reset o nuevo inicio.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            running_q <= 1'b0;
            snapshot_valid_q <= 1'b0;
            failed_q <= 1'b0;
            overflow_q <= 1'b0;
            configuration_q <= '0;
            for (int i = 0; i < NUM_COUNTERS; i++) begin
                counters_q[i] <= '0;
            end
            l2_inflight_max_q <= '0;
            wb_occupancy_max_q <= '0;
            eb_occupancy_max_q <= '0;
            pending_q <= '0;
        end else if (start_accepted) begin
            running_q <= 1'b1;
            snapshot_valid_q <= 1'b0;
            failed_q <= 1'b0;
            overflow_q <= 1'b0;
            configuration_q <= configuration_i;
            for (int i = 0; i < NUM_COUNTERS; i++) begin
                counters_q[i] <= '0;
            end
            l2_inflight_max_q <= '0;
            wb_occupancy_max_q <= '0;
            eb_occupancy_max_q <= '0;
            pending_q <= '0;
        end else if (running_q) begin
            for (int i = 0; i < NUM_COUNTERS; i++) begin
                wide_sum = {1'b0, counters_q[i]} + {1'b0, delta[i]};
                counters_q[i] <= wide_sum[64] ? '1 : wide_sum[63:0];
                if (wide_sum[64]) begin
                    overflow_q <= 1'b1;
                end
            end
            if ({32'd0, l2_events_i.inflight} > l2_inflight_max_q) begin
                l2_inflight_max_q <= {32'd0, l2_events_i.inflight};
            end
            if ({32'd0, wb_events_i.state.occupancy} > wb_occupancy_max_q) begin
                wb_occupancy_max_q <= {32'd0, wb_events_i.state.occupancy};
            end
            if ({32'd0, eb_events_i.state.occupancy} > eb_occupancy_max_q) begin
                eb_occupancy_max_q <= {32'd0, eb_events_i.state.occupancy};
            end
            if (run_failure) begin
                failed_q <= 1'b1;
            end
            if (stop_accepted) begin
                running_q <= 1'b0;
                snapshot_valid_q <= 1'b1;
                if (perf_stop_error_i) begin
                    failed_q <= 1'b1;
                end
                // El drenado posterior no altera el estado resultante de EN.
                pending_q <= pending_after;
            end
        end
    end

    /**
     * @details El seguimiento solo vive dentro de la ventana. Al consumir la
     * respuesta se libera, incluso si la presentacion ocurrio en ese mismo
     * flanco, porque la latencia ya se publico como delta.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || start_accepted) begin
            demand_active_q <= 1'b0;
            demand_write_q <= 1'b0;
            demand_cycles_q <= '0;
            demand_miss_q <= '0;
        end else if (running_q) begin
            if (cpu_events_i.dmem_done) begin
                demand_active_q <= 1'b0;
                demand_cycles_q <= '0;
                demand_miss_q <= '0;
            end else if (cpu_events_i.dmem_begin || demand_active_q) begin
                demand_active_q <= 1'b1;
                demand_cycles_q <= demand_cycles_now;
                demand_miss_q <= demand_miss_now;
                if (cpu_events_i.dmem_begin && !demand_active_q) begin
                    demand_write_q <= cpu_events_i.dmem_write;
                end
            end
        end
    end

    assign perf_running_o = running_q;
    assign perf_snapshot_valid_o = snapshot_valid_q;
    assign perf_overflow_o = overflow_q;
    assign perf_failed_o = failed_q;

    /** @brief Vista de los registros de la medicion, estable despues de stop. */
    always_comb begin
        perf_snapshot_o = '0;
        perf_snapshot_o.configuration = configuration_q;
        perf_snapshot_o.overflow = overflow_q;
        perf_snapshot_o.failed = failed_q;

        perf_snapshot_o.cpu.cycles = counters_q[C_CPU_CYCLES];
        perf_snapshot_o.cpu.bundles = counters_q[C_CPU_BUNDLES];
        perf_snapshot_o.cpu.instructions = counters_q[C_CPU_INSTRUCTIONS];
        perf_snapshot_o.cpu.nop_slots = counters_q[C_CPU_NOP_SLOTS];
        perf_snapshot_o.cpu.literal_slots = counters_q[C_CPU_LITERAL_SLOTS];
        perf_snapshot_o.cpu.stall_cycles = counters_q[C_CPU_STALL];
        perf_snapshot_o.cpu.wait_accept = counters_q[C_CPU_WAIT_ACCEPT];
        perf_snapshot_o.cpu.wait_miss = counters_q[C_CPU_WAIT_MISS];
        perf_snapshot_o.cpu.wait_rsp = counters_q[C_CPU_WAIT_RSP];
        perf_snapshot_o.cpu.branches = counters_q[C_CPU_BRANCHES];
        perf_snapshot_o.cpu.branches_taken = counters_q[C_CPU_BRANCHES_TAKEN];
        perf_snapshot_o.cpu.branch_delay_cycles = counters_q[C_CPU_BRANCH_DELAY];

        perf_snapshot_o.cpu.stage_if.occupied = counters_q[C_IF_OCCUPIED];
        perf_snapshot_o.cpu.stage_if.transfers = counters_q[C_IF_TRANSFERS];
        perf_snapshot_o.cpu.stage_if.mem_stalls = counters_q[C_IF_STALLS];
        perf_snapshot_o.cpu.stage_id.occupied = counters_q[C_ID_OCCUPIED];
        perf_snapshot_o.cpu.stage_id.transfers = counters_q[C_ID_TRANSFERS];
        perf_snapshot_o.cpu.stage_id.mem_stalls = counters_q[C_ID_STALLS];
        perf_snapshot_o.cpu.stage_ex.occupied = counters_q[C_EX_OCCUPIED];
        perf_snapshot_o.cpu.stage_ex.transfers = counters_q[C_EX_TRANSFERS];
        perf_snapshot_o.cpu.stage_ex.mem_stalls = counters_q[C_EX_STALLS];
        perf_snapshot_o.cpu.stage_wb.occupied = counters_q[C_WB_OCCUPIED];
        perf_snapshot_o.cpu.stage_wb.transfers = counters_q[C_WB_TRANSFERS];
        perf_snapshot_o.cpu.stage_wb.mem_stalls = counters_q[C_WB_STALLS];

        perf_snapshot_o.dmem.completed = counters_q[C_DM_COMPLETED];
        perf_snapshot_o.dmem.failed = counters_q[C_DM_FAILED];
        perf_snapshot_o.dmem.reads_completed = counters_q[C_DM_READS];
        perf_snapshot_o.dmem.writes_completed = counters_q[C_DM_WRITES];
        perf_snapshot_o.dmem.latency_sum = counters_q[C_DM_LATENCY];
        perf_snapshot_o.dmem.read_latency_sum = counters_q[C_DM_READ_LATENCY];
        perf_snapshot_o.dmem.write_latency_sum = counters_q[C_DM_WRITE_LATENCY];
        perf_snapshot_o.dmem.miss_stalls_wb = counters_q[C_DM_MISS_WB];
        perf_snapshot_o.dmem.miss_stalls_l2 = counters_q[C_DM_MISS_L2];
        perf_snapshot_o.dmem.miss_stalls_mem = counters_q[C_DM_MISS_MEM];

        perf_snapshot_o.l1.reads = counters_q[C_L1_READS];
        perf_snapshot_o.l1.writes = counters_q[C_L1_WRITES];
        perf_snapshot_o.l1.read_hits = counters_q[C_L1_READ_HITS];
        perf_snapshot_o.l1.read_misses = counters_q[C_L1_READ_MISSES];
        perf_snapshot_o.l1.write_hits = counters_q[C_L1_WRITE_HITS];
        perf_snapshot_o.l1.write_misses = counters_q[C_L1_WRITE_MISSES];
        perf_snapshot_o.l1.invalid_reads = counters_q[C_L1_INVALID_READS];
        perf_snapshot_o.l1.invalid_writes = counters_q[C_L1_INVALID_WRITES];
        perf_snapshot_o.l1.evictions_clean = counters_q[C_L1_EVICT_CLEAN];
        perf_snapshot_o.l1.evictions_dirty = counters_q[C_L1_EVICT_DIRTY];

        perf_snapshot_o.l2.demands = counters_q[C_L2_DEMANDS];
        perf_snapshot_o.l2.hits = counters_q[C_L2_HITS];
        perf_snapshot_o.l2.misses = counters_q[C_L2_MISSES];
        perf_snapshot_o.l2.promotions = counters_q[C_L2_PROMOTIONS];
        perf_snapshot_o.l2.evictions_clean = counters_q[C_L2_EVICT_CLEAN];
        perf_snapshot_o.l2.evictions_dirty = counters_q[C_L2_EVICT_DIRTY];
        perf_snapshot_o.l2.inflight_sum = counters_q[C_L2_INFLIGHT_SUM];
        perf_snapshot_o.l2.inflight_max = l2_inflight_max_q;
        perf_snapshot_o.l2.full_cycles = counters_q[C_L2_FULL];
        perf_snapshot_o.l2.get_wait_cycles = counters_q[C_L2_GET_WAIT];

        perf_snapshot_o.wb.enqueued = counters_q[C_WBUF_ENQUEUED];
        perf_snapshot_o.wb.forwarded = counters_q[C_WBUF_FORWARDED];
        perf_snapshot_o.wb.sent = counters_q[C_WBUF_SENT];
        perf_snapshot_o.wb.installed = counters_q[C_WBUF_INSTALLED];
        perf_snapshot_o.wb.occupancy_sum = counters_q[C_WBUF_OCC_SUM];
        perf_snapshot_o.wb.occupancy_max = wb_occupancy_max_q;
        perf_snapshot_o.wb.full_cycles = counters_q[C_WBUF_FULL];
        perf_snapshot_o.wb.push_wait_cycles = counters_q[C_WBUF_PUSH_WAIT];
        perf_snapshot_o.wb.install_wait_cycles = counters_q[C_WBUF_INSTALL_WAIT];
        perf_snapshot_o.wb.raw_wait_cycles = counters_q[C_WBUF_RAW_WAIT];

        perf_snapshot_o.eb.enqueued = counters_q[C_EB_ENQUEUED];
        perf_snapshot_o.eb.sent = counters_q[C_EB_SENT];
        perf_snapshot_o.eb.written = counters_q[C_EB_WRITTEN];
        perf_snapshot_o.eb.occupancy_sum = counters_q[C_EB_OCC_SUM];
        perf_snapshot_o.eb.occupancy_max = eb_occupancy_max_q;
        perf_snapshot_o.eb.full_cycles = counters_q[C_EB_FULL];
        perf_snapshot_o.eb.push_wait_cycles = counters_q[C_EB_PUSH_WAIT];
        perf_snapshot_o.eb.raw_wait_cycles = counters_q[C_EB_RAW_WAIT];

        perf_snapshot_o.mem.reads = counters_q[C_MEM_READS];
        perf_snapshot_o.mem.writes = counters_q[C_MEM_WRITES];
        perf_snapshot_o.mem.reads_complete = counters_q[C_MEM_READS_DONE];
        perf_snapshot_o.mem.writes_complete = counters_q[C_MEM_WRITES_DONE];
        perf_snapshot_o.mem.read_words = counters_q[C_MEM_READ_WORDS];
        perf_snapshot_o.mem.write_words = counters_q[C_MEM_WRITE_WORDS];
        perf_snapshot_o.mem.read_cycles = counters_q[C_MEM_READ_CYCLES];
        perf_snapshot_o.mem.write_cycles = counters_q[C_MEM_WRITE_CYCLES];
        perf_snapshot_o.mem.read_wait_cycles = counters_q[C_MEM_READ_WAIT];
        perf_snapshot_o.mem.write_wait_cycles = counters_q[C_MEM_WRITE_WAIT];
        perf_snapshot_o.mem.read_rsp_wait_cycles = counters_q[C_MEM_READ_RSP_WAIT];
        perf_snapshot_o.mem.write_rsp_wait_cycles = counters_q[C_MEM_WRITE_RSP_WAIT];
        perf_snapshot_o.mem.timeouts = counters_q[C_MEM_TIMEOUTS];
        perf_snapshot_o.mem.errors = counters_q[C_MEM_ERRORS];

        perf_snapshot_o.error_events = counters_q[C_ERROR_EVENTS];
        perf_snapshot_o.pending = pending_q;
    end
endmodule
