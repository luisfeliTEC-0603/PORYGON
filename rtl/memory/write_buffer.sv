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

    logic push_ready_internal;
    logic fwd_valid_internal;
    logic install_valid_internal;
    logic done_ready_internal;

    logic wb_push_handshake;
    logic wb_fwd_handshake;
    logic wb_install_handshake;
    logic wb_done_handshake;

    assign wb_push_ready_o = rst_ni && push_ready_internal;
    assign wb_fwd_valid_o = rst_ni && fwd_valid_internal;
    assign wb_install_valid_o = rst_ni && install_valid_internal;
    assign wb_done_ready_o = rst_ni && done_ready_internal;

    assign wb_push_handshake = wb_push_valid_i && wb_push_ready_o;
    assign wb_fwd_handshake = wb_fwd_valid_o && wb_fwd_ready_i;
    assign wb_install_handshake = wb_install_valid_o && wb_install_ready_i;
    assign wb_done_handshake = wb_done_valid_i && wb_done_ready_o;

    /** @brief Vectores empaquetados por profundidad para evitar warnings en Icarus. */
    logic [WRITE_BUFFER_DEPTH-1:0] entry_valid_q;
    pkg_memory::address_t entry_base_q [0:WRITE_BUFFER_DEPTH-1];
    pkg_memory::line_t entry_data_q [0:WRITE_BUFFER_DEPTH-1];
    logic [WRITE_BUFFER_DEPTH-1:0] entry_dirty_q;
    logic [WRITE_BUFFER_DEPTH-1:0] entry_inflight_q;
    logic [WRITE_BUFFER_DEPTH-1:0] entry_id_valid_q;
    logic [L2_ID_W-1:0] entry_l2_id_q [0:WRITE_BUFFER_DEPTH-1];
    logic [COUNT_W-1:0] count_q;

    /** @brief Retencion de ofertas wb_fwd y wb_install hasta handshake. */
    logic fwd_active_q;
    logic [IDX_W-1:0] fwd_held_idx_q;
    logic install_active_q;
    logic [IDX_W-1:0] install_held_idx_q;

    /** @brief Senales combinacionales de busqueda probe, forwarding, drenado y done. */
    logic probe_hit;
    logic probe_busy_stored;
    logic [IDX_W-1:0] probe_idx;
    logic [IDX_W-1:0] fwd_idx;
    logic install_found;
    logic [IDX_W-1:0] install_idx;
    logic done_found;
    logic [IDX_W-1:0] done_idx;

    always_comb begin
        probe_hit = 1'b0;
        probe_busy_stored = 1'b0;
        probe_idx = '0;
        if (wb_probe_valid_i) begin
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                if (!probe_hit && entry_valid_q[idx] &&
                    (entry_base_q[idx] == wb_probe_base_i)) begin
                    probe_hit = 1'b1;
                    probe_busy_stored = entry_inflight_q[idx];
                    for (integer bit_i = 0; bit_i < IDX_W; bit_i++) begin
                        probe_idx[bit_i] = idx[bit_i];
                    end
                end
            end
        end
    end

    /** @brief Control combinacional de canales, prioridad fwd/install y metricas. */
    always_comb begin
        push_ready_internal = (count_q < COUNT_W'(WRITE_BUFFER_DEPTH));
        fwd_valid_internal = 1'b0;
        install_valid_internal = 1'b0;
        done_ready_internal = 1'b0;

        wb_fwd_base_o = 32'b0;
        wb_fwd_data_o = '0;
        wb_fwd_dirty_o = 1'b0;
        fwd_idx = '0;

        if (fwd_active_q) begin
            fwd_valid_internal = 1'b1;
            fwd_idx = fwd_held_idx_q;
            wb_fwd_base_o = entry_base_q[fwd_held_idx_q];
            wb_fwd_data_o = entry_data_q[fwd_held_idx_q];
            wb_fwd_dirty_o = entry_dirty_q[fwd_held_idx_q];
        end else if (probe_hit && !probe_busy_stored) begin
            fwd_valid_internal = 1'b1;
            fwd_idx = probe_idx;
            wb_fwd_base_o = entry_base_q[probe_idx];
            wb_fwd_data_o = entry_data_q[probe_idx];
            wb_fwd_dirty_o = entry_dirty_q[probe_idx];
        end

        // Seleccion FIFO de drenado; forwarding tiene prioridad sobre entrada libre
        install_found = 1'b0;
        install_idx = '0;
        wb_install_base_o = 32'b0;
        wb_install_data_o = '0;
        wb_install_dirty_o = 1'b0;

        if (install_active_q) begin
            install_found = 1'b1;
            install_idx = install_held_idx_q;
            install_valid_internal = 1'b1;
            wb_install_base_o = entry_base_q[install_held_idx_q];
            wb_install_data_o = entry_data_q[install_held_idx_q];
            wb_install_dirty_o = entry_dirty_q[install_held_idx_q];
        end else begin
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                logic [IDX_W-1:0] idx_trunc;
                for (integer bit_i = 0; bit_i < IDX_W; bit_i++) begin
                    idx_trunc[bit_i] = idx[bit_i];
                end
                if (!install_found && entry_valid_q[idx] && !entry_inflight_q[idx] &&
                    !(fwd_valid_internal && (idx_trunc == fwd_idx))) begin
                    install_found = 1'b1;
                    install_idx = idx_trunc;
                    install_valid_internal = 1'b1;
                    wb_install_base_o = entry_base_q[idx_trunc];
                    wb_install_data_o = entry_data_q[idx_trunc];
                    wb_install_dirty_o = entry_dirty_q[idx_trunc];
                end
            end
        end

        // Consulta probe: entrada en servicio desde el ciclo en que se presenta install
        wb_probe_hit_o = rst_ni && probe_hit;
        wb_probe_busy_o = rst_ni && probe_hit &&
            (probe_busy_stored || (install_valid_internal && (probe_idx == install_idx)));

        // Busqueda de confirmacion wb_done por identificador L2
        done_found = 1'b0;
        done_idx = '0;
        for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
            if (!done_found && entry_valid_q[idx] && entry_inflight_q[idx] &&
                entry_id_valid_q[idx] && (entry_l2_id_q[idx] == wb_done_id_i)) begin
                done_found = 1'b1;
                for (integer bit_i = 0; bit_i < IDX_W; bit_i++) begin
                    done_idx[bit_i] = idx[bit_i];
                end
            end
        end
        done_ready_internal = done_found;

        // Eventos y estados observables
        perf_events_o = '0;
        perf_events_o.state.occupancy = {{(32 - COUNT_W){1'b0}}, count_q};
        perf_events_o.state.capacity = WRITE_BUFFER_DEPTH;
        perf_events_o.state.push_wait = wb_push_valid_i && !wb_push_ready_o;
        perf_events_o.state.send_wait = wb_install_valid_o && !wb_install_ready_i;
        perf_events_o.state.raw_wait = wb_probe_valid_i && wb_probe_hit_o && wb_probe_busy_o;

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
        if (wb_install_handshake) begin
            perf_events_o.install_accept.valid = 1'b1;
            perf_events_o.install_accept.id = {{(32 - L2_ID_W){1'b0}}, wb_install_accept_id_i};
        end
        if (wb_done_handshake) begin
            perf_events_o.install_done.valid = 1'b1;
            perf_events_o.install_done.id = {{(32 - L2_ID_W){1'b0}}, wb_done_id_i};
        end
    end

    /** @brief Actualizacion sincrona unificada: estado servicio, retiros, compactacion e insercion. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            count_q <= '0;
            fwd_active_q <= 1'b0;
            fwd_held_idx_q <= '0;
            install_active_q <= 1'b0;
            install_held_idx_q <= '0;
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
            logic [WRITE_BUFFER_DEPTH-1:0] next_valid;
            pkg_memory::address_t next_base [0:WRITE_BUFFER_DEPTH-1];
            pkg_memory::line_t next_data [0:WRITE_BUFFER_DEPTH-1];
            logic [WRITE_BUFFER_DEPTH-1:0] next_dirty;
            logic [WRITE_BUFFER_DEPTH-1:0] next_inflight;
            logic [WRITE_BUFFER_DEPTH-1:0] next_id_valid;
            logic [L2_ID_W-1:0] next_l2_id [0:WRITE_BUFFER_DEPTH-1];
            logic [COUNT_W-1:0] next_count;
            logic next_fwd_active;
            logic [IDX_W-1:0] next_fwd_held;
            logic next_install_active;
            logic [IDX_W-1:0] next_install_held;
            logic [IDX_W-1:0] write_ptr;

            next_valid = entry_valid_q;
            next_dirty = entry_dirty_q;
            next_inflight = entry_inflight_q;
            next_id_valid = entry_id_valid_q;
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                next_base[idx] = entry_base_q[idx];
                next_data[idx] = entry_data_q[idx];
                next_l2_id[idx] = entry_l2_id_q[idx];
            end

            next_fwd_active = fwd_active_q;
            next_fwd_held = fwd_held_idx_q;
            next_install_active = install_active_q;
            next_install_held = install_held_idx_q;

            // 1. Retencion de oferta wb_fwd
            if (wb_fwd_handshake) begin
                next_fwd_active = 1'b0;
            end else if (wb_fwd_valid_o && !wb_fwd_ready_i && !fwd_active_q) begin
                next_fwd_active = 1'b1;
                next_fwd_held = probe_idx;
            end

            // 2. Paso a servicio y asociacion de id en wb_install
            if (wb_install_valid_o) begin
                next_inflight[install_idx] = 1'b1;
                if (wb_install_handshake) begin
                    next_id_valid[install_idx] = 1'b1;
                    next_l2_id[install_idx] = wb_install_accept_id_i;
                    next_install_active = 1'b0;
                end else if (!install_active_q) begin
                    next_install_active = 1'b1;
                    next_install_held = install_idx;
                end
            end

            // 3. Marcar entradas retiradas en este ciclo (por fwd y/o done fuera de orden)
            if (wb_fwd_handshake) begin
                next_valid[fwd_idx] = 1'b0;
            end
            if (wb_done_handshake) begin
                next_valid[done_idx] = 1'b0;
            end

            // 4. Compactar entradas sobrevivientes preservando orden FIFO y desplazando indices retenidos
            write_ptr = '0;
            next_count = '0;
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                logic [IDX_W-1:0] idx_trunc;
                for (integer bit_i = 0; bit_i < IDX_W; bit_i++) begin
                    idx_trunc[bit_i] = idx[bit_i];
                end
                if (next_valid[idx]) begin
                    entry_valid_q[write_ptr] <= 1'b1;
                    entry_base_q[write_ptr] <= next_base[idx];
                    entry_data_q[write_ptr] <= next_data[idx];
                    entry_dirty_q[write_ptr] <= next_dirty[idx];
                    entry_inflight_q[write_ptr] <= next_inflight[idx];
                    entry_id_valid_q[write_ptr] <= next_id_valid[idx];
                    entry_l2_id_q[write_ptr] <= next_l2_id[idx];
                    if (next_fwd_active && (next_fwd_held == idx_trunc)) begin
                        next_fwd_held = write_ptr;
                    end
                    if (next_install_active && (next_install_held == idx_trunc)) begin
                        next_install_held = write_ptr;
                    end
                    write_ptr = write_ptr + IDX_W'(1);
                    next_count = next_count + COUNT_W'(1);
                end
            end

            // 5. Insercion al final de la cola si hubo wb_push_handshake
            if (wb_push_handshake) begin
                entry_valid_q[write_ptr] <= 1'b1;
                entry_base_q[write_ptr] <= wb_push_base_i;
                entry_data_q[write_ptr] <= wb_push_data_i;
                entry_dirty_q[write_ptr] <= wb_push_dirty_i;
                entry_inflight_q[write_ptr] <= 1'b0;
                entry_id_valid_q[write_ptr] <= 1'b0;
                entry_l2_id_q[write_ptr] <= '0;
                write_ptr = write_ptr + IDX_W'(1);
                next_count = next_count + COUNT_W'(1);
            end

            // 6. Limpiar huecos restantes por encima de next_count
            for (integer idx = 0; idx < WRITE_BUFFER_DEPTH; idx++) begin
                if (idx >= integer'(next_count)) begin
                    entry_valid_q[idx] <= 1'b0;
                    entry_base_q[idx] <= 32'b0;
                    entry_data_q[idx] <= '0;
                    entry_dirty_q[idx] <= 1'b0;
                    entry_inflight_q[idx] <= 1'b0;
                    entry_id_valid_q[idx] <= 1'b0;
                    entry_l2_id_q[idx] <= '0;
                end
            end

            count_q <= next_count;
            fwd_active_q <= next_fwd_active;
            fwd_held_idx_q <= next_fwd_held;
            install_active_q <= next_install_active;
            install_held_idx_q <= next_install_held;
        end
    end
endmodule