/**
 * @brief Skeleton del controlador de bursts y cruce CPU <-> memoria.
 * @param L2_MAX_INFLIGHT Determina el ancho de ids de lectura, rango 1..4.
 * @param EVICTION_BUFFER_DEPTH Determina el ancho de ids de escritura.
 * @param MEM_CLOCK_DIV Ciclos CPU por ciclo de memoria; dos por defecto.
 * @param MEM_READ_FIRST_WORD_CYCLES Ciclos CPU hasta primera palabra leida.
 * @param MEM_WRITE_FIRST_WORD_CYCLES Ciclos CPU hasta primera palabra escrita.
 * @param MEM_TIMEOUT_CYCLES Limite desde aceptacion hasta resultado disponible.
 * @details Los tiempos incluyen CDC; con 25, 25 y divisor 2, cada burst tarda
 * 39 ciclos CPU. Ready de solicitud significa inicio del servicio, despues
 * del arbitraje. Gana la solicitud mas antigua que puede avanzar, con prioridad
 * de drenado en empate. Un burst iniciado termina antes del siguiente.
 * Reset cancela ambas caras del CDC y descarta respuestas anteriores.
 * @see docs/ii-proyecto/interfaces.md secciones 6 y 7.
 */
module memory_controller #(
    parameter integer L2_MAX_INFLIGHT = pkg_memory::L2_MAX_INFLIGHT_DEFAULT,
    parameter integer EVICTION_BUFFER_DEPTH = pkg_memory::EVICTION_BUFFER_DEPTH_DEFAULT,
    parameter integer MEM_CLOCK_DIV = pkg_memory::MEM_CLOCK_DIV_DEFAULT,
    parameter integer MEM_READ_FIRST_WORD_CYCLES = pkg_memory::MEM_READ_FIRST_WORD_CYCLES_DEFAULT,
    parameter integer MEM_WRITE_FIRST_WORD_CYCLES = pkg_memory::MEM_WRITE_FIRST_WORD_CYCLES_DEFAULT,
    parameter integer MEM_TIMEOUT_CYCLES = pkg_memory::MEM_TIMEOUT_CYCLES_DEFAULT
) (
    input logic clk_i,
    input logic rst_ni,

    /**
     * @brief Lectura de linea; eb_probe_hit inhibe su aceptacion.
     * @details Rsp devuelve id/base sin cambios y datos completos. valid y
     * campos se conservan hasta ready. Estar disponible termina el timeout.
     */
    input logic mem_rd_req_valid_i,
    output logic mem_rd_req_ready_o,
    input logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_req_id_i,
    input pkg_memory::address_t mem_rd_req_base_i,
    input logic eb_probe_hit_i,
    output logic mem_rd_rsp_valid_o,
    input logic mem_rd_rsp_ready_i,
    output logic [pkg_memory::id_width(L2_MAX_INFLIGHT)-1:0] mem_rd_rsp_id_o,
    output pkg_memory::address_t mem_rd_rsp_base_o,
    output pkg_memory::line_t mem_rd_rsp_data_o,
    output logic mem_rd_rsp_error_o,

    /**
     * @brief Escritura completa; los ids son independientes de los de lectura.
     * @details La respuesta correcta confirma ocho palabras almacenadas;
     * aceptar req no permite liberar EB. Un timeout conserva su entrada.
     */
    input logic mem_wr_req_valid_i,
    output logic mem_wr_req_ready_o,
    input logic [pkg_memory::id_width(EVICTION_BUFFER_DEPTH)-1:0] mem_wr_req_id_i,
    input pkg_memory::address_t mem_wr_req_base_i,
    input pkg_memory::line_t mem_wr_req_data_i,
    output logic mem_wr_rsp_valid_o,
    input logic mem_wr_rsp_ready_i,
    output logic [pkg_memory::id_width(EVICTION_BUFFER_DEPTH)-1:0] mem_wr_rsp_id_o,
    output pkg_memory::address_t mem_wr_rsp_base_o,
    output logic mem_wr_rsp_error_o,

    /**
     * @brief Frontera de almacenamiento por palabra, en reloj de memoria.
     * @output ram_clk_o Reloj derivado; frecuencia 20..50 MHz.
     * @output ram_rst_no Reset activo bajo, liberado en el dominio de memoria.
     * @output ram_address_o Direccion fisica alineada de la palabra del burst.
     * @output ram_read_enable_o Habilita una lectura sincrona.
     * @output ram_write_enable_o Mascara por byte; 1111 para palabras de burst.
     * @input ram_read_* Respuesta sincrona de palabra y su validez.
     * @input ram_out_of_range_i Diagnostico de la solicitud en este dominio.
     * @details El controlador programa el almacenamiento, cuenta palabras y
     * realiza CDC. No presenta lectura y escritura simultaneas al arreglo.
     */
    output logic ram_clk_o,
    output logic ram_rst_no,
    output pkg_memory::address_t ram_address_o,
    output logic ram_read_enable_o,
    output pkg_memory::byte_mask_t ram_write_enable_o,
    output pkg_memory::word_t ram_write_data_o,
    input pkg_memory::word_t ram_read_data_i,
    input logic ram_read_valid_i,
    input logic ram_out_of_range_i,

    /** @brief Eventos de palabras/completitud y estados, todos en reloj CPU. */
    output pkg_metrics::mem_events_t perf_events_o
);

    /**
     * @brief Divide el reloj CPU para generar el reloj continuo de RAM.
     * @details MEM_CLOCK_DIV indica los ciclos CPU por ciclo de RAM.
     * El reset deja ram_clk_o en cero. La primera subida ocurre en el
     * primer flanco CPU tras liberar reset; las siguientes, cada
     * MEM_CLOCK_DIV flancos. El reloj sigue activo sin solicitudes.
     */
    localparam integer DIV_COUNT_W =
        (MEM_CLOCK_DIV > 1) ? $clog2(MEM_CLOCK_DIV) : 1;
    localparam integer RAM_HIGH_CYCLES = (MEM_CLOCK_DIV + 1) / 2;

    logic [DIV_COUNT_W-1:0] divider_count_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            divider_count_q <= MEM_CLOCK_DIV - 1;
            ram_clk_o <= 1'b0;
        end else if (divider_count_q == MEM_CLOCK_DIV - 1) begin
            divider_count_q <= '0;
            ram_clk_o <= 1'b1;
        end else begin
            divider_count_q <= divider_count_q + 1'b1;
            if (divider_count_q == RAM_HIGH_CYCLES - 1)
                ram_clk_o <= 1'b0;
        end
    end
    // TODO P2-03: arbitraje, temporizacion, bursts, CDC y timeout diagnosticado.
endmodule
