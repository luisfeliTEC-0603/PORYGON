/**
 * @brief Skeleton FIFO de victimas sucias L2 -> memoria.
 * @param EVICTION_BUFFER_DEPTH Capacidad en lineas; ocho por defecto.
 * @details La entrada se libera al consumir confirmacion correcta de las ocho
 * palabras. Un error la conserva. La consulta incluye entradas en servicio y
 * una entrada aceptada en el mismo flanco. Oferta y respuesta permanecen
 * estables durante esperas. Reset cancela entradas e identificadores.
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
    logic [EVICTION_BUFFER_DEPTH-1:0] occupied_q;
    pkg_memory::address_t base_q [EVICTION_BUFFER_DEPTH];
    pkg_memory::line_t data_q [EVICTION_BUFFER_DEPTH];
    logic dirty_q [EVICTION_BUFFER_DEPTH];
    logic [SLOT_W-1:0] free_slot;
    logic free_found;
    logic push_fire;

    always_comb begin
        free_found = 1'b0;
        free_slot = '0;
        for (integer i = 0; i < EVICTION_BUFFER_DEPTH; i++) begin
            if (!occupied_q[i] && !free_found) begin
                free_found = 1'b1;
                free_slot = SLOT_W'(i);
            end
        end
    end

    assign eb_push_ready_o = rst_ni && free_found;
    assign push_fire = eb_push_valid_i && eb_push_ready_o;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            occupied_q <= '0;
        end else if (push_fire) begin
            occupied_q[free_slot] <= 1'b1;
            base_q[free_slot] <= eb_push_base_i;
            data_q[free_slot] <= eb_push_data_i;
            dirty_q[free_slot] <= eb_push_dirty_i;
        end
    end

    assign eb_probe_hit_o = 1'b0;
    assign mem_wr_req_valid_o = 1'b0;
    assign mem_wr_req_id_o = '0;
    assign mem_wr_req_base_o = '0;
    assign mem_wr_req_data_o = '0;
    assign mem_wr_rsp_ready_o = 1'b0;

    assign perf_events_o = '0;
endmodule
