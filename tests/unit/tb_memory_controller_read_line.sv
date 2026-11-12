/**
 * @brief Comprueba la respuesta completa de una lectura de linea.
 * @details RAM sincrona de prueba; verifica datos, latencia y retencion.
 * DIV permite repetir todas las fases con varios divisores de reloj.
 */
module tb_memory_controller_read_line;
    import pkg_memory::*;

    parameter integer DIV = 2;
    localparam integer TOTAL_CYCLES =
        MEM_READ_FIRST_WORD_CYCLES_DEFAULT + (WORDS_PER_LINE - 1) * DIV;

    logic cpu_clk = 1'b0;
    logic rst_n = 1'b1;
    logic req_valid = 1'b0;
    logic req_ready;
    logic rsp_valid;
    logic rsp_ready = 1'b0;
    logic [id_width(L2_MAX_INFLIGHT_DEFAULT)-1:0] rsp_id;
    address_t rsp_base;
    line_t rsp_data;
    logic rsp_error;
    logic ram_clk;
    logic ram_rst_n;
    address_t ram_address;
    logic ram_read_enable;
    byte_mask_t ram_write_enable;
    word_t ram_read_data = '0;
    logic ram_read_valid = 1'b0;
    logic inject_bad_word = 1'b0;
    logic bad_word;
    integer cpu_edges = 0;
    integer accepted_edge = -1;

    always #5 cpu_clk = ~cpu_clk;

    assign bad_word = inject_bad_word && ram_read_enable &&
        (ram_address == DATA_BASE_ADDRESS + 12);

    memory_controller #(.MEM_CLOCK_DIV(DIV)) dut (
        .clk_i(cpu_clk),
        .rst_ni(rst_n),
        .mem_rd_req_valid_i(req_valid),
        .mem_rd_req_ready_o(req_ready),
        .mem_rd_req_id_i(2'd2),
        .mem_rd_req_base_i(DATA_BASE_ADDRESS),
        .eb_probe_hit_i(1'b0),
        .mem_rd_rsp_valid_o(rsp_valid),
        .mem_rd_rsp_ready_i(rsp_ready),
        .mem_rd_rsp_id_o(rsp_id),
        .mem_rd_rsp_base_o(rsp_base),
        .mem_rd_rsp_data_o(rsp_data),
        .mem_rd_rsp_error_o(rsp_error),
        .mem_wr_req_valid_i(1'b0),
        .mem_wr_req_ready_o(),
        .mem_wr_req_id_i('0),
        .mem_wr_req_base_i('0),
        .mem_wr_req_data_i('0),
        .mem_wr_rsp_valid_o(),
        .mem_wr_rsp_ready_i(1'b0),
        .mem_wr_rsp_id_o(),
        .mem_wr_rsp_base_o(),
        .mem_wr_rsp_error_o(),
        .ram_clk_o(ram_clk),
        .ram_rst_no(ram_rst_n),
        .ram_address_o(ram_address),
        .ram_read_enable_o(ram_read_enable),
        .ram_write_enable_o(ram_write_enable),
        .ram_write_data_o(),
        .ram_read_data_i(ram_read_data),
        .ram_read_valid_i(ram_read_valid),
        .ram_out_of_range_i(bad_word),
        .perf_events_o()
    );

    always @(posedge cpu_clk) begin
        cpu_edges = cpu_edges + 1;
        if (req_valid && req_ready) accepted_edge = cpu_edges;
    end

    /** @brief Modelo del contrato de lectura sincrona de una palabra. */
    always_ff @(posedge ram_clk) begin
        if (!ram_rst_n) begin
            ram_read_data <= '0;
            ram_read_valid <= 1'b0;
        end else begin
            ram_read_valid <= ram_read_enable && !bad_word;
            if (ram_read_enable)
                ram_read_data <= 32'hA500_0000 +
                    ((ram_address - DATA_BASE_ADDRESS) >> 2);
        end
    end

    task automatic check_response;
        if (rsp_valid !== 1'b1 || rsp_error !== 1'b0 ||
            rsp_id !== 2'd2 || rsp_base !== DATA_BASE_ADDRESS)
            $fatal(1, "respuesta de lectura invalida");
        for (integer word_index = 0; word_index < WORDS_PER_LINE; word_index++)
            if (rsp_data[word_index * 32 +: 32] !==
                32'hA500_0000 + word_index)
                $fatal(1, "palabra %0d incorrecta", word_index);
    endtask

    task automatic run_case(input integer phase_wait);
        @(negedge cpu_clk);
        rst_n = 1'b0;
        req_valid = 1'b0;
        rsp_ready = 1'b0;
        inject_bad_word = 1'b0;
        accepted_edge = -1;
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
        repeat (phase_wait) @(posedge cpu_clk);
        @(negedge cpu_clk);
        req_valid = 1'b1;
        @(posedge cpu_clk);
        #1;
        req_valid = 1'b0;
        @(posedge rsp_valid);
        #1;
        if (cpu_edges - accepted_edge != TOTAL_CYCLES)
            $fatal(1, "respuesta fuera del ciclo esperado");
        check_response();
        repeat (3) begin
            @(posedge cpu_clk);
            #1;
            check_response();
        end
        @(negedge cpu_clk);
        rsp_ready = 1'b1;
        @(posedge cpu_clk);
        #1;
        if (rsp_valid !== 1'b0 || req_ready !== 1'b1)
            $fatal(1, "consumo de respuesta no libero el controlador");
        rsp_ready = 1'b0;
    endtask

    /** @brief Inicia una lectura despues de que RAM salio de reset. */
    task automatic start_read;
        accepted_edge = -1;
        @(negedge cpu_clk);
        req_valid = 1'b1;
        @(posedge cpu_clk);
        #1;
        req_valid = 1'b0;
        if (accepted_edge < 0) $fatal(1, "lectura no aceptada");
    endtask

    /** @brief Consume una respuesta que ya fue comprobada. */
    task automatic consume_response;
        @(negedge cpu_clk);
        rsp_ready = 1'b1;
        @(posedge cpu_clk);
        #1;
        if (rsp_valid !== 1'b0 || req_ready !== 1'b1)
            $fatal(1, "respuesta consumida no libero el controlador");
        rsp_ready = 1'b0;
    endtask

    /** @brief Reset interrumpe el burst y permite comenzar uno nuevo. */
    task automatic check_reset_during_burst;
        @(negedge cpu_clk);
        rst_n = 1'b0;
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
        start_read();
        @(posedge ram_read_enable);
        repeat (3) @(posedge ram_clk);
        @(negedge cpu_clk);
        rst_n = 1'b0;
        #1;
        if (rsp_valid !== 1'b0 || req_ready !== 1'b0)
            $fatal(1, "reset no cancelo el burst");
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
        repeat (TOTAL_CYCLES + DIV) begin
            @(posedge cpu_clk);
            #1;
            if (rsp_valid !== 1'b0)
                $fatal(1, "aparecio respuesta del burst cancelado");
        end
        start_read();
        @(posedge rsp_valid);
        #1;
        if (cpu_edges - accepted_edge != TOTAL_CYCLES)
            $fatal(1, "latencia incorrecta despues de reset");
        check_response();
        consume_response();
    endtask

    /** @brief Reset descarta una respuesta retenida. */
    task automatic check_reset_with_response;
        start_read();
        @(posedge rsp_valid);
        #1;
        check_response();
        @(negedge cpu_clk);
        rst_n = 1'b0;
        #1;
        if (rsp_valid !== 1'b0)
            $fatal(1, "reset no descarto la respuesta retenida");
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
        start_read();
        @(posedge rsp_valid);
        #1;
        check_response();
        consume_response();
    endtask

    /** @brief Una palabra invalida deja error y conserva las otras siete. */
    task automatic check_invalid_word;
        inject_bad_word = 1'b1;
        start_read();
        @(posedge rsp_valid);
        #1;
        if (cpu_edges - accepted_edge != TOTAL_CYCLES ||
            rsp_error !== 1'b1)
            $fatal(1, "error de RAM no publicado a tiempo");
        for (integer word_index = 0; word_index < WORDS_PER_LINE; word_index++)
            if (rsp_data[word_index * 32 +: 32] !==
                ((word_index == 3) ? 32'b0 : 32'hA500_0000 + word_index))
                $fatal(1, "palabra %0d incorrecta con error", word_index);
        inject_bad_word = 1'b0;
        consume_response();
    endtask

    initial begin
        for (integer phase = 0; phase < DIV; phase++) run_case(phase);
        check_reset_during_burst();
        check_reset_with_response();
        check_invalid_word();
        $display("PASS tb_memory_controller_read_line DIV=%0d", DIV);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "timeout esperando respuesta de linea");
    end
endmodule
