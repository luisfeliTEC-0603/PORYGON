/**
 * @brief Observador independiente de eventos y contadores.
 * @param L2_MAX_INFLIGHT Tamano del seguimiento de lecturas identificadas.
 * @param EVICTION_BUFFER_DEPTH Tamano del seguimiento de escrituras.
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
    pkg_metrics::counter_t counters_q [NUM_COUNTERS];

    /** @brief Incremento de cada contador en el flanco actual. */
    pkg_metrics::counter_t delta [NUM_COUNTERS];

    /** @brief Suma de 65 bits; el bit alto delata el desbordamiento. */
    logic [64:0] wide_sum;

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
     * @brief Deltas del nucleo para el flanco actual.
     * @details Los deltas done_* son de ocho bits y admiten varias
     * finalizaciones en un mismo flanco, por eso se extienden con ceros en
     * lugar de tratarse como banderas. El ciclo se cuenta siempre que la
     * ventana este activa, incluso durante un congelamiento global.
     */
    always_comb begin
        for (int i = 0; i < NUM_COUNTERS; i++) begin
            delta[i] = '0;
        end

        delta[C_CPU_CYCLES] = 64'd1;
        delta[C_CPU_BUNDLES] = {56'd0, cpu_events_i.done_bundles};
        delta[C_CPU_INSTRUCTIONS] = {56'd0, cpu_events_i.done_instructions};
        delta[C_CPU_NOP_SLOTS] = {56'd0, cpu_events_i.done_nop_slots};
        delta[C_CPU_LITERAL_SLOTS] = {56'd0, cpu_events_i.done_literal_slots};

        // La causa del stall ya llega resuelta y es exclusiva: un ciclo
        // congelado incrementa el total y exactamente una de las tres causas.
        if (cpu_events_i.stall) begin
            delta[C_CPU_STALL] = 64'd1;
            case (cpu_events_i.wait_reason)
                pkg_metrics::WAIT_ACCEPT: delta[C_CPU_WAIT_ACCEPT] = 64'd1;
                pkg_metrics::WAIT_MISS: delta[C_CPU_WAIT_MISS] = 64'd1;
                pkg_metrics::WAIT_RESPONSE: delta[C_CPU_WAIT_RSP] = 64'd1;
                default: ;
            endcase
        end

        // Un salto se cuenta una vez al completarse; el tomado es subconjunto.
        delta[C_CPU_BRANCHES] = cpu_events_i.branch_done ? 64'd1 : 64'd0;
        delta[C_CPU_BRANCHES_TAKEN] =
            (cpu_events_i.branch_done && cpu_events_i.branch_taken) ? 64'd1 : 64'd0;
        delta[C_CPU_BRANCH_DELAY] = cpu_events_i.branch_delay ? 64'd1 : 64'd0;

        // Mascaras de etapa: bit 0 IF, 1 ID, 2 EX, 3 WB.
        delta[C_IF_OCCUPIED] = cpu_events_i.stage_occupied[0] ? 64'd1 : 64'd0;
        delta[C_IF_TRANSFERS] = cpu_events_i.stage_transfers[0] ? 64'd1 : 64'd0;
        delta[C_IF_STALLS] = cpu_events_i.stage_mem_stalls[0] ? 64'd1 : 64'd0;
        delta[C_ID_OCCUPIED] = cpu_events_i.stage_occupied[1] ? 64'd1 : 64'd0;
        delta[C_ID_TRANSFERS] = cpu_events_i.stage_transfers[1] ? 64'd1 : 64'd0;
        delta[C_ID_STALLS] = cpu_events_i.stage_mem_stalls[1] ? 64'd1 : 64'd0;
        delta[C_EX_OCCUPIED] = cpu_events_i.stage_occupied[2] ? 64'd1 : 64'd0;
        delta[C_EX_TRANSFERS] = cpu_events_i.stage_transfers[2] ? 64'd1 : 64'd0;
        delta[C_EX_STALLS] = cpu_events_i.stage_mem_stalls[2] ? 64'd1 : 64'd0;
        delta[C_WB_OCCUPIED] = cpu_events_i.stage_occupied[3] ? 64'd1 : 64'd0;
        delta[C_WB_TRANSFERS] = cpu_events_i.stage_transfers[3] ? 64'd1 : 64'd0;
        delta[C_WB_STALLS] = cpu_events_i.stage_mem_stalls[3] ? 64'd1 : 64'd0;
    end

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
            for (int i = 0; i < NUM_COUNTERS; i++) begin
                counters_q[i] <= '0;
            end
        end else if (start_accepted) begin
            running_q <= 1'b1;
            snapshot_valid_q <= 1'b0;
            failed_q <= 1'b0;
            overflow_q <= 1'b0;
            for (int i = 0; i < NUM_COUNTERS; i++) begin
                counters_q[i] <= '0;
            end
        end else if (running_q) begin
            for (int i = 0; i < NUM_COUNTERS; i++) begin
                wide_sum = {1'b0, counters_q[i]} + {1'b0, delta[i]};
                counters_q[i] <= wide_sum[64] ? '1 : wide_sum[63:0];
                if (wide_sum[64]) begin
                    overflow_q <= 1'b1;
                end
            end
            if (stop_accepted) begin
                running_q <= 1'b0;
                snapshot_valid_q <= 1'b1;
                failed_q <= perf_stop_error_i;
            end
        end
    end

    assign perf_running_o = running_q;
    assign perf_snapshot_valid_o = snapshot_valid_q;
    assign perf_overflow_o = overflow_q;
    assign perf_failed_o = failed_q;

    /** @details Los grupos sin contadores todavia se publican en cero. */
    always_comb begin
        perf_snapshot_o = '0;
        perf_snapshot_o.configuration = configuration_i;
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
    end
endmodule
