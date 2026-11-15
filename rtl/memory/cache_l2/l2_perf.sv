/**
 * @file l2_perf.sv
 * @brief Generación de eventos de métricas de L2.
 *
 * @details
 *   Único módulo (junto con el top) que depende de pkg_metrics. Mapea señales
 *   del top a los campos de pkg_metrics::l2_events_t:
 *     get_accept, get_done, lookup (id_event_t: valid + id)
 *     lookup_hit (campo suelto, no dentro de lookup)
 *     promotion, clean_discard, dirty_eviction (line_event_t: valid + base + dirty)
 *     inflight, capacity (occupancy_t), get_wait (logic)
 *     error (error_event_t, queda en 0: L2 no reporta error por este módulo)
 *
 *   Los conceptos sin campo en l2_events_t se exponen como salidas auxiliares
 *   para no perderlos: lookup_is_write, install_accept/id, install_done/id,
 *   inst_wait, mem_wait, eb_wait.
 *
 *   Sin reset: las métricas son acumulativas; el consumidor muestrea
 *   diferencias entre ciclos.
 *
 * @param AW   Ancho de dirección.
 * @param ID_W Ancho de identificador de operación.
 *
 * @input  get_accept_i      1 si se aceptó una demanda.
 * @input  get_base_i        Base de la demanda aceptada.
 * @input  get_id_i          Id de la demanda aceptada.
 * @input  fill_hs_i         1 en el handshake de fill (hit L2 entregado a L1).
 * @input  fill_base_i       Base de la línea entregada por fill.
 * @input  fill_dirty_i      Dirty de la línea entregada por fill.
 * @input  fill_id_i         Id de la operación que completó fill.
 * @input  lookup_valid_i    1 si hay un lookup en la etapa de tags.
 * @input  lookup_id_i       Id de la operación en lookup.
 * @input  lookup_hit_i      1 si el lookup acertó.
 * @input  lookup_is_write_i 1 si el lookup corresponde a un install.
 * @input  clean_discard_i   1 si se descartó una víctima limpia.
 * @input  clean_base_i      Base de la víctima limpia descartada.
 * @input  evict_i           1 si se empujó una víctima sucia al EB.
 * @input  evict_base_i      Base de la víctima sucia empujada.
 * @input  inst_accept_i     1 si se aceptó un install.
 * @input  inst_accept_id_i  Id del install aceptado.
 * @input  inst_done_i       1 si un install completó (wb_done handshake).
 * @input  inst_done_id_i    Id del install completado.
 * @input  occupancy_i       Ocupación actual de la tabla (posiciones busy).
 * @input  capacity_i        Capacidad de la tabla (L2_MAX_INFLIGHT).
 * @input  get_wait_i        1 si una demanda espera por falta de slot/conflicto.
 * @input  inst_wait_i       1 si un install espera por falta de slot/conflicto.
 * @input  mem_wait_i        1 si una lectura espera al controlador.
 * @input  eb_wait_i         1 si un eb_push espera al EB.
 *
 * @output perf_events_o      Eventos empaquetados según l2_events_t.
 * @output lookup_is_write_o  Copia de lookup_is_write_i (sin campo en l2_events_t).
 * @output install_accept_o   Copia de inst_accept_i.
 * @output install_accept_id_o Copia de inst_accept_id_i.
 * @output install_done_o     Copia de inst_done_i.
 * @output install_done_id_o  Copia de inst_done_id_i.
 * @output inst_wait_o        Copia de inst_wait_i.
 * @output mem_wait_o         Copia de mem_wait_i.
 * @output eb_wait_o          Copia de eb_wait_i.
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

        // id_event_t: solo valid + id
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
