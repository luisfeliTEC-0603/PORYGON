/**
 * @brief Conserva y drena victimas sucias de L2 hacia memoria.
 * @param EVICTION_BUFFER_DEPTH Capacidad en lineas; ocho por defecto.
 * @details La entrada se libera al consumir confirmacion correcta de las ocho
 * palabras. Un error la conserva. La consulta incluye entradas en servicio y
 * una entrada aceptada en el mismo flanco. La oferta permanece estable
 * mientras el controlador no la acepta. Reset cancela entradas e IDs.
 * @see docs/ii-proyecto/interfaces.md secciones 5 y 7.
 */
module eviction_buffer #(
    parameter integer EVICTION_BUFFER_DEPTH = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /** @brief Recibe victima completa con dirty=1; su handshake libera L2. */
    input logic eb_push_valid_i,
    output logic eb_push_ready_o,
    input pkg_memory::address_t eb_push_base_i,
    input pkg_memory::line_t eb_push_data_i,
    input logic eb_push_dirty_i,

    /** @brief Consulta combinacional RAW sin forwarding ni vaciado global. */
    input logic eb_probe_valid_i,
    input pkg_memory::address_t eb_probe_base_i,
    output logic eb_probe_hit_o,

    /**
     * @brief Drenado FIFO de lineas completas al controlador.
     * @details id identifica la entrada hasta consumir la respuesta; su
     * espacio es independiente del de ids de lectura procedentes de L2.
     */
    output logic mem_wr_req_valid_o,
    input logic mem_wr_req_ready_i,
    output logic [pkg_memory::id_width(EVICTION_BUFFER_DEPTH)-1:0] mem_wr_req_id_o,
    output pkg_memory::address_t mem_wr_req_base_o,
    output pkg_memory::line_t mem_wr_req_data_o,
    input logic mem_wr_rsp_valid_i,
    output logic mem_wr_rsp_ready_o,
    input logic [pkg_memory::id_width(EVICTION_BUFFER_DEPTH)-1:0] mem_wr_rsp_id_i,
    input pkg_memory::address_t mem_wr_rsp_base_i,
    input logic mem_wr_rsp_error_i,

    /** @brief Encolado, envio, confirmacion, ocupacion y conflicto RAW. */
    output pkg_metrics::eb_events_t perf_events_o
);
    /**
     * @brief Reserva un espacio fijo para cada victima aceptada.
     * @details El indice libre sera el id de escritura. Solo occupied_q define
     * si los datos de una entrada son vigentes; reset cancela todas las entradas.
     */
    localparam integer SLOT_W = pkg_memory::id_width(EVICTION_BUFFER_DEPTH);
    localparam integer COUNT_W = $clog2(EVICTION_BUFFER_DEPTH + 1);
    logic [EVICTION_BUFFER_DEPTH-1:0] occupied_q;
    logic [EVICTION_BUFFER_DEPTH-1:0] sent_q;
    logic [EVICTION_BUFFER_DEPTH-1:0] failed_q;
    pkg_memory::address_t base_q [EVICTION_BUFFER_DEPTH];
    pkg_memory::line_t data_q [EVICTION_BUFFER_DEPTH];
    logic dirty_q [EVICTION_BUFFER_DEPTH];
    logic [SLOT_W-1:0] order_q [EVICTION_BUFFER_DEPTH];
    logic [SLOT_W-1:0] order_d [EVICTION_BUFFER_DEPTH];
    logic [COUNT_W-1:0] count_q, count_d;
    logic [SLOT_W-1:0] free_slot, offer_id;
    logic free_found, offer_found, remove_found;
    logic push_fire, request_fire, response_fire;
    logic response_match, success_fire, error_fire, protocol_error_fire;
    integer remove_pos;

    /** @brief La respuesta correcta puede liberar un espacio en este flanco. */
    assign mem_wr_rsp_ready_o = rst_ni;
    assign response_fire = mem_wr_rsp_valid_i && mem_wr_rsp_ready_o;

    always_comb begin
        remove_found = 1'b0;
        remove_pos = 0;
        for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++) begin
            if (i < count_q && order_q[i] == mem_wr_rsp_id_i) begin
                remove_found = 1'b1;
                remove_pos = i;
            end
        end
        response_match = 1'b0;
        if (mem_wr_rsp_id_i < EVICTION_BUFFER_DEPTH) begin
            response_match = occupied_q[mem_wr_rsp_id_i] &&
                sent_q[mem_wr_rsp_id_i] && remove_found &&
                base_q[mem_wr_rsp_id_i] == mem_wr_rsp_base_i;
        end
    end

    assign success_fire = response_fire && response_match && !mem_wr_rsp_error_i;
    assign error_fire = response_fire && response_match && mem_wr_rsp_error_i;
    assign protocol_error_fire = response_fire && !response_match;

    /** @brief Asigna el indice fisico libre como id de la nueva entrada. */
    always_comb begin
        free_found = 1'b0;
        free_slot = '0;
        for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++) begin
            if ((!occupied_q[i] ||
                 (success_fire && mem_wr_rsp_id_i == SLOT_W'(i))) &&
                !free_found) begin
                free_found = 1'b1;
                free_slot = SLOT_W'(i);
            end
        end
    end

    assign eb_push_ready_o = rst_ni && free_found;
    assign push_fire = eb_push_valid_i && eb_push_ready_o;

    /** @brief Ofrece la entrada pendiente mas antigua sin mover sus datos. */
    always_comb begin
        offer_found = 1'b0;
        offer_id = '0;
        for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++) begin
            if (i < count_q && !offer_found &&
                occupied_q[order_q[i]] && !sent_q[order_q[i]] &&
                !failed_q[order_q[i]]) begin
                offer_found = 1'b1;
                offer_id = order_q[i];
            end
        end
    end

    assign mem_wr_req_valid_o = rst_ni && offer_found;
    assign mem_wr_req_id_o = offer_id;
    assign mem_wr_req_base_o = offer_found ? base_q[offer_id] : '0;
    assign mem_wr_req_data_o = offer_found ? data_q[offer_id] : '0;
    assign request_fire = mem_wr_req_valid_o && mem_wr_req_ready_i;

    /** @brief Retira solo el id confirmado y anade la nueva victima al final. */
    always_comb begin
        count_d = count_q;
        for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++)
            order_d[i] = order_q[i];
        if (success_fire) begin
            for (integer i = 0; i < EVICTION_BUFFER_DEPTH - 1; i++) begin
                if (i >= remove_pos && i + 1 < count_q)
                    order_d[i] = order_q[i + 1];
            end
            count_d = count_d - 1'b1;
        end
        if (push_fire) begin
            order_d[count_d] = free_slot;
            count_d = count_d + 1'b1;
        end
    end

    /**
     * @brief Conserva cada linea hasta consumir su confirmacion correcta.
     * @details Push tiene prioridad sobre la liberacion si reutiliza en el
     * mismo flanco el espacio que una respuesta correcta acaba de dejar libre.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            occupied_q <= '0;
            sent_q <= '0;
            failed_q <= '0;
            count_q <= '0;
            for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++)
                order_q[i] <= '0;
        end else begin
            count_q <= count_d;
            for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++)
                order_q[i] <= order_d[i];
            if (success_fire) begin
                occupied_q[mem_wr_rsp_id_i] <= 1'b0;
                sent_q[mem_wr_rsp_id_i] <= 1'b0;
                failed_q[mem_wr_rsp_id_i] <= 1'b0;
            end
            if (request_fire)
                sent_q[offer_id] <= 1'b1;
            if (error_fire)
                failed_q[mem_wr_rsp_id_i] <= 1'b1;
            if (push_fire) begin
                occupied_q[free_slot] <= 1'b1;
                sent_q[free_slot] <= 1'b0;
                failed_q[free_slot] <= 1'b0;
                base_q[free_slot] <= eb_push_base_i;
                data_q[free_slot] <= eb_push_data_i;
                dirty_q[free_slot] <= eb_push_dirty_i;
            end
        end
    end

    /**
     * @brief Busca conflictos de direccion sin retirar ni reenviar la linea.
     * @details Incluye la victima que L2 entrega en este mismo flanco para
     * impedir que el controlador acepte a la vez una lectura de esa base.
     */
    always_comb begin
        eb_probe_hit_o = 1'b0;
        if (rst_ni && eb_probe_valid_i) begin
            for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++) begin
                if (occupied_q[i] && base_q[i] == eb_probe_base_i)
                    eb_probe_hit_o = 1'b1;
            end
            if (push_fire && eb_push_base_i == eb_probe_base_i)
                eb_probe_hit_o = 1'b1;
        end
    end
    /** @brief Eventos por handshake y muestras del estado previo al flanco. */
    always_comb begin
        perf_events_o = '0;
        perf_events_o.enqueued.valid = push_fire;
        perf_events_o.enqueued.base = eb_push_base_i;
        perf_events_o.enqueued.dirty = eb_push_dirty_i;
        perf_events_o.write_accept.valid = request_fire;
        perf_events_o.write_accept.write = 1'b1;
        perf_events_o.write_accept.id = offer_id;
        perf_events_o.write_accept.base = mem_wr_req_base_o;
        perf_events_o.write_done.valid = success_fire;
        perf_events_o.write_done.write = 1'b1;
        perf_events_o.write_done.id = mem_wr_rsp_id_i;
        perf_events_o.write_done.base = mem_wr_rsp_base_i;
        perf_events_o.write_error = error_fire;
        perf_events_o.state.occupancy = count_q;
        perf_events_o.state.capacity = EVICTION_BUFFER_DEPTH;
        perf_events_o.state.push_wait = rst_ni && eb_push_valid_i && !eb_push_ready_o;
        perf_events_o.state.send_wait = mem_wr_req_valid_o && !mem_wr_req_ready_i;
        perf_events_o.state.raw_wait = eb_probe_valid_i && eb_probe_hit_o;
        perf_events_o.error.valid = protocol_error_fire;
        perf_events_o.error.kind = pkg_metrics::ERROR_PROTOCOL;
        perf_events_o.error.address = mem_wr_rsp_base_i;
    end
endmodule
