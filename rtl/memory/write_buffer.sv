/**
 * @brief Skeleton de FIFO L1 -> L2 con forwarding por direccion base.
 * @param WRITE_BUFFER_DEPTH Capacidad en lineas; cuatro por defecto.
 * @param L2_MAX_INFLIGHT Limite 1..4; determina el ancho de ids de instalacion.
 * @details Una entrada entra en servicio al presentar wb_install_valid, aun
 * antes de ready. Forwarding gana si ambos intentan iniciar sobre una entrada
 * libre; una entrada en servicio espera wb_done. Los campos ofrecidos quedan
 * estables durante esperas. Reset cancela entradas y asociaciones pendientes.
 * @see docs/ii-proyecto/interfaces.md secciones 2 y 4.
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
    // TODO P2-05: entradas, orden, consultas, forwarding e ids en servicio.
endmodule
