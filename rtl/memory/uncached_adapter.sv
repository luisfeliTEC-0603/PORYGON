/**
 * @brief Referencia CPU-palabra a bursts de linea, sin reutilizacion de datos.
 * @details Una demanda pendiente. Todo acceso valido lee una linea; un store
 * fusiona su mascara y escribe la linea completa antes de responder. La unica
 * linea temporal pertenece a ese store, no a una cache. Los relojes y el
 * timeout siguen siendo responsabilidad del controlador compartido.
 * @see docs/ii-proyecto/cpu-memory-contract.md seccion 6.
 */
module uncached_adapter #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT,
    parameter integer EVICTION_BUFFER_DEPTH = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,
    input logic dmem_req_valid_i,
    output logic dmem_req_ready_o,
    input pkg_memory::address_t dmem_req_addr_i,
    input logic dmem_req_write_i,
    input pkg_memory::word_t dmem_req_wdata_i,
    input pkg_memory::byte_mask_t dmem_req_wstrb_i,
    output logic dmem_rsp_valid_o,
    input logic dmem_rsp_ready_i,
    output pkg_memory::word_t dmem_rsp_rdata_o,
    output logic dmem_rsp_error_o,
    output pkg_metrics::demand_origin_t dmem_rsp_origin_o,

    /** @brief Lectura completa, id cero reservado hasta su consumo. */
    output logic mem_rd_req_valid_o,
    input logic mem_rd_req_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_req_id_o,
    output pkg_memory::address_t mem_rd_req_base_o,
    input logic mem_rd_rsp_valid_i,
    output logic mem_rd_rsp_ready_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_rsp_id_i,
    input pkg_memory::address_t mem_rd_rsp_base_i,
    input pkg_memory::line_t mem_rd_rsp_data_i,
    input logic mem_rd_rsp_error_i,

    /** @brief Escritura de linea fusionada; su confirmacion completa el store. */
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
    output pkg_metrics::error_event_t perf_error_o
);
    localparam integer WORD_BYTES = $bits(pkg_memory::word_t) / 8;
    localparam integer WORD_OFFSET_W = $clog2(WORD_BYTES);
    localparam integer LINE_OFFSET_W = $clog2(pkg_memory::LINE_BYTES);
    typedef enum logic [2:0] {
        IDLE, READ_OFFER, READ_WAIT, WRITE_OFFER, WRITE_WAIT, RESPONSE
    } state_t;
    state_t state_q;
    pkg_memory::address_t address_q, request_base, pending_base;
    pkg_memory::word_t write_data_q, response_data_q;
    pkg_memory::byte_mask_t mask_q;
    pkg_memory::line_t write_line_q, merged_line;
    logic write_q, response_error_q, protocol_reported_q;
    logic address_valid, read_match, write_match, protocol_error;
    logic request_fire, read_fire, write_fire;
    logic [LINE_OFFSET_W-WORD_OFFSET_W-1:0] word_index;

    assign request_base = {dmem_req_addr_i[31:LINE_OFFSET_W], {LINE_OFFSET_W{1'b0}}};
    assign pending_base = {address_q[31:LINE_OFFSET_W], {LINE_OFFSET_W{1'b0}}};
    assign word_index = address_q[WORD_OFFSET_W +: LINE_OFFSET_W-WORD_OFFSET_W];
    assign address_valid = dmem_req_addr_i >= pkg_memory::DATA_BASE_ADDRESS &&
        dmem_req_addr_i <= pkg_memory::DATA_BASE_ADDRESS + pkg_memory::MEMORY_BYTES - WORD_BYTES &&
        dmem_req_addr_i[WORD_OFFSET_W-1:0] == '0;
    assign read_match = mem_rd_rsp_id_i == '0 && mem_rd_rsp_base_i == pending_base;
    assign write_match = mem_wr_rsp_id_i == '0 && mem_wr_rsp_base_i == pending_base;
    assign request_fire = dmem_req_valid_i && dmem_req_ready_o;
    assign read_fire = mem_rd_rsp_valid_i && mem_rd_rsp_ready_o;
    assign write_fire = mem_wr_rsp_valid_i && mem_wr_rsp_ready_o;

    /** @brief Las ofertas dependen de la demanda conservada, nunca de ready. */
    assign dmem_req_ready_o = rst_ni && state_q == IDLE;
    assign mem_rd_req_valid_o = rst_ni && ((state_q == READ_OFFER) ||
        (state_q == IDLE && dmem_req_valid_i && address_valid));
    assign mem_rd_req_id_o = '0;
    assign mem_rd_req_base_o = state_q == IDLE ? request_base : pending_base;
    assign mem_rd_rsp_ready_o = rst_ni && state_q == READ_WAIT && read_match;
    assign mem_wr_req_valid_o = rst_ni && state_q == WRITE_OFFER;
    assign mem_wr_req_id_o = '0;
    assign mem_wr_req_base_o = pending_base;
    assign mem_wr_req_data_o = write_line_q;
    assign mem_wr_rsp_ready_o = rst_ni && state_q == WRITE_WAIT && write_match;

    always_comb begin
        merged_line = mem_rd_rsp_data_i;
        for (integer byte_index = 0; byte_index < WORD_BYTES; byte_index++)
            if (mask_q[byte_index])
                merged_line[8*(WORD_BYTES*word_index+byte_index) +: 8] =
                    write_data_q[8*byte_index +: 8];
    end

    /**
     * @brief El retorno puede completar la demanda en su propio flanco.
     * @details Si CPU bloquea, RESPONSE conserva la palabra/error mientras
     * el controlador ya queda libre. Un store exitoso espera su confirmacion.
     */
    always_comb begin
        dmem_rsp_valid_o = 1'b0;
        dmem_rsp_rdata_o = '0;
        dmem_rsp_error_o = 1'b0;
        if (rst_ni) begin
            case (state_q)
                IDLE: if (dmem_req_valid_i && !address_valid) begin
                    dmem_rsp_valid_o = 1'b1;
                    dmem_rsp_error_o = 1'b1;
                end
                READ_WAIT: if (mem_rd_rsp_valid_i && read_match &&
                               (!write_q || mem_rd_rsp_error_i)) begin
                    dmem_rsp_valid_o = 1'b1;
                    dmem_rsp_error_o = mem_rd_rsp_error_i;
                    if (!mem_rd_rsp_error_i)
                        dmem_rsp_rdata_o = mem_rd_rsp_data_i[$bits(pkg_memory::word_t)*word_index +: $bits(pkg_memory::word_t)];
                end
                WRITE_WAIT: if (mem_wr_rsp_valid_i && write_match) begin
                    dmem_rsp_valid_o = 1'b1;
                    dmem_rsp_error_o = mem_wr_rsp_error_i;
                end
                RESPONSE: begin
                    dmem_rsp_valid_o = 1'b1;
                    dmem_rsp_rdata_o = response_data_q;
                    dmem_rsp_error_o = response_error_q;
                end
                default: begin end
            endcase
        end
    end
    always_comb begin
        if (dmem_rsp_error_o) dmem_rsp_origin_o = pkg_metrics::ORIGIN_ERROR;
        else dmem_rsp_origin_o = pkg_metrics::ORIGIN_REFERENCE;
    end

    /**
     * @brief Captura unica, lectura, fusion/escritura y respuesta retenida.
     * @details Reset cancela el protocolo; los bytes ya escritos en RAM no se
     * revierten. La linea temporal no se consulta desde IDLE para otro acceso.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            address_q <= '0;
            write_q <= 1'b0;
            write_data_q <= '0;
            mask_q <= '0;
            write_line_q <= '0;
            response_data_q <= '0;
            response_error_q <= 1'b0;
            protocol_reported_q <= 1'b0;
        end else begin
            protocol_reported_q <= protocol_error;
            case (state_q)
                IDLE: if (request_fire) begin
                    address_q <= dmem_req_addr_i;
                    write_q <= dmem_req_write_i;
                    write_data_q <= dmem_req_wdata_i;
                    mask_q <= dmem_req_wstrb_i;
                    if (!address_valid) begin
                        if (!dmem_rsp_ready_i) begin
                            response_data_q <= '0;
                            response_error_q <= 1'b1;
                            state_q <= RESPONSE;
                        end
                    end else if (mem_rd_req_ready_i) state_q <= READ_WAIT;
                    else state_q <= READ_OFFER;
                end
                READ_OFFER: if (mem_rd_req_ready_i) state_q <= READ_WAIT;
                READ_WAIT: if (read_fire) begin
                    if (write_q && !mem_rd_rsp_error_i) begin
                        write_line_q <= merged_line;
                        state_q <= WRITE_OFFER;
                    end else if (dmem_rsp_ready_i) state_q <= IDLE;
                    else begin
                        response_data_q <= dmem_rsp_rdata_o;
                        response_error_q <= mem_rd_rsp_error_i;
                        state_q <= RESPONSE;
                    end
                end
                WRITE_OFFER: if (mem_wr_req_ready_i) state_q <= WRITE_WAIT;
                WRITE_WAIT: if (write_fire) begin
                    if (dmem_rsp_ready_i) state_q <= IDLE;
                    else begin
                        response_data_q <= '0;
                        response_error_q <= mem_wr_rsp_error_i;
                        state_q <= RESPONSE;
                    end
                end
                RESPONSE: if (dmem_rsp_ready_i) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end

    /** @brief Errores propios; los errores del controlador no se duplican. */
    assign protocol_error = (state_q == READ_WAIT && mem_rd_rsp_valid_i && !read_match) ||
                            (state_q == WRITE_WAIT && mem_wr_rsp_valid_i && !write_match);
    always_comb begin
        perf_error_o = '0;
        if (rst_ni && request_fire && !address_valid) begin
            perf_error_o.valid = 1'b1;
            if (dmem_req_addr_i[WORD_OFFSET_W-1:0] != '0)
                perf_error_o.kind = pkg_metrics::ERROR_ALIGNMENT;
            else perf_error_o.kind = pkg_metrics::ERROR_ADDRESS;
            perf_error_o.address = dmem_req_addr_i;
        end else if (rst_ni && protocol_error && !protocol_reported_q) begin
            perf_error_o.valid = 1'b1;
            perf_error_o.kind = pkg_metrics::ERROR_PROTOCOL;
            perf_error_o.address = state_q == READ_WAIT ? mem_rd_rsp_base_i : mem_wr_rsp_base_i;
        end
    end
endmodule
