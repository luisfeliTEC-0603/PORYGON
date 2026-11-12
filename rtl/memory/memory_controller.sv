/**
 * @brief Controlador de bursts y cruce CPU <-> memoria.
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
     * la solicitud. El arbitro compara ofertas de lectura y escritura.
     * La lectura ocupada se libera al consumir su respuesta.
     */
    localparam integer READ_ID_W = pkg_memory::id_width(L2_MAX_INFLIGHT);
    localparam integer WRITE_ID_W = pkg_memory::id_width(EVICTION_BUFFER_DEPTH);
    localparam integer WRITE_ACCEPT_PHASE =
        (MEM_CLOCK_DIV - 1 -
         (MEM_WRITE_FIRST_WORD_CYCLES % MEM_CLOCK_DIV) +
         MEM_CLOCK_DIV) % MEM_CLOCK_DIV;

    logic read_busy_q;
    logic write_busy_q;
    logic [READ_ID_W-1:0] read_id_q;
    pkg_memory::address_t read_base_q;
    logic [WRITE_ID_W-1:0] write_id_q;
    pkg_memory::address_t write_base_q;
    pkg_memory::line_t write_line_q;
    logic read_accept;
    logic write_accept;
    logic write_phase_ok;
    logic read_offer_seen_q;
    logic write_offer_seen_q;
    logic read_older_q;
    logic read_eligible;
    logic write_eligible;
    logic choose_read;
    logic choose_write;
    logic transfer_active_q;
    logic transfer_write_q;
    logic read_complete_now;
    logic read_word_new;
    logic write_word_new;
    logic write_complete_now;
    logic write_complete_reported_q;
    logic timeout_now;
    logic rsp_valid_q;

    /**
     * @brief Elige la oferta mas antigua que puede avanzar.
     * @details Las banderas seen recuerdan ofertas retenidas con valid.
     * Dos ofertas nuevas en el mismo ciclo favorecen escritura. Una lectura
     * con conflicto EB no compite; una escritura elegida espera su fase RAM.
     */
    assign read_eligible =
        mem_rd_req_valid_i && !read_busy_q && !eb_probe_hit_i;
    assign write_eligible = mem_wr_req_valid_i && !write_busy_q;
    assign choose_read = read_eligible &&
        (!write_eligible ||
         (read_offer_seen_q && !write_offer_seen_q) ||
         (read_offer_seen_q && write_offer_seen_q && read_older_q));
    assign choose_write = write_eligible && !choose_read;
    assign write_phase_ok = divider_count_q == WRITE_ACCEPT_PHASE;

    assign mem_rd_req_ready_o =
        rst_ni && ram_rst_no && !transfer_active_q &&
        !read_busy_q && !eb_probe_hit_i &&
        (!write_eligible || choose_read);
    assign mem_wr_req_ready_o =
        rst_ni && ram_rst_no && !transfer_active_q &&
        !write_busy_q && write_phase_ok &&
        (!read_eligible || choose_write);
    assign read_accept = mem_rd_req_valid_i && mem_rd_req_ready_o;
    assign write_accept = mem_wr_req_valid_i && mem_wr_req_ready_o;

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

    /** @brief La escritura conserva id, base y linea hasta su confirmacion. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_busy_q <= 1'b0;
            write_id_q <= '0;
            write_base_q <= '0;
            write_line_q <= '0;
        end else if (mem_wr_rsp_valid_o && mem_wr_rsp_ready_i) begin
            write_busy_q <= 1'b0;
        end else if (write_accept) begin
            write_busy_q <= 1'b1;
            write_id_q <= mem_wr_req_id_i;
            write_base_q <= mem_wr_req_base_i;
            write_line_q <= mem_wr_req_data_i;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_offer_seen_q <= 1'b0;
            write_offer_seen_q <= 1'b0;
            read_older_q <= 1'b0;
        end else begin
            read_offer_seen_q <= mem_rd_req_valid_i && !read_accept;
            write_offer_seen_q <= mem_wr_req_valid_i && !write_accept;
            if (read_accept)
                read_older_q <= 1'b0;
            else if (write_accept)
                read_older_q <= 1'b1;
            else if (!read_offer_seen_q && mem_rd_req_valid_i &&
                     !write_offer_seen_q && !mem_wr_req_valid_i)
                read_older_q <= 1'b1;
            else if (!write_offer_seen_q && mem_wr_req_valid_i &&
                     !read_offer_seen_q && !mem_rd_req_valid_i)
                read_older_q <= 1'b0;
            else if (!read_offer_seen_q && !write_offer_seen_q &&
                     mem_rd_req_valid_i && mem_wr_req_valid_i)
                read_older_q <= 1'b0;
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
    localparam integer WRITE_TOTAL_CYCLES =
        MEM_WRITE_FIRST_WORD_CYCLES +
        (pkg_memory::WORDS_PER_LINE - 1) * MEM_CLOCK_DIV;
    localparam integer WRITE_AGE_W =
        (WRITE_TOTAL_CYCLES > 1) ? $clog2(WRITE_TOTAL_CYCLES + 1) : 1;
    localparam integer TIMEOUT_W =
        (MEM_TIMEOUT_CYCLES > 1) ? $clog2(MEM_TIMEOUT_CYCLES + 1) : 1;

    logic [READ_AGE_W-1:0] read_age_q;
    logic read_start_toggle_q;
    logic read_start_seen_q;
    logic ram_rise_next;
    logic launch_on_accept;
    logic launch_while_waiting;
    logic [WRITE_AGE_W-1:0] write_age_q;
    logic write_start_toggle_q;
    logic write_start_seen_q;
    logic write_done_toggle_mem_q;
    logic write_done_seen_q;
    logic write_word_seen_q;
    logic write_error_mem_q;
    logic [TIMEOUT_W-1:0] active_age_q;

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
     * @brief Cuenta solo desde aceptacion hasta resultado disponible.
     * @details La espera de arbitraje y la espera de consumo no pertenecen
     * al timeout. La disponibilidad de la respuesta detiene la cuenta;
     * el evento de estado activo cuenta solo los ciclos de transferencia.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            active_age_q <= '0;
        else if (read_accept || write_accept)
            active_age_q <= 1;
        else if (transfer_active_q && !read_complete_now &&
                 !write_complete_now && !mem_wr_rsp_valid_o &&
                 active_age_q < MEM_TIMEOUT_CYCLES)
            active_age_q <= active_age_q + 1'b1;
    end

    /**
     * @brief Conserva la RAM para un burst hasta que su resultado aparece.
     * @details Una respuesta puede permanecer retenida en su canal mientras
     * un burst independiente del otro tipo utiliza la RAM.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            transfer_active_q <= 1'b0;
            transfer_write_q <= 1'b0;
        end else if (read_accept || write_accept) begin
            transfer_active_q <= 1'b1;
            transfer_write_q <= write_accept;
        end else if (transfer_active_q &&
                     ((!transfer_write_q && read_complete_now) ||
                      (transfer_write_q && mem_wr_rsp_valid_o))) begin
            transfer_active_q <= 1'b0;
        end
    end

    /**
     * @brief Avisa el primer store un ciclo CPU antes del flanco RAM.
     * @details La fase de aceptacion garantiza que RAM sube en F. Despues
     * de F se realizan las otras siete escrituras cada MEM_CLOCK_DIV ciclos.
     */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_age_q <= '0;
            write_start_toggle_q <= 1'b0;
        end else if (write_accept) begin
            write_age_q <= 1;
        end else if (write_busy_q &&
                     write_age_q < WRITE_TOTAL_CYCLES) begin
            write_age_q <= write_age_q + 1'b1;
            if (write_age_q == MEM_WRITE_FIRST_WORD_CYCLES - 1)
                write_start_toggle_q <= ~write_start_toggle_q;
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
    localparam integer READ_WORD_BITS =
        pkg_memory::LINE_BITS / pkg_memory::WORDS_PER_LINE;

    logic reading_mem_q;
    logic [READ_WORD_INDEX_W-1:0] read_word_index_mem_q;
    logic writing_mem_q;
    logic [READ_WORD_INDEX_W-1:0] write_word_index_mem_q;
    logic read_word_toggle_mem_q;
    logic [READ_WORD_INDEX_W-1:0] read_issued_index_mem_q;
    logic read_issued_range_mem_q;
    logic write_word_toggle_mem_q;
    logic write_word_ok_mem_q;

    always_ff @(posedge ram_clk_o or negedge rst_ni) begin
        if (!rst_ni) begin
            read_start_seen_q <= 1'b0;
            reading_mem_q <= 1'b0;
            read_word_index_mem_q <= '0;
            read_word_toggle_mem_q <= 1'b0;
            read_issued_index_mem_q <= '0;
            read_issued_range_mem_q <= 1'b0;
        end else if (ram_rst_no) begin
            if (ram_read_enable_o) begin
                read_word_toggle_mem_q <= ~read_word_toggle_mem_q;
                read_issued_index_mem_q <= read_word_index_mem_q;
                read_issued_range_mem_q <= ram_out_of_range_i;
            end
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

    /**
     * @brief Escribe las ocho palabras de la linea en flancos RAM.
     * @details El primer flanco reconoce el aviso y usa indice cero.
     * Cada flanco posterior usa el indice anterior. La ultima escritura
     * cambia done_toggle para publicar la confirmacion en ese mismo ciclo.
     */
    always_ff @(posedge ram_clk_o or negedge rst_ni) begin
        if (!rst_ni) begin
            write_start_seen_q <= 1'b0;
            writing_mem_q <= 1'b0;
            write_word_index_mem_q <= '0;
            write_done_toggle_mem_q <= 1'b0;
            write_error_mem_q <= 1'b0;
            write_word_toggle_mem_q <= 1'b0;
            write_word_ok_mem_q <= 1'b0;
        end else if (ram_rst_no) begin
            if (|ram_write_enable_o) begin
                write_word_toggle_mem_q <= ~write_word_toggle_mem_q;
                write_word_ok_mem_q <= !ram_out_of_range_i;
            end
            if (write_start_toggle_q != write_start_seen_q) begin
                write_start_seen_q <= write_start_toggle_q;
                writing_mem_q <= 1'b1;
                write_word_index_mem_q <= 1;
                write_error_mem_q <= ram_out_of_range_i;
            end else if (writing_mem_q) begin
                write_error_mem_q <= write_error_mem_q || ram_out_of_range_i;
                if (write_word_index_mem_q ==
                    pkg_memory::WORDS_PER_LINE - 1) begin
                    writing_mem_q <= 1'b0;
                    write_word_index_mem_q <= '0;
                    write_done_toggle_mem_q <= ~write_done_toggle_mem_q;
                end else begin
                    write_word_index_mem_q <=
                        write_word_index_mem_q + 1'b1;
                end
            end
        end
    end

    assign ram_write_enable_o =
        (ram_rst_no &&
         ((write_start_toggle_q != write_start_seen_q) || writing_mem_q))
            ? '1 : '0;
    assign ram_address_o =
        (|ram_write_enable_o)
            ? write_base_q + write_word_index_mem_q * BYTES_PER_WORD
            : read_base_q + read_word_index_mem_q * BYTES_PER_WORD;
    assign ram_write_data_o =
        write_line_q[write_word_index_mem_q * READ_WORD_BITS +:
                     READ_WORD_BITS];

    /**
    * @brief Reune las palabras leidas por RAM y publica una linea completa.
    * @details RAM cambia un bit por cada acceso fisico y conserva su indice.
    * CPU detecta el bit nuevo en el flanco siguiente y captura el dato.
    * La respuesta hacia L2 aparece tras ocho accesos y al menos
    * READ_TOTAL_CYCLES; permanece estable hasta su handshake. Un reloj RAM
    * detenido espera al timeout en vez de fingir lecturas.
    */
    localparam integer READ_WORD_COUNT_W =
        $clog2(pkg_memory::WORDS_PER_LINE + 1);

    logic read_word_seen_q;
    logic [READ_WORD_COUNT_W-1:0] words_captured_q;
    pkg_memory::line_t read_line_q;
    logic read_error_q;
    logic read_range_error_q;

    assign read_word_new =
        read_word_toggle_mem_q != read_word_seen_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            read_word_seen_q <= 1'b0;
            words_captured_q <= '0;
            read_line_q <= '0;
            read_error_q <= 1'b0;
            read_range_error_q <= 1'b0;
            rsp_valid_q <= 1'b0;
        end else if (read_accept) begin
            read_word_seen_q <= read_word_toggle_mem_q;
            words_captured_q <= '0;
            read_line_q <= '0;
            read_error_q <= 1'b0;
            read_range_error_q <= 1'b0;
            rsp_valid_q <= 1'b0;
        end else begin
            if (read_word_new) begin
                read_word_seen_q <= read_word_toggle_mem_q;
                words_captured_q <= words_captured_q + 1'b1;

                if (ram_read_valid_i)
                    read_line_q[read_issued_index_mem_q * READ_WORD_BITS
                                +: READ_WORD_BITS] <= ram_read_data_i;
                else
                    read_error_q <= 1'b1;

                if (read_issued_range_mem_q) begin
                    read_error_q <= 1'b1;
                    read_range_error_q <= 1'b1;
                end
            end

            if (read_complete_now) begin
                rsp_valid_q <= 1'b1;
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
    assign read_complete_now =
        read_busy_q && !rsp_valid_q &&
        (read_age_q == READ_TOTAL_CYCLES) &&
        (words_captured_q + (read_word_new ? 1 : 0) ==
         pkg_memory::WORDS_PER_LINE);

    /**
     * @brief Retiene la confirmacion hasta que el eviction buffer la consume.
     * @details El bit done cambia al almacenarse la palabra 7. El bit seen
     * sigue siendo distinto mientras la respuesta esta pendiente.
     */
    assign mem_wr_rsp_valid_o =
        write_busy_q && (write_done_toggle_mem_q != write_done_seen_q);
    assign mem_wr_rsp_id_o = write_id_q;
    assign mem_wr_rsp_base_o = write_base_q;
    assign mem_wr_rsp_error_o = write_error_mem_q;
    assign write_word_new =
        write_word_toggle_mem_q != write_word_seen_q;
    assign write_complete_now =
        mem_wr_rsp_valid_o && !write_complete_reported_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            write_done_seen_q <= 1'b0;
            write_word_seen_q <= 1'b0;
            write_complete_reported_q <= 1'b0;
        end else begin
            if (write_accept) begin
                write_word_seen_q <= write_word_toggle_mem_q;
                write_complete_reported_q <= 1'b0;
            end else begin
                if (write_word_new)
                    write_word_seen_q <= write_word_toggle_mem_q;
                if (mem_wr_rsp_valid_o)
                    write_complete_reported_q <= 1'b1;
            end
            if (mem_wr_rsp_valid_o && mem_wr_rsp_ready_i)
                write_done_seen_q <= write_done_toggle_mem_q;
        end
    end

    assign timeout_now =
        transfer_active_q &&
        (active_age_q >= MEM_TIMEOUT_CYCLES) &&
        !read_complete_now && !write_complete_now &&
        !mem_wr_rsp_valid_o;

    /**
     * @brief Expone eventos de una sola vez y estados por ciclo CPU.
     * @details Cada palabra se informa una vez tras su flanco RAM real.
     * Complete ocurre al estar disponible el resultado, antes de ready;
     * el evento de escritura cruza al siguiente flanco CPU observable.
     */
    always_comb begin
        perf_events_o = '0;
        perf_events_o.complete_error = pkg_metrics::ERROR_NONE;

        if (read_accept) begin
            perf_events_o.accept.valid = 1'b1;
            perf_events_o.accept.write = 1'b0;
            perf_events_o.accept.id = mem_rd_req_id_i;
            perf_events_o.accept.base = mem_rd_req_base_i;
        end else if (write_accept) begin
            perf_events_o.accept.valid = 1'b1;
            perf_events_o.accept.write = 1'b1;
            perf_events_o.accept.id = mem_wr_req_id_i;
            perf_events_o.accept.base = mem_wr_req_base_i;
        end

        if (write_word_new && write_word_ok_mem_q) begin
            perf_events_o.word.valid = 1'b1;
            perf_events_o.word.write = 1'b1;
            perf_events_o.word.id = write_id_q;
            perf_events_o.word.base = write_base_q;
        end else if (read_word_new && ram_read_valid_i &&
                     !read_issued_range_mem_q) begin
            perf_events_o.word.valid = 1'b1;
            perf_events_o.word.write = 1'b0;
            perf_events_o.word.id = read_id_q;
            perf_events_o.word.base = read_base_q;
        end

        if (read_complete_now) begin
            perf_events_o.complete.valid = 1'b1;
            perf_events_o.complete.write = 1'b0;
            perf_events_o.complete.id = read_id_q;
            perf_events_o.complete.base = read_base_q;
            if (read_range_error_q ||
                (read_word_new && read_issued_range_mem_q))
                perf_events_o.complete_error = pkg_metrics::ERROR_ADDRESS;
            else if (read_error_q ||
                     (read_word_new && !ram_read_valid_i))
                perf_events_o.complete_error = pkg_metrics::ERROR_PROTOCOL;
        end else if (write_complete_now) begin
            perf_events_o.complete.valid = 1'b1;
            perf_events_o.complete.write = 1'b1;
            perf_events_o.complete.id = write_id_q;
            perf_events_o.complete.base = write_base_q;
            if (write_error_mem_q)
                perf_events_o.complete_error = pkg_metrics::ERROR_ADDRESS;
        end else if (timeout_now) begin
            perf_events_o.complete.valid = 1'b1;
            perf_events_o.complete.write = transfer_write_q;
            perf_events_o.complete.id =
                transfer_write_q ? write_id_q : read_id_q;
            perf_events_o.complete.base =
                transfer_write_q ? write_base_q : read_base_q;
            perf_events_o.complete_error = pkg_metrics::ERROR_TIMEOUT;
        end

        perf_events_o.read_active = transfer_active_q && !transfer_write_q;
        perf_events_o.write_active = transfer_active_q &&
                                     transfer_write_q && !mem_wr_rsp_valid_o;
        perf_events_o.read_wait =
            rst_ni && mem_rd_req_valid_i && !mem_rd_req_ready_o;
        perf_events_o.write_wait =
            rst_ni && mem_wr_req_valid_i && !mem_wr_req_ready_o;
        perf_events_o.read_rsp_wait =
            mem_rd_rsp_valid_o && !mem_rd_rsp_ready_i;
        perf_events_o.write_rsp_wait =
            mem_wr_rsp_valid_o && !mem_wr_rsp_ready_i;
        perf_events_o.read_rsp_consumed =
            mem_rd_rsp_valid_o && mem_rd_rsp_ready_i;
        perf_events_o.write_rsp_consumed =
            mem_wr_rsp_valid_o && mem_wr_rsp_ready_i;
        perf_events_o.reads_pending = read_busy_q;
        perf_events_o.writes_pending = write_busy_q;
        perf_events_o.read_responses_pending = mem_rd_rsp_valid_o;
        perf_events_o.write_responses_pending = mem_wr_rsp_valid_o;
    end

`ifndef SYNTHESIS
    initial begin
        if (MEM_CLOCK_DIV < 2 || MEM_CLOCK_DIV > 5)
            $fatal(1, "MEM_CLOCK_DIV debe estar entre 2 y 5");
        if (MEM_READ_FIRST_WORD_CYCLES <= MEM_CLOCK_DIV ||
            MEM_WRITE_FIRST_WORD_CYCLES < 2)
            $fatal(1, "latencia inicial incompatible con cruce de reloj");
        if (MEM_TIMEOUT_CYCLES <= READ_TOTAL_CYCLES ||
            MEM_TIMEOUT_CYCLES <= WRITE_TOTAL_CYCLES)
            $fatal(1, "MEM_TIMEOUT_CYCLES debe exceder ambos bursts");
    end

    always @(posedge clk_i) begin
        if (rst_ni && timeout_now) begin
            if (transfer_write_q)
                $fatal(1,
                       "memory_controller timeout tipo=write base=%h ciclos=%0d",
                       write_base_q, active_age_q);
            else
                $fatal(1,
                       "memory_controller timeout tipo=read base=%h ciclos=%0d",
                       read_base_q, active_age_q);
        end
    end
`endif
endmodule
