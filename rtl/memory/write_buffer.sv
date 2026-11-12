`timescale 1ns/1ps

/**
 * @brief Buffer FIFO L1 -> L2 con forwarding por direccion base y drenado identificado.
 * @param WRITE_BUFFER_DEPTH Capacidad en lineas; cuatro por defecto.
 * @param L2_MAX_INFLIGHT Limite 1..4; determina el ancho de ids de instalacion.
 * @details Las entradas validas ocupan posiciones contiguas [0 .. count_q-1] en
 * orden FIFO (indice 0 es la mas antigua). Una entrada entra en servicio al
 * presentar wb_install_valid_o, aun antes de ready. Forwarding gana si ambos
 * intentan iniciar sobre una entrada libre; una entrada en servicio espera wb_done.
 * @see docs/ii-proyecto/interfaces.md secciones 2 y 4.
 * @see docs/ii-proyecto/line-transfers.md seccion 2.
 */
module write_buffer #(
    parameter integer WRITE_BUFFER_DEPTH = pkg_memory::WRITE_BUFFER_DEPTH_DEFAULT,
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /** @brief Acepta victima limpia/sucia; conserva base, 32 bytes y dirty. */
    input logic wb_push_valid_i,
    output logic wb_push_ready_o,
    input pkg_memory::address_t wb_push_base_i,
    input pkg_memory::line_t wb_push_data_i,
    input logic wb_push_dirty_i,

    /** @brief Consulta sin handshake; incluye entradas en servicio. */
    input logic wb_probe_valid_i,
    input pkg_memory::address_t wb_probe_base_i,
    output logic wb_probe_hit_o,
    output logic wb_probe_busy_o,

    /** @brief Forwarding completo; al aceptar L1 se retira esa entrada. */
    output logic wb_fwd_valid_o,
    input logic wb_fwd_ready_i,
    output pkg_memory::address_t wb_fwd_base_o,
    output pkg_memory::line_t wb_fwd_data_o,
    output logic wb_fwd_dirty_o,

    /**
     * @brief Drenado FIFO con confirmaciones identificadas de L2.
     * @details Al aceptar install se guarda accept_id y se puede presentar la
     * siguiente entrada. La entrada se libera al consumir done, fuera de orden
     * si corresponde, conservando el orden relativo de las restantes.
     */
    output logic wb_install_valid_o,
    input logic wb_install_ready_i,
    output pkg_memory::address_t wb_install_base_o,
    output pkg_memory::line_t wb_install_data_o,
    output logic wb_install_dirty_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] wb_install_accept_id_i,
    input logic wb_done_valid_i,
    output logic wb_done_ready_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] wb_done_id_i,

    /** @brief Pulsos de entrega y estado de ocupacion, siempre en reloj CPU. */
    output pkg_metrics::wb_events_t perf_events_o
);
    localparam integer L2_ID_W = pkg_memory::id_width(L2_MAX_INFLIGHT);
    localparam integer COUNT_W = $clog2(WRITE_BUFFER_DEPTH + 1);
    localparam integer IDX_W = (WRITE_BUFFER_DEPTH > 1) ? $clog2(WRITE_BUFFER_DEPTH) : 1;

    /**
     * @brief Frontera de reset para las ofertas y aceptaciones del Write Buffer.
     * @details Con rst_ni=0, WB baja su lado de cada canal para impedir
     * transferencias aunque el vecino este activo.
     */
    logic push_ready_internal;
    logic fwd_valid_internal;
    logic install_valid_internal;
    logic done_ready_internal;
    logic wb_push_handshake;
    logic wb_fwd_handshake;

    assign wb_push_ready_o = rst_ni && push_ready_internal;
    assign wb_fwd_valid_o = rst_ni && fwd_valid_internal;
    assign wb_install_valid_o = rst_ni && install_valid_internal;
    assign wb_done_ready_o = rst_ni && done_ready_internal;
    assign wb_push_handshake = wb_push_valid_i && wb_push_ready_o;
    assign wb_fwd_handshake = wb_fwd_valid_o && wb_fwd_ready_i;

    /** @brief Vectores empaquetados por profundidad para evitar warnings en Icarus. */
    logic [WRITE_BUFFER_DEPTH-1:0] entry_valid_q;
    pkg_memory::address_t entry_base_q [0:WRITE_BUFFER_DEPTH-1];
    pkg_memory::line_t entry_data_q [0:WRITE_BUFFER_DEPTH-1];
    logic [WRITE_BUFFER_DEPTH-1:0] entry_dirty_q;
    logic [WRITE_BUFFER_DEPTH-1:0] entry_inflight_q;
    logic [WRITE_BUFFER_DEPTH-1:0] entry_id_valid_q;
    logic [L2_ID_W-1:0] entry_l2_id_q [0:WRITE_BUFFER_DEPTH-1];
    logic [COUNT_W-1:0] count_q;

    /** @brief Retencion de oferta de forwarding mientras !wb_fwd_ready_i. */
    logic fwd_active_q;
    logic [IDX_W-1:0] fwd_held_idx_q;

    /** @brief Senales combinacionales de busqueda probe y seleccion forwarding. */
    logic probe_hit;
    logic probe_busy;
    logic [IDX_W-1:0] probe_idx;
    logic [IDX_W-1:0] fwd_idx;

    always_comb begin
        probe_hit = 1'b0;
        probe_busy = 1'b0;
        probe_idx = '0;
        if (wb_probe_valid_i) begin
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                if (!probe_hit && entry_valid_q[idx] &&
                    (entry_base_q[idx] == wb_probe_base_i)) begin
                    probe_hit = 1'b1;
                    probe_busy = entry_inflight_q[idx];
                    for (integer bit_i = 0; bit_i < IDX_W; bit_i++) begin
                        probe_idx[bit_i] = idx[bit_i];
                    end
                end
            end
        end
    end

    /** @brief Control combinacional de capacidad, probe, forwarding y metricas (WB-2/WB-3). */
    always_comb begin
        push_ready_internal = (count_q < COUNT_W'(WRITE_BUFFER_DEPTH));
        fwd_valid_internal = 1'b0;
        install_valid_internal = 1'b0;
        done_ready_internal = 1'b0;

        wb_probe_hit_o = rst_ni && probe_hit;
        wb_probe_busy_o = rst_ni && probe_hit && probe_busy;
        wb_fwd_base_o = 32'b0;
        wb_fwd_data_o = '0;
        wb_fwd_dirty_o = 1'b0;
        wb_install_base_o = 32'b0;
        wb_install_data_o = '0;
        wb_install_dirty_o = 1'b0;
        fwd_idx = '0;

        if (fwd_active_q) begin
            fwd_valid_internal = 1'b1;
            fwd_idx = fwd_held_idx_q;
            wb_fwd_base_o = entry_base_q[fwd_held_idx_q];
            wb_fwd_data_o = entry_data_q[fwd_held_idx_q];
            wb_fwd_dirty_o = entry_dirty_q[fwd_held_idx_q];
        end else if (probe_hit && !probe_busy) begin
            fwd_valid_internal = 1'b1;
            fwd_idx = probe_idx;
            wb_fwd_base_o = entry_base_q[probe_idx];
            wb_fwd_data_o = entry_data_q[probe_idx];
            wb_fwd_dirty_o = entry_dirty_q[probe_idx];
        end

        perf_events_o = '0;
        perf_events_o.state.occupancy = {{(32 - COUNT_W){1'b0}}, count_q};
        perf_events_o.state.capacity = WRITE_BUFFER_DEPTH;
        perf_events_o.state.push_wait = wb_push_valid_i && !wb_push_ready_o;
        perf_events_o.state.raw_wait = wb_probe_valid_i && probe_hit && probe_busy;

        if (wb_push_handshake) begin
            perf_events_o.enqueued.valid = 1'b1;
            perf_events_o.enqueued.base = wb_push_base_i;
            perf_events_o.enqueued.dirty = wb_push_dirty_i;
        end
        if (wb_fwd_handshake) begin
            perf_events_o.forwarded.valid = 1'b1;
            perf_events_o.forwarded.base = wb_fwd_base_o;
            perf_events_o.forwarded.dirty = wb_fwd_dirty_o;
        end
    end

    /** @brief Actualizacion sincrona: reset, retencion fwd, compactacion e insercion. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            count_q <= '0;
            fwd_active_q <= 1'b0;
            fwd_held_idx_q <= '0;
            entry_valid_q <= '0;
            entry_dirty_q <= '0;
            entry_inflight_q <= '0;
            entry_id_valid_q <= '0;
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                entry_base_q[idx] <= 32'b0;
                entry_data_q[idx] <= '0;
                entry_l2_id_q[idx] <= '0;
            end
        end else begin
            logic [COUNT_W-1:0] next_count;
            next_count = count_q;

            if (wb_fwd_handshake) begin
                fwd_active_q <= 1'b0;
            end else if (wb_fwd_valid_o && !wb_fwd_ready_i && !fwd_active_q) begin
                fwd_active_q <= 1'b1;
                fwd_held_idx_q <= probe_idx;
            end

            if (wb_fwd_handshake) begin
                for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                    if (idx >= integer'(fwd_idx)) begin
                        if ((idx + 1) < WRITE_BUFFER_DEPTH) begin
                            entry_valid_q[idx] <= entry_valid_q[idx + 1];
                            entry_base_q[idx] <= entry_base_q[idx + 1];
                            entry_data_q[idx] <= entry_data_q[idx + 1];
                            entry_dirty_q[idx] <= entry_dirty_q[idx + 1];
                            entry_inflight_q[idx] <= entry_inflight_q[idx + 1];
                            entry_id_valid_q[idx] <= entry_id_valid_q[idx + 1];
                            entry_l2_id_q[idx] <= entry_l2_id_q[idx + 1];
                        end else begin
                            entry_valid_q[idx] <= 1'b0;
                            entry_base_q[idx] <= 32'b0;
                            entry_data_q[idx] <= '0;
                            entry_dirty_q[idx] <= 1'b0;
                            entry_inflight_q[idx] <= 1'b0;
                            entry_id_valid_q[idx] <= 1'b0;
                            entry_l2_id_q[idx] <= '0;
                        end
                    end
                end
                next_count = next_count - COUNT_W'(1);
            end

            if (wb_push_handshake) begin
                entry_valid_q[next_count[IDX_W-1:0]] <= 1'b1;
                entry_base_q[next_count[IDX_W-1:0]] <= wb_push_base_i;
                entry_data_q[next_count[IDX_W-1:0]] <= wb_push_data_i;
                entry_dirty_q[next_count[IDX_W-1:0]] <= wb_push_dirty_i;
                entry_inflight_q[next_count[IDX_W-1:0]] <= 1'b0;
                entry_id_valid_q[next_count[IDX_W-1:0]] <= 1'b0;
                entry_l2_id_q[next_count[IDX_W-1:0]] <= '0;
                next_count = next_count + COUNT_W'(1);
            end

            count_q <= next_count;
        end
    end

    // Siguiente paso: implementar WB-4 (drenado FIFO wb_install, prioridad fwd y wb_done fuera de orden).
endmodule