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
 *   lookup y lookup_hit describen solo demandas L1; las instalaciones se
 *   cuentan aparte por install_lookup_o/install_lookup_hit_o para conservar
 *   l2_demands = l2_hits + l2_misses.
 *
 *   get_done se emite para toda demanda finalizada, sea por hit L2 (fill_hs_i)
 *   o por miss (rsp_done_i). Como l2_events_t solo tiene un get_done por ciclo,
 *   una cola pequeña (gd_q, GD_DEPTH entradas) retiene finalizaciones cuando
 *   fill y rsp coinciden o cuando el consumidor no drena en el mismo ciclo.
 *
 *   Sin reset de métricas: las métricas son acumulativas; el consumidor
 *   muestrea diferencias entre ciclos. El reset solo limpia la cola gd_q.
 *
 * @param AW       Ancho de dirección.
 * @param ID_W     Ancho de identificador de operación.
 * @param GD_DEPTH Profundidad de la cola de finalizaciones de demanda.
 *
 * @input  clk_i             Reloj.
 * @input  rst_ni            Reset asíncrono activo bajo.
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
 * @input  rsp_done_i        1 si una demanda miss finalizó al observar mem_rd_rsp.
 * @input  rsp_done_id_i     Id de la demanda miss que finalizó.
 * @input  occupancy_i       Ocupación actual de la tabla (posiciones busy).
 * @input  capacity_i        Capacidad de la tabla (L2_MAX_INFLIGHT).
 * @input  get_wait_i        1 si una demanda espera por falta de slot/conflicto.
 * @input  inst_wait_i       1 si un install espera por falta de slot/conflicto.
 * @input  mem_wait_i        1 si una lectura espera al controlador.
 * @input  eb_wait_i         1 si un eb_push espera al EB.
 *
 * @output perf_events_o       Eventos empaquetados según l2_events_t.
 * @output lookup_is_write_o   Copia de lookup_is_write_i (sin campo en l2_events_t).
 * @output install_accept_o    Copia de inst_accept_i.
 * @output install_accept_id_o Copia de inst_accept_id_i.
 * @output install_done_o      Copia de inst_done_i.
 * @output install_done_id_o   Copia de inst_done_id_i.
 * @output inst_wait_o         Copia de inst_wait_i.
 * @output mem_wait_o          Copia de mem_wait_i.
 * @output install_lookup_o    1 si el lookup es de un install.
 * @output install_lookup_hit_o 1 si el lookup de un install acertó.
 * @output eb_wait_o           Copia de eb_wait_i.
 * @output gd_overflow_o       1 si se intentó encolar una finalización con la cola llena.
 **/

