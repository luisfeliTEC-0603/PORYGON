/**
 * @brief Verifica el controlador junto con la RAM real de 64 KiB.
 * @details Comprueba escritura y lectura de lineas, tiempos, respuestas
 * retenidas, arbitraje, conflicto EB, reset y errores. Los modos especiales
 * comprueban timeout con reloj detenido y arbitraje en cada fase.
 * @param DIV Ciclos CPU por ciclo RAM; ejecutar con 2 y 5.
 * @param READ_FIRST, WRITE_FIRST Latencias iniciales independientes.
 * @param TEST_MODE 0: recorrido completo; 1/2: timeout aislado de lectura/
 * escritura; 3/4: timeout de lectura con confirmacion anterior retenida/
 * consumida; 5: arbitraje por fase. Modos 1..4 esperan el fatal del DUT.
 */
module tb_memory_controller_full;
    import pkg_memory::*;

    parameter integer DIV = 2;
    parameter integer READ_FIRST = MEM_READ_FIRST_WORD_CYCLES_DEFAULT;
    parameter integer WRITE_FIRST = MEM_WRITE_FIRST_WORD_CYCLES_DEFAULT;
    parameter integer TEST_MODE = 0;
    localparam integer WRITE_TOTAL = WRITE_FIRST + (WORDS_PER_LINE - 1) * DIV;
    localparam integer READ_TOTAL = READ_FIRST + (WORDS_PER_LINE - 1) * DIV;
    localparam integer READ_ACCEPT_PHASE_TB =
        (DIV - (READ_FIRST % DIV)) % DIV;
    localparam integer WRITE_ACCEPT_PHASE_TB =
        (DIV - 1 - (WRITE_FIRST % DIV) + DIV) % DIV;
    localparam address_t A = DATA_BASE_ADDRESS;
    localparam address_t B = DATA_BASE_ADDRESS + LINE_BYTES;
    localparam address_t C = DATA_BASE_ADDRESS + 2 * LINE_BYTES;
    localparam address_t D = DATA_BASE_ADDRESS + 3 * LINE_BYTES;
    localparam address_t END_BASE = DATA_BASE_ADDRESS + MEMORY_BYTES - 16;

    logic cpu_clk = 1'b0;
    logic rst_n = 1'b1;
    logic rd_valid = 1'b0;
    logic rd_ready;
    logic [id_width(L2_MAX_INFLIGHT_DEFAULT)-1:0] rd_id = '0;
    address_t rd_base = '0;
    logic rd_rsp_valid;
    logic rd_rsp_ready = 1'b0;
    logic [id_width(L2_MAX_INFLIGHT_DEFAULT)-1:0] rd_rsp_id;
    address_t rd_rsp_base;
    line_t rd_rsp_data;
    logic rd_rsp_error;
    logic eb_hit = 1'b0;
    logic wr_valid = 1'b0;
    logic wr_ready;
    logic [id_width(EVICTION_BUFFER_DEPTH_DEFAULT)-1:0] wr_id = '0;
    address_t wr_base = '0;
    line_t wr_data = '0;
    logic wr_rsp_valid;
    logic wr_rsp_ready = 1'b0;
    logic [id_width(EVICTION_BUFFER_DEPTH_DEFAULT)-1:0] wr_rsp_id;
    address_t wr_rsp_base;
    logic wr_rsp_error;
    logic ram_clk;
    logic ram_rst_n;
    address_t ram_address;
    logic ram_read_enable;
    byte_mask_t ram_write_enable;
    word_t ram_write_data;
    word_t ram_read_data;
    logic ram_read_valid;
    logic ram_read_valid_for_controller;
    logic ram_out_of_range;
    logic inject_protocol_word = 1'b0;
    logic protocol_drop_q = 1'b0;
    pkg_metrics::mem_events_t perf_events;
    integer cpu_edges = 0;
    integer rd_accepts = 0;
    integer wr_accepts = 0;
    integer rd_accept_edge = -1;
    integer wr_accept_edge = -1;
    integer read_words_in_burst = 0;
    integer previous_read_edge = -1;
    address_t expected_read_base;
    logic [id_width(L2_MAX_INFLIGHT_DEFAULT)-1:0] expected_read_id;
    logic [WORDS_PER_LINE-1:0] read_word_event_mask = '0;
    integer observed_read_word_index;
    integer clock_age = 0;
    logic clock_check_armed = 1'b0;
    integer words_written = 0;
    integer physical_read_words = 0;
    integer physical_write_words = 0;
    integer protocol_drop_count = 0;
    integer timeout_word_events = 0;
    integer event_read_words = 0;
    integer event_write_words = 0;
    integer event_read_accepts = 0;
    integer event_write_accepts = 0;
    integer event_read_completes = 0;
    integer event_write_completes = 0;
    integer event_read_consumes = 0;
    integer event_write_consumes = 0;
    integer read_active_span = 0;
    integer write_active_span = 0;
    address_t expected_write_base;
    line_t expected_write_line;
    logic [id_width(EVICTION_BUFFER_DEPTH_DEFAULT)-1:0] expected_write_id;

    always #5 cpu_clk = ~cpu_clk;

    /** @brief Comprueba fase continua del divisor y dos flancos de reset RAM. */
    always @(negedge rst_n) begin
        clock_age = 0;
        clock_check_armed = 1'b1;
    end

    always @(posedge cpu_clk) begin
        if (clock_check_armed && (TEST_MODE == 0 || TEST_MODE == 5)) begin
            if (!rst_n)
                clock_age = 0;
            else
                clock_age = clock_age + 1;
            #1;
            if (!rst_n) begin
                if (ram_clk !== 1'b0 || ram_rst_n !== 1'b0)
                    $fatal(1, "reloj o reset RAM incorrecto durante reset");
            end else begin
                if (ram_clk !==
                    (((clock_age - 1) % DIV) < ((DIV + 1) / 2)) ||
                    ram_rst_n !== (clock_age >= DIV + 1))
                    $fatal(1, "fase de reloj/reset RAM incorrecta ciclo=%0d",
                           clock_age);
            end
        end
    end

    memory_controller #(
        .MEM_CLOCK_DIV(DIV),
        .MEM_READ_FIRST_WORD_CYCLES(READ_FIRST),
        .MEM_WRITE_FIRST_WORD_CYCLES(WRITE_FIRST),
        .MEM_TIMEOUT_CYCLES((TEST_MODE >= 1 && TEST_MODE <= 4)
                            ? 45 : MEM_TIMEOUT_CYCLES_DEFAULT)
    ) dut (
        .clk_i(cpu_clk), .rst_ni(rst_n),
        .mem_rd_req_valid_i(rd_valid), .mem_rd_req_ready_o(rd_ready),
        .mem_rd_req_id_i(rd_id), .mem_rd_req_base_i(rd_base),
        .eb_probe_hit_i(eb_hit),
        .mem_rd_rsp_valid_o(rd_rsp_valid), .mem_rd_rsp_ready_i(rd_rsp_ready),
        .mem_rd_rsp_id_o(rd_rsp_id), .mem_rd_rsp_base_o(rd_rsp_base),
        .mem_rd_rsp_data_o(rd_rsp_data), .mem_rd_rsp_error_o(rd_rsp_error),
        .mem_wr_req_valid_i(wr_valid), .mem_wr_req_ready_o(wr_ready),
        .mem_wr_req_id_i(wr_id), .mem_wr_req_base_i(wr_base),
        .mem_wr_req_data_i(wr_data),
        .mem_wr_rsp_valid_o(wr_rsp_valid), .mem_wr_rsp_ready_i(wr_rsp_ready),
        .mem_wr_rsp_id_o(wr_rsp_id), .mem_wr_rsp_base_o(wr_rsp_base),
        .mem_wr_rsp_error_o(wr_rsp_error),
        .ram_clk_o(ram_clk), .ram_rst_no(ram_rst_n),
        .ram_address_o(ram_address), .ram_read_enable_o(ram_read_enable),
        .ram_write_enable_o(ram_write_enable), .ram_write_data_o(ram_write_data),
        .ram_read_data_i(ram_read_data),
        .ram_read_valid_i(ram_read_valid_for_controller),
        .ram_out_of_range_i(ram_out_of_range), .perf_events_o(perf_events)
    );

    main_memory u_ram (
        .clk_i(ram_clk), .rst_ni(ram_rst_n),
        .address_i(ram_address), .read_enable_i(ram_read_enable),
        .write_enable_i(ram_write_enable), .write_data_i(ram_write_data),
        .read_data_o(ram_read_data), .read_valid_o(ram_read_valid),
        .out_of_range_o(ram_out_of_range)
    );

    /** @brief Inyecta una sola palabra sin valid para probar ERROR_PROTOCOL. */
    assign ram_read_valid_for_controller =
        ram_read_valid && !protocol_drop_q;

    always @(posedge ram_clk or negedge rst_n) begin
        if (!rst_n)
            protocol_drop_q <= 1'b0;
        else
            protocol_drop_q <= inject_protocol_word && ram_read_enable &&
                               ram_address == A + 12;
    end

    function automatic line_t pattern(input word_t seed);
        line_t result;
        for (integer i = 0; i < WORDS_PER_LINE; i++)
            result[i * 32 +: 32] = seed + i;
        return result;
    endfunction

    always @(posedge cpu_clk) begin
        cpu_edges = cpu_edges + 1;
        if (rd_valid && rd_ready) begin
            rd_accepts = rd_accepts + 1;
            rd_accept_edge = cpu_edges;
            read_active_span = 0;
            read_words_in_burst = 0;
            previous_read_edge = -1;
            expected_read_base = rd_base;
            expected_read_id = rd_id;
            read_word_event_mask = '0;
        end
        if (wr_valid && wr_ready) begin
            wr_accepts = wr_accepts + 1;
            wr_accept_edge = cpu_edges;
            words_written = 0;
            write_active_span = 0;
            expected_write_id = wr_id;
            expected_write_base = wr_base;
            expected_write_line = wr_data;
        end
        if (TEST_MODE != 0 && perf_events.word.valid)
            timeout_word_events = timeout_word_events + 1;
        if (TEST_MODE == 0 || TEST_MODE == 5) begin
        if (rd_valid && rd_ready && wr_valid && wr_ready)
            $fatal(1, "dos bursts aceptados en el mismo flanco");
        if (perf_events.accept.valid) begin
            if (perf_events.accept.write) begin
                event_write_accepts = event_write_accepts + 1;
                if (!(wr_valid && wr_ready) ||
                    perf_events.accept.id !== wr_id ||
                    perf_events.accept.base !== wr_base)
                    $fatal(1, "evento de aceptacion de escritura incorrecto");
            end else begin
                event_read_accepts = event_read_accepts + 1;
                if (!(rd_valid && rd_ready) ||
                    perf_events.accept.id !== rd_id ||
                    perf_events.accept.base !== rd_base)
                    $fatal(1, "evento de aceptacion de lectura incorrecto");
            end
        end
        if (perf_events.word.valid) begin
            if (perf_events.word.write) begin
                event_write_words = event_write_words + 1;
                if (perf_events.word.id !== expected_write_id ||
                    perf_events.word.base !== expected_write_base)
                    $fatal(1, "evento de palabra escrita sin asociacion");
            end else begin
                if (cpu_edges - rd_accept_edge < READ_FIRST ||
                    cpu_edges - rd_accept_edge >= READ_TOTAL + DIV ||
                    (cpu_edges - rd_accept_edge - READ_FIRST) % DIV != 0 ||
                    perf_events.word.id !== expected_read_id ||
                    perf_events.word.base !== expected_read_base)
                    $fatal(1, "evento de palabra leida fuera de ciclo o asociacion");
                observed_read_word_index =
                    (cpu_edges - rd_accept_edge - READ_FIRST) / DIV;
                if (read_word_event_mask[observed_read_word_index])
                    $fatal(1, "evento de palabra leida duplicado");
                read_word_event_mask[observed_read_word_index] = 1'b1;
                event_read_words = event_read_words + 1;
            end
        end
        if (perf_events.complete.valid) begin
            if (perf_events.complete.write) begin
                event_write_completes = event_write_completes + 1;
                if (cpu_edges - wr_accept_edge != WRITE_TOTAL + 1 ||
                    perf_events.complete.id !== expected_write_id ||
                    perf_events.complete.base !== expected_write_base ||
                    perf_events.complete_error !==
                        ((expected_write_id == 6)
                            ? pkg_metrics::ERROR_ADDRESS
                            : pkg_metrics::ERROR_NONE))
                    $fatal(1, "evento de fin de escritura incorrecto");
            end else begin
                event_read_completes = event_read_completes + 1;
                if (cpu_edges - rd_accept_edge != READ_TOTAL ||
                    perf_events.complete.id !== rd_rsp_id ||
                    perf_events.complete.base !== rd_rsp_base ||
                    perf_events.complete_error !==
                        (inject_protocol_word
                            ? pkg_metrics::ERROR_PROTOCOL
                            : ((rd_rsp_base == END_BASE)
                                ? pkg_metrics::ERROR_ADDRESS
                                : pkg_metrics::ERROR_NONE)))
                    $fatal(1, "evento de fin de lectura incorrecto");
            end
        end
        if (perf_events.read_rsp_consumed)
            event_read_consumes = event_read_consumes + 1;
        if (perf_events.write_rsp_consumed)
            event_write_consumes = event_write_consumes + 1;
        if (perf_events.read_active && perf_events.write_active)
            $fatal(1, "metricas indican dos bursts activos");
        if (perf_events.read_active)
            read_active_span = read_active_span + 1;
        if (perf_events.write_active)
            write_active_span = write_active_span + 1;
        if (perf_events.complete.valid &&
            ((perf_events.complete.write &&
              write_active_span != WRITE_TOTAL) ||
             (!perf_events.complete.write &&
              read_active_span != READ_TOTAL)))
            $fatal(1, "ciclos activos de memoria incorrectos");
        end
    end

    always @(posedge ram_clk) begin
        if ((TEST_MODE == 0 || TEST_MODE == 5) && ram_read_enable) begin
            if (read_words_in_burst >= WORDS_PER_LINE ||
                ram_address !== expected_read_base + 4 * read_words_in_burst)
                $fatal(1, "direccion de lectura RAM incorrecta");
            if (read_words_in_burst == 0) begin
                if (cpu_edges - rd_accept_edge != READ_FIRST - 1)
                    $fatal(1, "primera lectura RAM fuera de ciclo");
            end else if (cpu_edges - previous_read_edge != DIV)
                $fatal(1, "intervalo entre lecturas RAM incorrecto");
            previous_read_edge = cpu_edges;
            read_words_in_burst = read_words_in_burst + 1;
        end
        if (inject_protocol_word && ram_read_enable && ram_address == A + 12)
            protocol_drop_count = protocol_drop_count + 1;
        if (ram_read_enable && !ram_out_of_range)
            physical_read_words = physical_read_words + 1;
        if (|ram_write_enable) begin
            if (ram_read_enable || ram_write_enable !== 4'b1111)
                $fatal(1, "RAM recibio acceso simultaneo o mascara incompleta");
            if (words_written >= WORDS_PER_LINE ||
                ram_address !== expected_write_base + 4 * words_written ||
                ram_write_data !== expected_write_line[32 * words_written +: 32])
                $fatal(1, "palabra %0d de escritura incorrecta", words_written);
            if (cpu_edges - wr_accept_edge != WRITE_FIRST + DIV * words_written)
                $fatal(1, "palabra %0d escrita fuera de ciclo", words_written);
            if (!ram_out_of_range)
                physical_write_words = physical_write_words + 1;
            words_written = words_written + 1;
        end
    end

    task automatic reset_controller;
        @(negedge cpu_clk);
        rst_n = 1'b0;
        rd_valid = 1'b0;
        wr_valid = 1'b0;
        rd_rsp_ready = 1'b0;
        wr_rsp_ready = 1'b0;
        eb_hit = 1'b0;
        #1;
        if (rd_rsp_valid !== 1'b0 || wr_rsp_valid !== 1'b0 ||
            rd_ready !== 1'b0 || wr_ready !== 1'b0)
            $fatal(1, "reset no cancelo las respuestas");
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
    endtask

    /** @brief Con fases iguales, una oferta anterior gana al desempate. */
    task automatic check_older_offer(input logic read_older);
        integer old_reads;
        integer old_writes;
        reset_controller();
        if (read_older)
            send_write(3, C, pattern(32'hDD00_0000));
        else
            send_read(3, A);
        old_reads = rd_accepts;
        old_writes = wr_accepts;
        repeat (4) @(posedge cpu_clk);
        @(negedge cpu_clk);
        if (read_older) begin
            rd_id = 1;
            rd_base = A;
            rd_valid = 1'b1;
        end else begin
            wr_id = 2;
            wr_base = B;
            wr_data = pattern(32'hCC00_0000);
            wr_valid = 1'b1;
        end
        repeat (2) @(posedge cpu_clk);
        @(negedge cpu_clk);
        if (read_older) begin
            wr_id = 2;
            wr_base = B;
            wr_data = pattern(32'hCC00_0000);
            wr_valid = 1'b1;
        end else begin
            rd_id = 1;
            rd_base = A;
            rd_valid = 1'b1;
        end
        if (read_older) begin
            wait (wr_rsp_valid);
            consume_write();
        end else begin
            wait (rd_rsp_valid);
            consume_read();
        end
        while (rd_accepts == old_reads && wr_accepts == old_writes) begin
            @(posedge cpu_clk);
            #1;
        end
        if (read_older ?
            (rd_accepts != old_reads + 1 || wr_accepts != old_writes) :
            (wr_accepts != old_writes + 1 || rd_accepts != old_reads))
            $fatal(1, "antiguedad ignorada en fase compartida");
        if (read_older) rd_valid = 1'b0;
        else wr_valid = 1'b0;
        while (rd_accepts == old_reads || wr_accepts == old_writes) begin
            @(posedge cpu_clk);
            #1;
        end
        if (read_older) wr_valid = 1'b0;
        else rd_valid = 1'b0;
        wait (rd_rsp_valid && wr_rsp_valid);
        #1;
        if (rd_rsp_id !== 1 || rd_rsp_base !== A || rd_rsp_error ||
            wr_rsp_id !== 2 || wr_rsp_base !== B || wr_rsp_error)
            $fatal(1, "respuesta de arbitraje por antiguedad incorrecta");
        consume_read();
        consume_write();
    endtask

    task automatic send_write(input integer id, input address_t base,
                              input line_t data);
        integer before_count;
        before_count = wr_accepts;
        @(negedge cpu_clk);
        wr_id = id;
        wr_base = base;
        wr_data = data;
        wr_valid = 1'b1;
        while (wr_accepts == before_count) begin
            @(posedge cpu_clk);
            #1;
        end
        wr_valid = 1'b0;
        wr_id = '0;
        wr_base = '0;
        wr_data = '0;
    endtask

    task automatic send_read(input integer id, input address_t base);
        integer before_count;
        before_count = rd_accepts;
        @(negedge cpu_clk);
        rd_id = id;
        rd_base = base;
        rd_valid = 1'b1;
        while (rd_accepts == before_count) begin
            @(posedge cpu_clk);
            #1;
        end
        rd_valid = 1'b0;
        rd_id = '0;
        rd_base = '0;
    endtask

    task automatic expect_write(input integer id, input address_t base,
                                input logic expected_error);
        @(posedge wr_rsp_valid);
        #1;
        if (cpu_edges - wr_accept_edge != WRITE_TOTAL ||
            words_written != WORDS_PER_LINE ||
            wr_rsp_id !== id || wr_rsp_base !== base ||
            wr_rsp_error !== expected_error)
            $fatal(1, "confirmacion de escritura incorrecta");
        repeat (3) begin
            @(posedge cpu_clk);
            #1;
            if (!wr_rsp_valid || wr_rsp_id !== id ||
                wr_rsp_base !== base || wr_rsp_error !== expected_error)
                $fatal(1, "confirmacion de escritura no retenida");
        end
    endtask

    task automatic consume_write;
        @(negedge cpu_clk);
        wr_rsp_ready = 1'b1;
        @(posedge cpu_clk);
        #1;
        wr_rsp_ready = 1'b0;
        if (wr_rsp_valid !== 1'b0)
            $fatal(1, "confirmacion de escritura no consumida");
    endtask

    task automatic expect_read(input integer id, input address_t base,
                               input line_t data);
        @(posedge rd_rsp_valid);
        #1;
        if (cpu_edges - rd_accept_edge != READ_TOTAL ||
            rd_rsp_id !== id || rd_rsp_base !== base ||
            rd_rsp_data !== data || rd_rsp_error !== 1'b0)
            $fatal(1, "respuesta de lectura incorrecta");
    endtask

    task automatic consume_read;
        @(negedge cpu_clk);
        rd_rsp_ready = 1'b1;
        @(posedge cpu_clk);
        #1;
        rd_rsp_ready = 1'b0;
        if (rd_rsp_valid !== 1'b0)
            $fatal(1, "respuesta de lectura no consumida");
    endtask

    /** @brief Comprueba ERROR_PROTOCOL al perder valid en la palabra 3. */
    task automatic check_protocol_error;
        inject_protocol_word = 1'b1;
        send_read(2, A);
        @(posedge rd_rsp_valid);
        #1;
        if (cpu_edges - rd_accept_edge != READ_TOTAL ||
            rd_rsp_id !== 2 || rd_rsp_base !== A ||
            rd_rsp_error !== 1'b1)
            $fatal(1, "respuesta de error de protocolo incorrecta");
        for (integer i = 0; i < WORDS_PER_LINE; i++)
            if (rd_rsp_data[32 * i +: 32] !==
                ((i == 3) ? 32'b0 : 32'hCAFE_0000 + i))
                $fatal(1, "palabra %0d alterada por error de protocolo", i);
        inject_protocol_word = 1'b0;
        consume_read();
    endtask

    /** @brief valid retenido no debe aceptar dos veces la misma lectura. */
    task automatic check_read_reservation;
        integer before_count;
        before_count = rd_accepts;
        @(negedge cpu_clk);
        rd_id = 2;
        rd_base = A;
        rd_valid = 1'b1;
        while (rd_accepts == before_count) begin
            @(posedge cpu_clk);
            #1;
        end
        @(negedge cpu_clk);
        rd_id = 1;
        rd_base = B;
        repeat (3) begin
            @(posedge cpu_clk);
            #1;
            if (rd_ready !== 1'b0 || rd_accepts != before_count + 1)
                $fatal(1, "valid retenido duplico lectura aceptada");
        end
        rd_valid = 1'b0;
        expect_read(2, A, pattern(32'h1234_0000));
        consume_read();
    endtask

    /**
     * @brief Ofrece ambos canales en cada fase y comprueba quien puede iniciar.
     * @details La fase esperada se calcula desde el contrato, no desde el DUT.
     */
    task automatic check_simultaneous_phase(input integer phase_offset);
        integer old_reads;
        integer old_writes;
        integer offer_edge;
        integer phase_at_offer;
        integer read_delay;
        integer write_delay;
        logic expect_write_first;
        reset_controller();
        repeat (phase_offset) @(posedge cpu_clk);
        @(negedge cpu_clk);
        old_reads = rd_accepts;
        old_writes = wr_accepts;
        offer_edge = cpu_edges;
        phase_at_offer = (DIV - 1 + clock_age) % DIV;
        read_delay =
            (READ_ACCEPT_PHASE_TB - phase_at_offer + DIV) % DIV;
        write_delay =
            (WRITE_ACCEPT_PHASE_TB - phase_at_offer + DIV) % DIV;
        expect_write_first = write_delay <= read_delay;
        rd_id = 1;
        rd_base = A;
        rd_valid = 1'b1;
        wr_id = 2;
        wr_base = B;
        wr_data = pattern(32'hAB00_0000 + phase_offset);
        wr_valid = 1'b1;
        while (rd_accepts == old_reads && wr_accepts == old_writes) begin
            @(posedge cpu_clk);
            #1;
        end
        if (cpu_edges - offer_edge !=
            1 + ((read_delay < write_delay) ? read_delay : write_delay))
            $fatal(1, "primera concesion incorrecta fase=%0d", phase_offset);
        if (expect_write_first) begin
            if (wr_accepts != old_writes + 1 || rd_accepts != old_reads)
                $fatal(1, "escritura elegible no gano fase=%0d", phase_offset);
        end else if (rd_accepts != old_reads + 1 ||
                     wr_accepts != old_writes) begin
            $fatal(1, "lectura elegible no gano fase=%0d", phase_offset);
        end
        if (expect_write_first) wr_valid = 1'b0;
        else rd_valid = 1'b0;
        while (rd_accepts == old_reads || wr_accepts == old_writes) begin
            @(posedge cpu_clk);
            #1;
        end
        if (expect_write_first) rd_valid = 1'b0;
        else wr_valid = 1'b0;
        if (!(expect_write_first ? wr_rsp_valid : rd_rsp_valid))
            $fatal(1, "segundo burst adelanto fin del primero");
        wait (rd_rsp_valid && wr_rsp_valid);
        #1;
        if (rd_rsp_id !== 1 || rd_rsp_base !== A || rd_rsp_error ||
            wr_rsp_id !== 2 || wr_rsp_base !== B || wr_rsp_error ||
            read_word_event_mask !== '1 ||
            words_written != WORDS_PER_LINE)
            $fatal(1, "resultado o palabras de arbitraje incorrectos");
        consume_read();
        consume_write();
    endtask

    initial begin : checks
        integer old_reads;
        if (TEST_MODE == 5) begin
            for (integer phase = 0; phase < DIV; phase++)
                check_simultaneous_phase(phase);
            if (READ_ACCEPT_PHASE_TB == WRITE_ACCEPT_PHASE_TB) begin
                check_older_offer(1'b1);
                check_older_offer(1'b0);
            end
            if (event_read_words != physical_read_words ||
                event_write_words != physical_write_words)
                $fatal(1, "eventos de palabras perdidos en arbitraje");
            $display("PASS arbiter DIV=%0d READ_FIRST=%0d WRITE_FIRST=%0d",
                     DIV, READ_FIRST, WRITE_FIRST);
            $finish;
        end else if (TEST_MODE >= 1 && TEST_MODE <= 4) begin
            reset_controller();
            if (TEST_MODE == 3 || TEST_MODE == 4) begin
                send_write(2, B, pattern(32'h5555_0000));
                @(posedge wr_rsp_valid);
                #1;
                if (wr_rsp_id !== 2 || wr_rsp_base !== B || wr_rsp_error)
                    $fatal(1, "confirmacion previa incorrecta");
                @(posedge cpu_clk);
                #1;
                send_read(1, A);
            end else if (TEST_MODE == 1)
                send_read(1, A);
            else
                send_write(2, A, pattern(32'h5555_0000));
            timeout_word_events = 0;
            force dut.ram_clk_o = 1'b0;
            if (TEST_MODE == 4) begin
                repeat (8) begin
                    @(posedge cpu_clk);
                    #1;
                    if (rd_rsp_valid)
                        $fatal(1, "lectura congelada publico respuesta");
                end
                consume_write();
            end
            @(posedge perf_events.complete.valid);
            #1;
            if (perf_events.complete_error !== pkg_metrics::ERROR_TIMEOUT ||
                perf_events.complete.write !== (TEST_MODE == 2) ||
                perf_events.complete.id !== ((TEST_MODE == 2) ? 2 : 1) ||
                perf_events.complete.base !== A ||
                cpu_edges - ((TEST_MODE == 2)
                             ? wr_accept_edge : rd_accept_edge) != 44 ||
                rd_rsp_valid !== 1'b0 ||
                wr_rsp_valid !== (TEST_MODE == 3) ||
                timeout_word_events != 0)
                $fatal(1, "evento de timeout incorrecto");
            $display("TIMEOUT_EVENT_OK mode=%0d", TEST_MODE);
            // El controlador debe ejecutar $fatal en el siguiente flanco CPU.
        end else begin
        reset_controller();

        send_write(3, A, pattern(32'h1234_0000));
        expect_write(3, A, 1'b0);
        consume_write();
        send_read(2, A);
        expect_read(2, A, pattern(32'h1234_0000));
        consume_read();
        check_read_reservation();

        // Una lectura terminada puede esperar ready mientras RAM escribe B.
        send_read(1, A);
        expect_read(1, A, pattern(32'h1234_0000));
        send_write(2, B, pattern(32'hAAAA_0000));
        expect_write(2, B, 1'b0);
        if (rd_rsp_valid !== 1'b1 || rd_rsp_id !== 1 ||
            rd_rsp_data !== pattern(32'h1234_0000))
            $fatal(1, "escritura altero respuesta de lectura retenida");
        consume_write();
        consume_read();

        // El arbitraje por fase y antiguedad se prueba en TEST_MODE=5.
        // EB contiene una version mas reciente de A: lectura espera.
        old_reads = rd_accepts;
        @(negedge cpu_clk);
        eb_hit = 1'b1;
        rd_id = 3;
        rd_base = A;
        rd_valid = 1'b1;
        send_write(5, A, pattern(32'hCAFE_0000));
        expect_write(5, A, 1'b0);
        if (rd_accepts != old_reads)
            $fatal(1, "lectura RAW aceptada antes de drenar EB");
        consume_write();
        @(negedge cpu_clk);
        eb_hit = 1'b0;
        while (rd_accepts == old_reads) begin
            @(posedge cpu_clk);
            #1;
        end
        rd_valid = 1'b0;
        expect_read(3, A, pattern(32'hCAFE_0000));
        consume_read();

        // Las ultimas cuatro direcciones no pertenecen a los 64 KiB.
        send_write(6, END_BASE, pattern(32'hDEAD_0000));
        expect_write(6, END_BASE, 1'b1);
        consume_write();
        send_read(0, END_BASE);
        @(posedge rd_rsp_valid);
        #1;
        if (cpu_edges - rd_accept_edge != READ_TOTAL ||
            rd_rsp_error !== 1'b1 || rd_rsp_base !== END_BASE)
            $fatal(1, "lectura fuera de rango no reportada");
        for (integer i = 0; i < WORDS_PER_LINE; i++)
            if (rd_rsp_data[32 * i +: 32] !==
                ((i < 4) ? 32'hDEAD_0000 + i : 32'b0))
                $fatal(1, "dato de lectura fuera de rango incorrecto");
        consume_read();

        // Reset a mitad del burst cancela la respuesta sin borrar RAM.
        send_write(2, C, pattern(32'hABCD_0000));
        while (words_written < 3) begin
            @(posedge ram_clk);
            #1;
        end
        @(posedge cpu_clk);
        #1;
        reset_controller();
        repeat (WRITE_TOTAL + DIV) begin
            @(posedge cpu_clk);
            #1;
            if (wr_rsp_valid)
                $fatal(1, "respuesta de burst cancelado por reset");
        end
        send_write(7, D, pattern(32'hFEED_0000));
        expect_write(7, D, 1'b0);
        consume_write();
        send_read(0, D);
        expect_read(0, D, pattern(32'hFEED_0000));
        consume_read();

        // Reset descarta una confirmacion ya disponible; RAM conserva datos.
        send_write(0, B, pattern(32'h4444_0000));
        @(posedge wr_rsp_valid);
        #1;
        if (wr_rsp_id !== 0 || wr_rsp_error !== 1'b0)
            $fatal(1, "confirmacion previa al reset incorrecta");
        @(posedge cpu_clk);
        #1;
        reset_controller();
        repeat (WRITE_TOTAL + DIV) begin
            @(posedge cpu_clk);
            #1;
            if (wr_rsp_valid)
                $fatal(1, "confirmacion antigua reaparecio tras reset");
        end
        send_read(1, B);
        expect_read(1, B, pattern(32'h4444_0000));
        consume_read();

        // Reset interrumpe una lectura y descarta su resultado antiguo.
        send_read(0, A);
        while (read_words_in_burst < 3) begin
            @(posedge ram_clk);
            #1;
        end
        @(posedge cpu_clk);
        #1;
        reset_controller();
        repeat (READ_TOTAL + DIV) begin
            @(posedge cpu_clk);
            #1;
            if (rd_rsp_valid)
                $fatal(1, "respuesta de lectura cancelada por reset");
        end
        send_read(0, A);
        expect_read(0, A, pattern(32'hCAFE_0000));
        consume_read();

        // Reset tambien descarta una respuesta de lectura ya disponible.
        send_read(0, A);
        expect_read(0, A, pattern(32'hCAFE_0000));
        reset_controller();
        repeat (READ_TOTAL + DIV) begin
            @(posedge cpu_clk);
            #1;
            if (rd_rsp_valid)
                $fatal(1, "respuesta retenida reaparecio tras reset");
        end
        send_read(0, A);
        expect_read(0, A, pattern(32'hCAFE_0000));
        consume_read();

        // La RAM conserva datos tras reset; cada fase del divisor da 39 ciclos.
        for (integer phase = 0; phase < DIV; phase++) begin
            reset_controller();
            repeat (phase) @(posedge cpu_clk);
            send_read(1, A);
            expect_read(1, A, pattern(32'hCAFE_0000));
            consume_read();
        end
        check_protocol_error();

        if (event_read_accepts != rd_accepts ||
            event_write_accepts != wr_accepts ||
            event_read_words != physical_read_words - protocol_drop_count ||
            event_write_words != physical_write_words ||
            event_read_completes != event_read_consumes + 1 ||
            event_write_completes != event_write_consumes + 1 ||
            event_write_completes != wr_accepts - 1 ||
            event_read_completes != rd_accepts - 1)
            $fatal(1,
                "eventos de memoria: acepta R=%0d/%0d W=%0d/%0d palabras R=%0d/%0d W=%0d/%0d fin R=%0d/%0d W=%0d/%0d",
                event_read_accepts, rd_accepts,
                event_write_accepts, wr_accepts,
                event_read_words, physical_read_words,
                event_write_words, physical_write_words,
                event_read_completes, event_read_consumes,
                event_write_completes, event_write_consumes);

        $display("PASS tb_memory_controller_full DIV=%0d READ_FIRST=%0d WRITE_FIRST=%0d",
                 DIV, READ_FIRST, WRITE_FIRST);
        $finish;
        end
    end

    initial begin
        #500000;
        $fatal(1, "timeout del testbench general de memoria");
    end
endmodule
