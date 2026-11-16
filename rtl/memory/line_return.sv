/**
 * @brief Seleccion sin latencia adicional del retorno WB/L2/memoria a L1.
 * @param L2_MAX_INFLIGHT Limite 1..4; determina el ancho de ids de retorno.
 * @details Solo hay un origen autorizado por demanda. Se propaga ready solo
 * al seleccionado y el handshake es simultaneo al de fill en L1. La seleccion
 * y campos permanecen estables con fill_valid && !fill_ready. No se impone
 * un ciclo registrado adicional. Reset elimina ofertas y seleccion pendiente.
 * @see docs/ii-proyecto/interfaces.md seccion 8.
 */
module line_return #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /** @brief WB aporta dirty; fill_id=0 y fill_error=0 para forwarding. */
    input logic wb_fwd_valid_i,
    output logic wb_fwd_ready_o,
    input pkg_memory::address_t wb_fwd_base_i,
    input pkg_memory::line_t wb_fwd_data_i,
    input logic wb_fwd_dirty_i,

    /** @brief Hit de L2; conserva id, base, datos, dirty y error. */
    input logic l2_fill_valid_i,
    output logic l2_fill_ready_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_fill_id_i,
    input pkg_memory::address_t l2_fill_base_i,
    input pkg_memory::line_t l2_fill_data_i,
    input logic l2_fill_dirty_i,
    input logic l2_fill_error_i,

    /** @brief Lectura completa del controlador; fill_dirty=0. */
    input logic mem_rd_rsp_valid_i,
    output logic mem_rd_rsp_ready_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_rsp_id_i,
    input pkg_memory::address_t mem_rd_rsp_base_i,
    input pkg_memory::line_t mem_rd_rsp_data_i,
    input logic mem_rd_rsp_error_i,

    /** @brief Oferta unica a la via o entrada reservada de L1. */
    output logic fill_valid_o,
    input logic fill_ready_i,
    output pkg_memory::address_t fill_base_o,
    output pkg_memory::line_t fill_data_o,
    output logic fill_dirty_o,
    output logic fill_error_o,
    output pkg_memory::fill_source_t fill_source_o,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] fill_id_o,

    /** @brief Pulso de error local de seleccion, por ejemplo ofertas ilegales. */
    output pkg_metrics::error_event_t perf_error_o
);
    localparam integer ID_W = pkg_memory::id_width(L2_MAX_INFLIGHT);
    typedef struct packed {
        pkg_memory::address_t base;
        pkg_memory::line_t data;
        logic dirty;
        logic error;
        pkg_memory::fill_source_t source;
        logic [ID_W-1:0] id;
    } return_t;

    return_t offered, held_q, selected;
    logic held_valid_q, conflict_reported_q;
    logic [2:0] offers;
    logic single_offer, conflict;

    assign offers = {mem_rd_rsp_valid_i, l2_fill_valid_i, wb_fwd_valid_i};
    assign single_offer = (offers == 3'b001) || (offers == 3'b010) ||
                          (offers == 3'b100);
    assign conflict = (|offers) && !single_offer;

    /**
     * @brief Los productores autorizan un unico origen por demanda.
     * @details Ofertas simultaneas son un error, no una prioridad de arbitraje.
     * Una oferta ya retenida conserva su identidad hasta el consumo de L1.
     */
    always_comb begin
        offered = '0;
        offered.source = pkg_memory::FILL_RESERVED;
        case (offers)
            3'b001: begin
                offered.base = wb_fwd_base_i;
                offered.data = wb_fwd_data_i;
                offered.dirty = wb_fwd_dirty_i;
                offered.source = pkg_memory::FILL_WB;
            end
            3'b010: begin
                offered.base = l2_fill_base_i;
                offered.data = l2_fill_data_i;
                offered.dirty = l2_fill_dirty_i;
                offered.error = l2_fill_error_i;
                offered.source = pkg_memory::FILL_L2;
                offered.id = l2_fill_id_i;
            end
            3'b100: begin
                offered.base = mem_rd_rsp_base_i;
                offered.data = mem_rd_rsp_data_i;
                offered.error = mem_rd_rsp_error_i;
                offered.source = pkg_memory::FILL_MEMORY;
                offered.id = mem_rd_rsp_id_i;
            end
            default: begin end
        endcase
    end

    assign selected = held_valid_q ? held_q : offered;
    assign fill_valid_o = rst_ni && (held_valid_q || single_offer);
    assign fill_base_o = selected.base;
    assign fill_data_o = selected.data;
    assign fill_dirty_o = selected.dirty;
    assign fill_error_o = selected.error;
    assign fill_source_o = selected.source;
    assign fill_id_o = selected.id;

    /** @brief Ready no participa en elegir datos: el handshake es el de L1. */
    assign wb_fwd_ready_o = fill_valid_o && fill_ready_i &&
                           (selected.source == pkg_memory::FILL_WB);
    assign l2_fill_ready_o = fill_valid_o && fill_ready_i &&
                            (selected.source == pkg_memory::FILL_L2);
    assign mem_rd_rsp_ready_o = fill_valid_o && fill_ready_i &&
                               (selected.source == pkg_memory::FILL_MEMORY);

    /**
     * @brief Captura solamente ante bloqueo; el camino libre es combinacional.
     * @details No consume el origen antes de L1 ni crea otra confirmacion.
     * Reset cancela tambien la oferta retenida y el diagnostico pendiente.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            held_valid_q <= 1'b0;
            held_q <= '0;
            conflict_reported_q <= 1'b0;
        end else begin
            if (fill_valid_o && fill_ready_i) begin
                held_valid_q <= 1'b0;
            end else if (fill_valid_o && !held_valid_q) begin
                held_valid_q <= 1'b1;
                held_q <= offered;
            end
            conflict_reported_q <= conflict;
        end
    end

    always_comb begin
        perf_error_o = '0;
        if (rst_ni && conflict && !conflict_reported_q) begin
            perf_error_o.valid = 1'b1;
            perf_error_o.kind = pkg_metrics::ERROR_PROTOCOL;
            perf_error_o.address = fill_base_o;
        end
    end
endmodule
