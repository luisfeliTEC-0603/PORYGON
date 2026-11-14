/**
 * @file l2_perf.sv
 * @brief Generacion de eventos de metricas de L2.
 *
 * @details
 *   UNICO modulo (junto con el top) que depende de pkg_metrics. Los campos
 *   asignados en perf_events_o corresponden EXACTAMENTE a los definidos en
 *   pkg_metrics::l2_events_t:
 *
 *     id_event_t     get_accept   -> .valid, .id
 *     id_event_t     get_done     -> .valid, .id
 *     id_event_t     lookup       -> .valid, .id
 *     logic          lookup_hit   (campo suelto, no dentro de lookup)
 *     line_event_t   promotion    -> .valid, .base, .dirty
 *     line_event_t   clean_discard-> .valid, .base, .dirty
 *     line_event_t   dirty_eviction-> .valid, .base, .dirty
 *     occupancy_t    inflight
 *     occupancy_t    capacity
 *     logic          get_wait
 *     error_event_t  error        (no usado aqui; queda en 0)
 *
 *   Los conceptos que NO tienen campo en l2_events_t se exponen como salidas
 *   separadas del modulo para no perderlos:
 *     - lookup_is_write_o
 *     - install_accept_o / install_accept_id_o
 *     - install_done_o   / install_done_id_o
 *     - inst_wait_o, mem_wait_o, eb_wait_o
 *
 *   El top (o performance_counters) puede consumir estas salidas aparte.
 */

module l2_perf #(
    parameter int AW   = 16,
    parameter int ID_W = 2
) (
    input  logic            get_accept_i,
    input  logic [AW-1:0]   get_base_i,
    input  logic [ID_W-1:0] get_id_i,
    input  logic            fill_hs_i,
    input  logic [AW-1:0]   fill_base_i,
    input  logic            fill_dirty_i,
    input  logic [ID_W-1:0] fill_id_i,
    input  logic            lookup_valid_i,
    input  logic [ID_W-1:0] lookup_id_i,
    input  logic            lookup_hit_i,
    input  logic            lookup_is_write_i,
    input  logic            clean_discard_i,
    input  logic [AW-1:0]   clean_base_i,
    input  logic            evict_i,
    input  logic [AW-1:0]   evict_base_i,
    input  logic            inst_accept_i,
    input  logic [ID_W-1:0] inst_accept_id_i,
    input  logic            inst_done_i,
    input  logic [ID_W-1:0] inst_done_id_i,
    input  logic [7:0]      occupancy_i,
    input  logic [7:0]      capacity_i,
    input  logic            get_wait_i,
    input  logic            inst_wait_i,
    input  logic            mem_wait_i,
    input  logic            eb_wait_i,

    // Eventos empaquetados segun pkg_metrics::l2_events_t
    output pkg_metrics::l2_events_t perf_events_o,

    // Salidas auxiliares para campos sin lugar en l2_events_t
    output logic            lookup_is_write_o,
    output logic            install_accept_o,
    output logic [ID_W-1:0] install_accept_id_o,
    output logic            install_done_o,
    output logic [ID_W-1:0] install_done_id_o,
    output logic            inst_wait_o,
    output logic            mem_wait_o,
    output logic            eb_wait_o
);
    always_comb begin
        perf_events_o = '0;

        // id_event_t: solo valid + id (NO tienen base)
        perf_events_o.get_accept.valid = get_accept_i;
        perf_events_o.get_accept.id    = get_id_i;

        perf_events_o.get_done.valid   = fill_hs_i;
        perf_events_o.get_done.id      = fill_id_i;

        perf_events_o.lookup.valid     = lookup_valid_i;
        perf_events_o.lookup.id        = lookup_id_i;
        perf_events_o.lookup_hit       = lookup_hit_i;   // campo suelto

        // line_event_t: valid + base + dirty
        perf_events_o.promotion.valid      = fill_hs_i;
        perf_events_o.promotion.base       = fill_base_i;
        perf_events_o.promotion.dirty      = fill_dirty_i;

        perf_events_o.clean_discard.valid  = clean_discard_i;
        perf_events_o.clean_discard.base   = clean_base_i;
        perf_events_o.clean_discard.dirty  = 1'b0;

        perf_events_o.dirty_eviction.valid = evict_i;
        perf_events_o.dirty_eviction.base  = evict_base_i;
        perf_events_o.dirty_eviction.dirty = 1'b1;

        // Campos sueltos de estado/ocupacion
        perf_events_o.inflight  = occupancy_i;
        perf_events_o.capacity  = capacity_i;
        perf_events_o.get_wait  = get_wait_i;

        // perf_events_o.error queda en '0 (no hay error de L2 en este modulo)
    end

    // Salidas auxiliares: conceptos no modelados en l2_events_t
    assign lookup_is_write_o   = lookup_is_write_i;
    assign install_accept_o    = inst_accept_i;
    assign install_accept_id_o = inst_accept_id_i;
    assign install_done_o      = inst_done_i;
    assign install_done_id_o   = inst_done_id_i;
    assign inst_wait_o         = inst_wait_i;
    assign mem_wait_o          = mem_wait_i;
    assign eb_wait_o           = eb_wait_i;
endmodule
