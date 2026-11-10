/**
 * @brief Skeleton L2 exclusiva: 16 KiB, cuatro vias, tree-PLRU y write-back.
 * @param L2_MAX_INFLIGHT Operaciones aceptadas hasta finalizacion consumida;
 * cuatro por defecto, rango 1..4. No determina bancos ni busquedas simultaneas.
 * @details Pipeline interno y non-blocking son entregables distintos. Se
 * atiende la solicitud mas antigua que pueda avanzar, preservando reservas.
 * Hit/miss sin contencion conserva ocho ciclos adicionales. valid y campos
 * permanecen estables hasta handshake. Reset cancela operaciones y reservas.
 * @see docs/ii-proyecto/interfaces.md secciones 3 a 6.
 */
module cache_l2 #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /** @brief Aceptar get asigna un id libre del limite compartido con WB. */
    input logic l2_get_valid_i,
    output logic l2_get_ready_o,
    input pkg_memory::address_t l2_get_base_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_get_accept_id_o,

    /** @brief Hit L2: al aceptar L1 se invalida la linea y se libera su id. */
    output logic l2_fill_valid_o,
    input logic l2_fill_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] l2_fill_id_o,
    output pkg_memory::address_t l2_fill_base_o,
    output pkg_memory::line_t l2_fill_data_o,
    output logic l2_fill_dirty_o,
    output logic l2_fill_error_o,

    /** @brief Instalacion conserva dirty; done se ofrece despues de instalar. */
    input logic wb_install_valid_i,
    output logic wb_install_ready_o,
    input pkg_memory::address_t wb_install_base_i,
    input pkg_memory::line_t wb_install_data_i,
    input logic wb_install_dirty_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] wb_install_accept_id_o,
    output logic wb_done_valid_o,
    input logic wb_done_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] wb_done_id_o,

    /** @brief Victima sucia: aceptar eb_push permite reutilizar la via. */
    output logic eb_push_valid_o,
    input logic eb_push_ready_i,
    output pkg_memory::address_t eb_push_base_o,
    output pkg_memory::line_t eb_push_data_o,
    output logic eb_push_dirty_o,

    /**
     * @brief Consulta de conflicto de la lectura ofrecida a memoria.
     * @details probe_valid=mem_rd_req_valid y probe_base=mem_rd_req_base.
     * La coincidencia incluye una entrada que EB acepta en el mismo flanco.
     */
    output logic eb_probe_valid_o,
    output pkg_memory::address_t eb_probe_base_o,
    input logic eb_probe_hit_i,

    /** @brief Miss: solicitar lectura con el mismo id de la demanda L1. */
    output logic mem_rd_req_valid_o,
    input logic mem_rd_req_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_req_id_o,
    output pkg_memory::address_t mem_rd_req_base_o,

    /**
     * @brief Observacion del retorno directo controlador -> L1.
     * @details L2 observa valid && ready para liberar el id en el mismo flanco
     * de entrega a L1. No recibe ni instala una copia de los datos de memoria.
     */
    input logic mem_rd_rsp_valid_i,
    input logic mem_rd_rsp_ready_i,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_rsp_id_i,
    input pkg_memory::address_t mem_rd_rsp_base_i,
    input logic mem_rd_rsp_error_i,

    /** @brief Clasificaciones unicas, movimientos, ocupacion y errores. */
    output pkg_metrics::l2_events_t perf_events_o
);
    // TODO P2-07: almacenamiento, tree-PLRU y movimientos de lineas.
    // TODO P2-08: seguimiento, ids, reservas, arbitraje y pipeline interno.
endmodule
