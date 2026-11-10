/**
 * @brief Skeleton de seleccion de retorno WB/L2/memoria a L1.
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
    // TODO P2-11: seleccion, propagacion de ready y diagnostico de protocolo.
endmodule
