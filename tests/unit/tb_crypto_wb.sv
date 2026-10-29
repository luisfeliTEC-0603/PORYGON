`timescale 1ns/1ps

module tb_crypto_wb;
    import pkg_vliw::*;

    logic clk_i;
    logic rst_ni;
    logic [0:1] write_enable_i;
    logic auth_failed_i;
    logic access_error_i;
    logic [0:1][$clog2(NUM_REGS)-1:0] write_addr_i;
    logic [0:1][DATA_WIDTH-1:0] write_data_i;

    logic [0:1] write_enable_o;
    logic auth_failed_o;
    logic access_error_o;
    logic [0:1][$clog2(NUM_REGS)-1:0] write_addr_o;
    logic [0:1][DATA_WIDTH-1:0] write_data_o;

    integer test_count;
    integer error_count;

    crypto_wb u_dut (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .write_enable_i (write_enable_i),
        .auth_failed_i  (auth_failed_i),
        .access_error_i (access_error_i),
        .write_addr_i   (write_addr_i),
        .write_data_i   (write_data_i),
        .write_enable_o (write_enable_o),
        .auth_failed_o  (auth_failed_o),
        .access_error_o (access_error_o),
        .write_addr_o   (write_addr_o),
        .write_data_o   (write_data_o)
    );

    always #5 clk_i = ~clk_i;

    task automatic drive_inputs(
        input logic enable_0,
        input reg_index_t addr_0,
        input word_t data_0,
        input logic enable_1,
        input reg_index_t addr_1,
        input word_t data_1,
        input logic auth_failed,
        input logic access_error
    );
        begin
            write_enable_i[0] = enable_0;
            write_addr_i[0] = addr_0;
            write_data_i[0] = data_0;
            write_enable_i[1] = enable_1;
            write_addr_i[1] = addr_1;
            write_data_i[1] = data_1;
            auth_failed_i = auth_failed;
            access_error_i = access_error;
        end
    endtask

    task automatic expect_bit(
        input logic actual,
        input logic expected,
        input string test_name
    );
        begin
            test_count = test_count + 1;
            if (actual !== expected) begin
                error_count = error_count + 1;
                $error("%s: value=%b expected=%b", test_name, actual, expected);
            end
        end
    endtask

    task automatic expect_addr(
        input reg_index_t actual,
        input reg_index_t expected,
        input string test_name
    );
        begin
            test_count = test_count + 1;
            if (actual !== expected) begin
                error_count = error_count + 1;
                $error("%s: value=%0d expected=%0d", test_name, actual, expected);
            end
        end
    endtask

    task automatic expect_word(
        input word_t actual,
        input word_t expected,
        input string test_name
    );
        begin
            test_count = test_count + 1;
            if (actual !== expected) begin
                error_count = error_count + 1;
                $error("%s: value=%08h expected=%08h", test_name, actual, expected);
            end
        end
    endtask

    task automatic check_outputs(
        input logic expected_enable_0,
        input reg_index_t expected_addr_0,
        input word_t expected_data_0,
        input logic expected_enable_1,
        input reg_index_t expected_addr_1,
        input word_t expected_data_1,
        input logic expected_auth_failed,
        input logic expected_access_error,
        input string test_name
    );
        begin
            expect_bit(write_enable_o[0], expected_enable_0,
                       {test_name, " channel 0 enable"});
            expect_addr(write_addr_o[0], expected_addr_0,
                        {test_name, " channel 0 address"});
            expect_word(write_data_o[0], expected_data_0,
                        {test_name, " channel 0 data"});
            expect_bit(write_enable_o[1], expected_enable_1,
                       {test_name, " channel 1 enable"});
            expect_addr(write_addr_o[1], expected_addr_1,
                        {test_name, " channel 1 address"});
            expect_word(write_data_o[1], expected_data_1,
                        {test_name, " channel 1 data"});
            expect_bit(auth_failed_o, expected_auth_failed,
                       {test_name, " auth_failed"});
            expect_bit(access_error_o, expected_access_error,
                       {test_name, " access_error"});
        end
    endtask

    initial begin
        $dumpfile("build/waves/crypto_wb.vcd");
        $dumpvars(0, tb_crypto_wb);

        clk_i = 1'b0;
        rst_ni = 1'b0;
        test_count = 0;
        error_count = 0;
        drive_inputs(1'b1, 3'd6, 32'hffff_0001,
                     1'b1, 3'd7, 32'hffff_0002, 1'b1, 1'b1);

        @(posedge clk_i);
        #1;
        check_outputs(1'b0, '0, '0, 1'b0, '0, '0, 1'b0, 1'b0,
                      "initial synchronous reset and reset priority");

        @(negedge clk_i);
        rst_ni = 1'b1;
        drive_inputs(1'b1, 3'd1, 32'h1111_1111,
                     1'b1, 3'd2, 32'h2222_2222, 1'b0, 1'b0);
        #1;
        check_outputs(1'b0, '0, '0, 1'b0, '0, '0, 1'b0, 1'b0,
                      "two writes before capture");
        @(posedge clk_i);
        #1;
        check_outputs(1'b1, 3'd1, 32'h1111_1111,
                      1'b1, 3'd2, 32'h2222_2222, 1'b0, 1'b0,
                      "two simultaneous writes");

        @(negedge clk_i);
        drive_inputs(1'b1, 3'd3, 32'haaaa_0003,
                     1'b0, 3'd4, 32'hbbbb_0004, 1'b0, 1'b0);
        @(posedge clk_i);
        #1;
        check_outputs(1'b1, 3'd3, 32'haaaa_0003,
                      1'b0, 3'd4, 32'hbbbb_0004, 1'b0, 1'b0,
                      "only channel 0 active");

        @(negedge clk_i);
        drive_inputs(1'b0, 3'd5, 32'hcccc_0005,
                     1'b1, 3'd6, 32'hdddd_0006, 1'b0, 1'b0);
        @(posedge clk_i);
        #1;
        check_outputs(1'b0, 3'd5, 32'hcccc_0005,
                      1'b1, 3'd6, 32'hdddd_0006, 1'b0, 1'b0,
                      "only channel 1 active");

        @(negedge clk_i);
        drive_inputs(1'b0, 3'd7, 32'h7777_0007,
                     1'b0, 3'd1, 32'h1111_0001, 1'b0, 1'b0);
        @(posedge clk_i);
        #1;
        check_outputs(1'b0, 3'd7, 32'h7777_0007,
                      1'b0, 3'd1, 32'h1111_0001, 1'b0, 1'b0,
                      "both channels disabled after active cycles");

        @(negedge clk_i);
        drive_inputs(1'b0, 3'd2, 32'h1234_5678,
                     1'b0, 3'd4, 32'h8765_4321, 1'b1, 1'b1);
        #1;
        check_outputs(1'b0, 3'd7, 32'h7777_0007,
                      1'b0, 3'd1, 32'h1111_0001, 1'b0, 1'b0,
                      "event inputs before capture");
        @(posedge clk_i);
        #1;
        check_outputs(1'b0, 3'd2, 32'h1234_5678,
                      1'b0, 3'd4, 32'h8765_4321, 1'b1, 1'b1,
                      "registered event pulses");

        @(negedge clk_i);
        drive_inputs(1'b0, 3'd0, 32'h0000_0000,
                     1'b0, 3'd0, 32'h0000_0000, 1'b0, 1'b0);
        #1;
        check_outputs(1'b0, 3'd2, 32'h1234_5678,
                      1'b0, 3'd4, 32'h8765_4321, 1'b1, 1'b1,
                      "events held for exactly the registered cycle");
        @(posedge clk_i);
        #1;
        check_outputs(1'b0, '0, '0, 1'b0, '0, '0, 1'b0, 1'b0,
                      "events clear on next capture");

        @(negedge clk_i);
        drive_inputs(1'b1, 3'd1, 32'h0bad_f00d,
                     1'b1, 3'd2, 32'hcafe_babe, 1'b0, 1'b0);
        @(posedge clk_i);
        #1;
        check_outputs(1'b1, 3'd1, 32'h0bad_f00d,
                      1'b1, 3'd2, 32'hcafe_babe, 1'b0, 1'b0,
                      "first consecutive operation");
        @(negedge clk_i);
        drive_inputs(1'b1, 3'd5, 32'h1357_9bdf,
                     1'b1, 3'd6, 32'h2468_ace0, 1'b1, 1'b0);
        @(posedge clk_i);
        #1;
        check_outputs(1'b1, 3'd5, 32'h1357_9bdf,
                      1'b1, 3'd6, 32'h2468_ace0, 1'b1, 1'b0,
                      "second consecutive operation");

        @(negedge clk_i);
        rst_ni = 1'b0;
        drive_inputs(1'b1, 3'd7, 32'hffff_ffff,
                     1'b1, 3'd7, 32'heeee_eeee, 1'b1, 1'b1);
        #1;
        check_outputs(1'b1, 3'd5, 32'h1357_9bdf,
                      1'b1, 3'd6, 32'h2468_ace0, 1'b1, 1'b0,
                      "synchronous reset before edge");
        @(posedge clk_i);
        #1;
        check_outputs(1'b0, '0, '0, 1'b0, '0, '0, 1'b0, 1'b0,
                      "reset overrides active data and events");

        if (error_count == 0) begin
            $display("PASS: crypto_wb passed %0d checks", test_count);
            $finish;
        end

        $fatal(1, "FAIL: crypto_wb failed %0d checks of %0d",
               error_count, test_count);
    end

endmodule
