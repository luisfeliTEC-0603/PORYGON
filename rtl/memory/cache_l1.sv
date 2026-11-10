/**
 * @brief Skeleton L1-D: 4 KiB, dos vias, LRU, write-back y write-allocate.
 * @param L2_MAX_INFLIGHT Limite 1..4; determina el ancho de ids L2.
 * @input clk_i, rst_ni Reloj CPU y reset activo bajo.
 * @details Una demanda CPU pendiente. Hit en EX de un ciclo; req y rsp pueden
 * transferirse en el mismo flanco. Un miss reserva una entrada de 32 bytes.
 * Las ofertas con valid && !ready conservan todos sus campos. Reset cancela
 * reservas y operaciones; las metricas siguen activas durante stalls de CPU.
 * @see docs/ii-proyecto/cpu-memory-contract.md
 * @see docs/ii-proyecto/interfaces.md secciones 2, 3 y 8.
 */
module cache_l1 #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /**
     * @brief Solicitud y respuesta de palabra CPU; nombres desde L1.
     * @input dmem_req_* Direccion alineada, store desplazado y mascara de bytes.
     * @output dmem_rsp_* Una respuesta por solicitud; dato cero en store/error.
     * @output dmem_rsp_origin_o Sideband de metricas, calificado por rsp_valid.
     */
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

    /** @brief Victima completa: el handshake wb_push libera su via de L1. */
    output logic wb_push_valid_o,
    input logic wb_push_ready_i,
    output pkg_memory::address_t wb_push_base_o,
    output pkg_memory::line_t wb_push_data_o,
    output logic wb_push_dirty_o,

    /** @brief Consulta combinacional RAW; busy obliga a esperar instalacion. */
    output logic wb_probe_valid_o,
    output pkg_memory::address_t wb_probe_base_o,
    input logic wb_probe_hit_i,
    input logic wb_probe_busy_i,

    /** @brief Demanda de linea; accept_id solo es valido al aceptar l2_get. */
    output logic l2_get_valid_o,
    input logic l2_get_ready_i,
    output pkg_memory::address_t l2_get_base_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_get_accept_id_i,

    /**
     * @brief Retorno seleccionado WB/L2/memoria al espacio reservado.
     * @details El handshake transfiere responsabilidad a L1. Se comprueban
     * base e id antes de aceptar; id no se usa para FILL_WB. Un error no instala.
     */
    input logic fill_valid_i,
    output logic fill_ready_o,
    input pkg_memory::address_t fill_base_i,
    input pkg_memory::line_t fill_data_i,
    input logic fill_dirty_i,
    input logic fill_error_i,
    input pkg_memory::fill_source_t fill_source_i,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] fill_id_i,

    /** @brief Eventos CPU-domain de aceptacion, victima y errores propios. */
    output pkg_metrics::l1_events_t perf_events_o
);
    // TODO P2-06: almacenamiento, reemplazo y control de acceso/traslados.
endmodule
