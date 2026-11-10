/**
 * @brief Skeleton del observador independiente de eventos y contadores.
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
    // TODO P2-10: seguimiento de demandas/ids, conteos y captura de resultados.
endmodule