module l2_perf #(
    parameter int AW       = 16,
    parameter int ID_W     = 2,
    parameter int GD_DEPTH = 8
) (
    input  logic            clk_i,
    input  logic            rst_ni,
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
    input  logic            rsp_done_i,
    input  logic [ID_W-1:0] rsp_done_id_i,
    input  logic [7:0]      occupancy_i,
    input  logic [7:0]      capacity_i,
    input  logic            get_wait_i,
    input  logic            inst_wait_i,
    input  logic            mem_wait_i,
    input  logic            eb_wait_i,

    output pkg_metrics::l2_events_t perf_events_o,

    output logic            lookup_is_write_o,
    output logic            install_accept_o,
    output logic [ID_W-1:0] install_accept_id_o,
    output logic            install_done_o,
    output logic [ID_W-1:0] install_done_id_o,
    output logic            inst_wait_o,
    output logic            mem_wait_o,
    output logic            install_lookup_o,
    output logic            install_lookup_hit_o,
    output logic            eb_wait_o,
    output logic            gd_overflow_o
);
    // ------------------------------------------------------------------
    // Cola de finalizaciones de demanda (get_done)
    // ------------------------------------------------------------------
    // l2_events_t solo tiene un get_done por ciclo. fill_hs_i (hit) y
    // rsp_done_i (miss) pueden coincidir; la segunda finalización espera en
    // esta cola y se emite al ciclo siguiente. El ancho del contador se deriva
    // de GD_DEPTH para no acoplar el diseño a un valor fijo.
    localparam int GD_CNT_W = $clog2(GD_DEPTH + 1);

    logic [GD_DEPTH*ID_W-1:0] gd_q, gd_nq;
    logic [GD_CNT_W-1:0]      gd_cnt_q, gd_ncnt;
    logic                     gd_valid, gd_overflow;
    logic [ID_W-1:0]          gd_id, gd_head;

    assign gd_head = gd_q[ID_W-1:0];

    // gd_valid: hay algo que emitir este ciclo (cabeza de cola o evento nuevo).
    // gd_id: la cabeza si la cola no está vacía; si no, el evento del ciclo
    // (fill tiene prioridad sobre rsp cuando ambos coinciden y la cola está vacía).
    always_comb begin
        gd_valid = (gd_cnt_q != '0) || fill_hs_i || rsp_done_i;
        if (gd_cnt_q != '0) gd_id = gd_head;
        else if (fill_hs_i) gd_id = fill_id_i;
        else                gd_id = rsp_done_id_i;
    end

    // Actualización de la cola: se emite la cabeza (si hay), se encolan los
    // eventos nuevos que no se hayan emitido directamente. gd_overflow se
    // activa si se intenta encolar con la cola llena.
    always_comb begin
        gd_nq       = gd_q;
        gd_ncnt     = gd_cnt_q;
        gd_overflow = 1'b0;

        if (gd_cnt_q != '0) begin
            // Se emite la cabeza; se desplaza la cola y se encolan los nuevos
            // eventos (si caben).
            gd_nq   = gd_q >> ID_W;
            gd_ncnt = gd_cnt_q - 1'b1;

            if (fill_hs_i) begin
                if (gd_ncnt < GD_DEPTH) begin
                    gd_nq[gd_ncnt*ID_W +: ID_W] = fill_id_i;
                    gd_ncnt = gd_ncnt + 1'b1;
                end else begin
                    gd_overflow = 1'b1;
                end
            end
            if (rsp_done_i) begin
                if (gd_ncnt < GD_DEPTH) begin
                    gd_nq[gd_ncnt*ID_W +: ID_W] = rsp_done_id_i;
                    gd_ncnt = gd_ncnt + 1'b1;
                end else begin
                    gd_overflow = 1'b1;
                end
            end
        end else if (fill_hs_i && rsp_done_i) begin
            // Cola vacía, ambos eventos coinciden: se emite fill (por gd_id) y
            // se encola rsp para el ciclo siguiente.
            gd_nq[ID_W-1:0] = rsp_done_id_i;
            gd_ncnt         = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            gd_q     <= '0;
            gd_cnt_q <= '0;
        end else begin
            gd_q     <= gd_nq;
            gd_cnt_q <= gd_ncnt;
        end
    end

    assign gd_overflow_o = gd_overflow;

    // ------------------------------------------------------------------
    // Mapeo a pkg_metrics::l2_events_t
    // ------------------------------------------------------------------
    always_comb begin
        perf_events_o = '0;

        // id_event_t: solo valid + id (no llevan base).
        perf_events_o.get_accept.valid = get_accept_i;
        perf_events_o.get_accept.id    = get_id_i;

        perf_events_o.get_done.valid   = gd_valid;
        perf_events_o.get_done.id      = gd_id;

        // lookup y lookup_hit describen solo demandas L1; las instalaciones
        // se cuentan aparte por install_lookup_o/install_lookup_hit_o.
        perf_events_o.lookup.valid     = lookup_valid_i && !lookup_is_write_i;
        perf_events_o.lookup.id        = lookup_id_i;
        perf_events_o.lookup_hit       = lookup_hit_i && !lookup_is_write_i;

        // line_event_t: valid + base + dirty.
        perf_events_o.promotion.valid      = fill_hs_i;
        perf_events_o.promotion.base       = fill_base_i;
        perf_events_o.promotion.dirty      = fill_dirty_i;

        perf_events_o.clean_discard.valid  = clean_discard_i;
        perf_events_o.clean_discard.base   = clean_base_i;
        perf_events_o.clean_discard.dirty  = 1'b0;

        perf_events_o.dirty_eviction.valid = evict_i;
        perf_events_o.dirty_eviction.base  = evict_base_i;
        perf_events_o.dirty_eviction.dirty = 1'b1;

        // Campos sueltos de estado/ocupación.
        perf_events_o.inflight  = occupancy_i;
        perf_events_o.capacity  = capacity_i;
        perf_events_o.get_wait  = get_wait_i;

        // error queda en 0: L2 no reporta error por este módulo.
    end

    // ------------------------------------------------------------------
    // Salidas auxiliares: conceptos no modelados en l2_events_t
    // ------------------------------------------------------------------
    assign lookup_is_write_o    = lookup_is_write_i;
    assign install_lookup_o     = lookup_valid_i && lookup_is_write_i;
    assign install_lookup_hit_o = lookup_valid_i && lookup_is_write_i && lookup_hit_i;
    assign install_accept_o     = inst_accept_i;
    assign install_accept_id_o  = inst_accept_id_i;
    assign install_done_o       = inst_done_i;
    assign install_done_id_o    = inst_done_id_i;
    assign inst_wait_o          = inst_wait_i;
    assign mem_wait_o           = mem_wait_i;
    assign eb_wait_o            = eb_wait_i;
endmodule
