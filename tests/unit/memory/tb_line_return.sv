`timescale 1ns/1ps

/** @brief Retorno sin registro obligatorio, exclusividad, retencion y reset. */
module tb_line_return;
    parameter integer N = 4;
    localparam integer ID_W = pkg_memory::id_width(N);
    logic clk = 0, rst_n = 0;
    logic wb_valid = 0, l2_valid = 0, mem_valid = 0, ready = 0;
    logic wb_ready, l2_ready, mem_ready, valid, dirty, error;
    pkg_memory::address_t base;
    pkg_memory::line_t data;
    pkg_memory::fill_source_t source;
    logic [ID_W-1:0] id;
    pkg_metrics::error_event_t diagnostic;
    integer errors = 0, deliveries = 0;
    always #5 clk = ~clk;

    line_return #(.L2_MAX_INFLIGHT(N)) dut (
        .clk_i(clk), .rst_ni(rst_n),
        .wb_fwd_valid_i(wb_valid), .wb_fwd_ready_o(wb_ready),
        .wb_fwd_base_i(32'h10000), .wb_fwd_data_i(256'h1234), .wb_fwd_dirty_i(1'b1),
        .l2_fill_valid_i(l2_valid), .l2_fill_ready_o(l2_ready),
        .l2_fill_id_i(ID_W'(N-1)), .l2_fill_base_i(32'h10020),
        .l2_fill_data_i(256'h5678), .l2_fill_dirty_i(1'b1), .l2_fill_error_i(1'b1),
        .mem_rd_rsp_valid_i(mem_valid), .mem_rd_rsp_ready_o(mem_ready),
        .mem_rd_rsp_id_i(ID_W'(N-1)), .mem_rd_rsp_base_i(32'h10040),
        .mem_rd_rsp_data_i(256'h9abc), .mem_rd_rsp_error_i(1'b0),
        .fill_valid_o(valid), .fill_ready_i(ready), .fill_base_o(base),
        .fill_data_o(data), .fill_dirty_o(dirty), .fill_error_o(error),
        .fill_source_o(source), .fill_id_o(id), .perf_error_o(diagnostic)
    );
    always @(posedge clk) if (rst_n) begin
        if (diagnostic.valid) errors++;
        if (valid && ready) deliveries++;
        if (int'(wb_valid && wb_ready) + int'(l2_valid && l2_ready) +
            int'(mem_valid && mem_ready) != int'(valid && ready))
            $fatal(1, "Entrega distinta del handshake de L1");
    end

    task automatic check(input integer origin);
        if (!valid || source != 2'(origin) ||
            base !== 32'h10000 + 32*origin ||
            data !== ((origin == 0) ? 256'h1234 : ((origin == 1) ? 256'h5678 : 256'h9abc)) ||
            dirty !== (origin != 2) || error !== (origin == 1) ||
            id !== ((origin == 0) ? ID_W'(0) : ID_W'(N-1)))
            $fatal(1, "Campos del retorno %0d incorrectos", origin);
        if ({mem_ready, l2_ready, wb_ready} !== (ready ? (3'b001 << origin) : 3'b000))
            $fatal(1, "Ready alcanzo otro origen");
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1;
        for (integer origin = 0; origin < 3; origin++) begin
            {mem_valid, l2_valid, wb_valid} = 3'b001 << origin;
            ready = 0;
            #1;
            check(origin);
            repeat (4) begin
                @(negedge clk);
                check(origin);
            end
            ready = 1;
            #1;
            check(origin);
            @(negedge clk);
            {mem_valid, l2_valid, wb_valid} = '0;
            #1;
            if (valid) $fatal(1, "Retorno duplicado");
            /** La proxima oferta tambien debe poder consumirse sin registrarla. */
            {mem_valid, l2_valid, wb_valid} = 3'b001 << origin;
            #1;
            check(origin);
            @(negedge clk);
            {mem_valid, l2_valid, wb_valid} = '0;
        end
        /** Una oferta ajena no cambia la seleccion ya retenida. */
        ready = 0;
        l2_valid = 1;
        @(negedge clk);
        mem_valid = 1;
        repeat (3) begin
            @(negedge clk);
            check(1);
        end
        ready = 1;
        #1;
        check(1);
        @(negedge clk);
        l2_valid = 0;
        mem_valid = 0;
        @(negedge clk);
        wb_valid = 1;
        mem_valid = 1;
        repeat (3) begin
            @(negedge clk);
            if (valid || wb_ready || l2_ready || mem_ready)
                $fatal(1, "Se acepto una oferta ambigua");
        end
        if (errors != 2 || deliveries != 7) $fatal(1, "Diagnosticos o entregas repetidos");
        mem_valid = 0;
        ready = 0;
        @(negedge clk);
        rst_n = 0;
        #1;
        if (valid || wb_ready || l2_ready || mem_ready || diagnostic.valid)
            $fatal(1, "Transferencia durante reset");
        wb_valid = 0;
        @(negedge clk);
        rst_n = 1;
        #1;
        if (valid) $fatal(1, "Retorno anterior a reset");
        $display("PASS tb_line_return N=%0d: tres origenes, bloqueo, error y reset", N);
        $finish;
    end
    initial begin
        #5000;
        $fatal(1, "Timeout tb_line_return");
    end
endmodule
