/**
 * @file l2_perf.sv
 * @brief Generacion de eventos de metricas de L2.
 *
 * @details
 *   UNICO modulo (junto con el top) que depende de pkg_metrics. Los nombres
 *   de campo de l2_events_t estan tomados del diseno previo; si
 *   docs/ii-proyecto/metrics.md define otros, solo hay que adaptar este bloque.
 *
 *   Ademas de perf_events_o, expone tres pulsos para metricas de MSHR que
 *   no tienen campo en l2_events_t:
 *     - mshr_alloc_o   : se asigno una entrada MSHR (miss nuevo).
 *     - mshr_hit_o     : una demanda se engancho a una entrada existente.
 *     - mshr_release_o : se libero una entrada MSHR.
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
    input  logic            mshr_alloc_i,
    input  logic            mshr_hit_i,
    input  logic            mshr_release_i,
    output pkg_metrics::l2_events_t perf_events_o,
    output logic            mshr_alloc_o,
    output logic            mshr_hit_o,
    output logic            mshr_release_o
);
    always_comb begin
        perf_events_o = '0;
        perf_events_o.get_accept.valid  = get_accept_i;
        perf_events_o.get_accept.base   = get_base_i;
        perf_events_o.get_accept.id     = get_id_i;
        perf_events_o.get_done.valid    = fill_hs_i;
        perf_events_o.get_done.base     = fill_base_i;
        perf_events_o.get_done.id       = fill_id_i;
        perf_events_o.lookup.valid      = lookup_valid_i;
        perf_events_o.lookup.id         = lookup_id_i;
        perf_events_o.lookup.hit        = lookup_hit_i;
        perf_events_o.lookup.is_write   = lookup_is_write_i;
        perf_events_o.promotion.valid   = fill_hs_i;
        perf_events_o.promotion.base    = fill_base_i;
        perf_events_o.clean_discard.valid = clean_discard_i;
        perf_events_o.clean_discard.base  = clean_base_i;
        perf_events_o.eviction.valid    = evict_i;
        perf_events_o.eviction.base     = evict_base_i;
        perf_events_o.install_accept.valid = inst_accept_i;
        perf_events_o.install_accept.id    = inst_accept_id_i;
        perf_events_o.install_done.valid   = inst_done_i;
        perf_events_o.install_done.id      = inst_done_id_i;
        perf_events_o.state.occupancy    = occupancy_i;
        perf_events_o.state.capacity     = capacity_i;
        perf_events_o.state.get_wait     = get_wait_i;
        perf_events_o.state.install_wait = inst_wait_i;
        perf_events_o.state.mem_wait     = mem_wait_i;
        perf_events_o.state.eb_wait      = eb_wait_i;
    end

    assign mshr_alloc_o   = mshr_alloc_i;
    assign mshr_hit_o     = mshr_hit_i;
    assign mshr_release_o = mshr_release_i;
endmodule
