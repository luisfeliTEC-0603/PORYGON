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

    /**
     * @brief Libera el reset de RAM en su propio dominio de reloj.
     * @details El reset externo baja ram_rst_no inmediatamente. Tras
     * liberarlo, dos flancos positivos de ram_clk_o mantienen el reset
     * activo; la RAM comienza a operar en el flanco siguiente.
     */
    logic [1:0] ram_reset_sync_q;

    always_ff @(posedge ram_clk_o or negedge rst_ni) begin
        if (!rst_ni)
            ram_reset_sync_q <= 2'b00;
        else
            ram_reset_sync_q <= {ram_reset_sync_q[0], 1'b1};
    end

    assign ram_rst_no = rst_ni && ram_reset_sync_q[1];


    /**
     * @brief Conserva la lectura aceptada desde L2.
     * @details El handshake ocurre en un flanco CPU con valid y ready altos.
     * Se guardan id y base para que cambios posteriores en L2 no alteren
     * la solicitud. Por ahora, una oferta de escritura bloquea ready;
     * el arbitraje definitivo por antiguedad se agregara despues.
     * La lectura ocupada se libera al consumir su respuesta.
     */
    localparam integer READ_ID_W = pkg_memory::id_width(L2_MAX_INFLIGHT);

    logic read_busy_q;
    logic [READ_ID_W-1:0] read_id_q;
    pkg_memory::address_t read_base_q;

    assign mem_rd_req_ready_o =
        rst_ni && ram_rst_no &&
        !read_busy_q && !eb_probe_hit_i &&
        !mem_wr_req_valid_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_busy_q <= 1'b0;
            read_id_q <= '0;
            read_base_q <= '0;
        end else if (mem_rd_rsp_valid_o && mem_rd_rsp_ready_i) begin
            read_busy_q <= 1'b0;
        end else if (mem_rd_req_valid_i && mem_rd_req_ready_o) begin
            read_busy_q <= 1'b1;
            read_id_q <= mem_rd_req_id_i;
            read_base_q <= mem_rd_req_base_i;
        end
    end


    /**
     * @brief Prepara el primer acceso RAM según la fase del divisor.
     * @details La edad comienza con la lectura aceptada. Se cambia un bit
     * de aviso un flanco CPU antes del flanco RAM elegido; la base ya está
     * guardada y permanece estable. Requiere una latencia inicial mayor
     * que MEM_CLOCK_DIV para admitir cualquier fase.
     */

    localparam integer READ_TOTAL_CYCLES =
        MEM_READ_FIRST_WORD_CYCLES +
        (pkg_memory::WORDS_PER_LINE - 1) * MEM_CLOCK_DIV;

    localparam integer READ_AGE_W =
        (READ_TOTAL_CYCLES > 1) ? $clog2(READ_TOTAL_CYCLES + 1) : 1;
    localparam integer FIRST_READ_WINDOW =
        MEM_READ_FIRST_WORD_CYCLES - MEM_CLOCK_DIV;

    logic [READ_AGE_W-1:0] read_age_q;
    logic read_start_toggle_q;
    logic read_start_seen_q;
    logic read_accept;
    logic ram_rise_next;
    logic launch_on_accept;
    logic launch_while_waiting;

    assign read_accept = mem_rd_req_valid_i && mem_rd_req_ready_o;
    assign ram_rise_next = divider_count_q == MEM_CLOCK_DIV - 2;

    assign launch_on_accept =
        ram_rise_next &&
        (1 >= FIRST_READ_WINDOW) &&
        (1 < MEM_READ_FIRST_WORD_CYCLES);

    assign launch_while_waiting =
        ram_rise_next &&
        (read_age_q + 1 >= FIRST_READ_WINDOW) &&
        (read_age_q + 1 < MEM_READ_FIRST_WORD_CYCLES);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_age_q <= '0;
            read_start_toggle_q <= 1'b0;
        end else if (read_accept) begin
            read_age_q <= 1;
            if (launch_on_accept)
                read_start_toggle_q <= ~read_start_toggle_q;
        end else if (read_busy_q &&
                     read_age_q < READ_TOTAL_CYCLES) begin
            read_age_q <= read_age_q + 1'b1;
            if (launch_while_waiting)
                read_start_toggle_q <= ~read_start_toggle_q;
        end
    end

    /**
     * @brief Recorre las ocho palabras de la linea en reloj de RAM.
     * @details El indice indica la direccion que usara el proximo flanco.
     * En cada flanco se lee con el indice anterior; despues se prepara
     * la direccion siguiente. Tras la palabra 7 se apaga la lectura.
     */
    localparam integer READ_WORD_INDEX_W =
        $clog2(pkg_memory::WORDS_PER_LINE);
    localparam integer BYTES_PER_WORD =
        pkg_memory::LINE_BYTES / pkg_memory::WORDS_PER_LINE;

    logic reading_mem_q;
    logic [READ_WORD_INDEX_W-1:0] read_word_index_mem_q;

    always_ff @(posedge ram_clk_o or negedge rst_ni) begin
        if (!rst_ni) begin
            read_start_seen_q <= 1'b0;
            reading_mem_q <= 1'b0;
            read_word_index_mem_q <= '0;
        end else if (ram_rst_no) begin
            if (read_start_toggle_q != read_start_seen_q) begin
                read_start_seen_q <= read_start_toggle_q;
                reading_mem_q <= 1'b1;
                read_word_index_mem_q <= 1;
            end else if (reading_mem_q) begin
                if (read_word_index_mem_q ==
                    pkg_memory::WORDS_PER_LINE - 1) begin
                    reading_mem_q <= 1'b0;
                    read_word_index_mem_q <= '0;
                end else begin
                    read_word_index_mem_q <=
                        read_word_index_mem_q + 1'b1;
                end
            end
        end
    end

    assign ram_read_enable_o =
        ram_rst_no &&
        ((read_start_toggle_q != read_start_seen_q) || reading_mem_q);

    assign ram_address_o =
        read_base_q + read_word_index_mem_q * BYTES_PER_WORD;

    /**
    * @brief Reune las palabras leidas por RAM y publica una linea completa.
    * @details En el flanco CPU que genera una subida RAM se guarda el indice
    * del acceso. En el siguiente flanco CPU se captura el dato registrado
    * por RAM. La respuesta aparece en READ_TOTAL_CYCLES y se conserva
    * hasta el handshake del retorno hacia L1, observado por L2.
    */
    localparam integer READ_WORD_BITS =
        pkg_memory::LINE_BITS / pkg_memory::WORDS_PER_LINE;
    localparam integer READ_WORD_COUNT_W =
        $clog2(pkg_memory::WORDS_PER_LINE + 1);

    logic ram_issue_now;
    logic pending_q;
    logic [READ_WORD_INDEX_W-1:0] pending_index_q;
    logic pending_range_q;
    logic [READ_WORD_COUNT_W-1:0] words_captured_q;
    pkg_memory::line_t read_line_q;
    logic read_error_q;
    logic rsp_valid_q;

    assign ram_issue_now =
        ram_read_enable_o &&
        (divider_count_q == MEM_CLOCK_DIV - 1);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pending_q <= 1'b0;
            pending_index_q <= '0;
            pending_range_q <= 1'b0;
            words_captured_q <= '0;
            read_line_q <= '0;
            read_error_q <= 1'b0;
            rsp_valid_q <= 1'b0;
        end else if (read_accept) begin
            pending_q <= 1'b0;
            pending_index_q <= '0;
            pending_range_q <= 1'b0;
            words_captured_q <= '0;
            read_line_q <= '0;
            read_error_q <= 1'b0;
            rsp_valid_q <= 1'b0;
        end else begin
            pending_q <= ram_issue_now;

            if (ram_issue_now) begin
                pending_index_q <= read_word_index_mem_q;
                pending_range_q <= ram_out_of_range_i;
            end

            if (pending_q) begin
                words_captured_q <= words_captured_q + 1'b1;

                if (ram_read_valid_i)
                    read_line_q[pending_index_q * READ_WORD_BITS
                                +: READ_WORD_BITS] <= ram_read_data_i;
                else
                    read_error_q <= 1'b1;

                if (pending_range_q)
                    read_error_q <= 1'b1;
            end

            if (read_busy_q && !rsp_valid_q &&
                read_age_q == READ_TOTAL_CYCLES) begin
                rsp_valid_q <= 1'b1;

                if (words_captured_q + (pending_q ? 1 : 0) !=
                    pkg_memory::WORDS_PER_LINE)
                    read_error_q <= 1'b1;
            end else if (rsp_valid_q && mem_rd_rsp_ready_i) begin
                rsp_valid_q <= 1'b0;
            end
        end
    end

    assign mem_rd_rsp_valid_o = rsp_valid_q;
    assign mem_rd_rsp_id_o = read_id_q;
    assign mem_rd_rsp_base_o = read_base_q;
    assign mem_rd_rsp_data_o = read_line_q;
    assign mem_rd_rsp_error_o = read_error_q;

    /** @brief La ruta de escritura se incorporara en otro incremento. */
    assign ram_write_enable_o = '0;
    assign ram_write_data_o = '0;

    // TODO P2-03: escritura, arbitraje definitivo, timeout y metricas.
endmodule
