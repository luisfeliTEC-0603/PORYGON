/**
 * @brief Provoca un timeout deteniendo el reloj RAM.
 * @details La simulacion debe terminar con el fatal del controlador,
 * tipo de operacion, base DATA_BASE_ADDRESS y 45 ciclos transcurridos.
 */
module tb_memory_controller_timeout;
    import pkg_memory::*;
    parameter bit TEST_WRITE = 1'b1;

    logic cpu_clk = 1'b0;
    logic rst_n = 1'b1;
    logic wr_valid = 1'b0;
    logic wr_ready;
    logic rd_valid = 1'b0;
    logic rd_ready;
    logic wr_rsp_valid;
    logic ram_clk;
    logic ram_rst_n;
    pkg_metrics::mem_events_t perf;
    integer cpu_edges = 0;
    integer accepted_edge = -1;
    integer word_events = 0;

    always #5 cpu_clk = ~cpu_clk;

    memory_controller #(.MEM_TIMEOUT_CYCLES(45)) dut (
        .clk_i(cpu_clk), .rst_ni(rst_n),
        .mem_rd_req_valid_i(rd_valid), .mem_rd_req_ready_o(rd_ready),
        .mem_rd_req_id_i(2'd1), .mem_rd_req_base_i(DATA_BASE_ADDRESS),
        .eb_probe_hit_i(1'b0),
        .mem_rd_rsp_valid_o(), .mem_rd_rsp_ready_i(1'b0),
        .mem_rd_rsp_id_o(), .mem_rd_rsp_base_o(),
        .mem_rd_rsp_data_o(), .mem_rd_rsp_error_o(),
        .mem_wr_req_valid_i(wr_valid), .mem_wr_req_ready_o(wr_ready),
        .mem_wr_req_id_i(3'd2), .mem_wr_req_base_i(DATA_BASE_ADDRESS),
        .mem_wr_req_data_i('1), .mem_wr_rsp_valid_o(wr_rsp_valid),
        .mem_wr_rsp_ready_i(1'b0), .mem_wr_rsp_id_o(),
        .mem_wr_rsp_base_o(), .mem_wr_rsp_error_o(),
        .ram_clk_o(ram_clk), .ram_rst_no(ram_rst_n),
        .ram_address_o(), .ram_read_enable_o(),
        .ram_write_enable_o(), .ram_write_data_o(),
        .ram_read_data_i('0), .ram_read_valid_i(1'b0),
        .ram_out_of_range_i(1'b0), .perf_events_o(perf)
    );

    always @(posedge cpu_clk) begin
        cpu_edges = cpu_edges + 1;
        if ((wr_valid && wr_ready) || (rd_valid && rd_ready))
            accepted_edge = cpu_edges;
        if (perf.word.valid) word_events = word_events + 1;
    end

    initial begin
        #1 rst_n = 1'b0;
        @(negedge cpu_clk);
        rst_n = 1'b1;
        @(posedge ram_rst_n);
        @(negedge cpu_clk);
        if (TEST_WRITE) wr_valid = 1'b1;
        else rd_valid = 1'b1;
        while (accepted_edge < 0) begin
            @(posedge cpu_clk);
            #1;
        end
        wr_valid = 1'b0;
        rd_valid = 1'b0;
        force dut.ram_clk_o = 1'b0;
        @(posedge perf.complete.valid);
        #1;
        if (perf.complete_error !== pkg_metrics::ERROR_TIMEOUT ||
            perf.complete.write !== TEST_WRITE ||
            perf.complete.base !== DATA_BASE_ADDRESS ||
            cpu_edges - accepted_edge != 44 || wr_rsp_valid !== 1'b0 ||
            word_events != 0)
            $fatal(1, "evento de timeout incorrecto");
        $display("TIMEOUT_EVENT_OK write=%0d", TEST_WRITE);
    end

    initial begin
        #100000;
        $fatal(1,
            "el controlador no detecto timeout: age=%0d active=%b read_busy=%b words=%0d",
            dut.active_age_q, dut.transfer_active_q,
            dut.read_busy_q, dut.words_captured_q);
    end
endmodule
