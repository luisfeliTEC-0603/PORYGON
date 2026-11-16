`timescale 1ns/1ps
/** @brief Finalizacion EX/WB/MUL, literales, r0, simultaneidad, stall y reset. */
module tb_bundle_completions;
    import pkg_vliw::*;
    import pkg_metrics::*;
    logic clk = 0, rst_n = 0, advance = 0, valid = 0, mul = 0;
    bundle_t bundle = '0;
    event_delta_t wb = 0;
    completion_delta_t done;
    logic wb_occupied, mul_occupied;
    always #5 clk = ~clk;
    bundle_completions dut (
        .clk_i(clk), .rst_ni(rst_n), .advance_i(advance), .ex_valid_i(valid),
        .ex_bundle_i(bundle), .wb_operations_i(wb), .mul_operation_i(mul),
        .done_o(done), .wb_occupied_o(wb_occupied), .mul_occupied_o(mul_occupied)
    );
    task automatic step(input logic enable, present, input bundle_t bits,
                        input event_delta_t wb_count, input logic multiply,
                        input completion_delta_t expected);
        @(negedge clk);
        advance = enable;
        valid = present;
        bundle = bits;
        wb = wb_count;
        mul = multiply;
        #1;
        if (done !== expected)
            $fatal(1, "Finalizaciones recibido=%h esperado=%h", done, expected);
        @(posedge clk);
        #1;
    endtask
    initial begin
        @(negedge clk);
        rst_n = 1;
        step(1, 1, 0, 0, 0, {8'd1, 8'd0, 8'd4, 8'd0});
        step(1, 1, 64'h0014, 1, 0, '0);
        step(0, 0, 0, 0, 0, '0);
        if (!wb_occupied) $fatal(1, "Stall perdio el WB de destino r0");
        step(1, 1, 0, 0, 0, {8'd2, 8'd1, 8'd6, 8'd1});
        step(1, 1, 64'h0000A410000320BC, 1, 1, '0);
        if (!wb_occupied || !mul_occupied) $fatal(1, "Falta ocupacion WB/MUL");
        step(0, 0, 0, 0, 0, '0);
        step(1, 1, 0, 0, 0, {8'd1, 8'd1, 8'd4, 8'd0});
        step(1, 0, 0, 0, 0, '0);
        step(1, 0, 0, 0, 0, {8'd1, 8'd1, 8'd1, 8'd1});
        step(1, 1, 64'h0000A41800042014, 2, 0, '0);
        step(1, 0, 0, 0, 0, {8'd1, 8'd2, 8'd1, 8'd1});
        step(1, 1, 64'h0000A410000320BC, 1, 1, '0);
        rst_n = 0;
        advance = 0;
        #1;
        if (done !== '0 || wb_occupied || mul_occupied) $fatal(1, "Reset no cancelo tags");
        @(negedge clk);
        rst_n = 1;
        repeat (3) step(1, 0, 0, 0, 0, '0);
        $display("tb_bundle_completions: PASS");
        $finish;
    end
endmodule
