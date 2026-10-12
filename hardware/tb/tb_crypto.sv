`timescale 1ns/1ps

module tb_crypto;
    import pkg_vliw::*;

    word_t left_i;
    word_t right_i;
    word_t subkey_i;
    word_t left_o;
    word_t right_o;

    integer test_count;
    integer error_count;
    integer random_index;
    word_t random_left;
    word_t random_right;
    word_t random_subkey;

    feistel_round_logic u_dut (
        .left_i   (left_i),
        .right_i  (right_i),
        .subkey_i (subkey_i),
        .left_o   (left_o),
        .right_o  (right_o)
    );

    function automatic word_t rol32(
        input word_t value,
        input integer rotation
    );
        rol32 = (value << rotation) | (value >> (DATA_WIDTH - rotation));
    endfunction

    task automatic check_round(
        input word_t test_left,
        input word_t test_right,
        input word_t test_subkey,
        input string test_name
    );
        word_t expected_left;
        word_t expected_right;
        word_t expected_function;
        begin
            left_i = test_left;
            right_i = test_right;
            subkey_i = test_subkey;
            #1;

            expected_function = (rol32(test_right, 5) + test_subkey)
                                ^ rol32(test_right, 13);
            expected_left = test_right;
            expected_right = test_left ^ expected_function;
            test_count = test_count + 1;

            if ((left_o !== expected_left) || (right_o !== expected_right)) begin
                error_count = error_count + 1;
                $error("%s: L'=%08h expected=%08h, R'=%08h expected=%08h",
                       test_name, left_o, expected_left, right_o, expected_right);
            end
        end
    endtask

    initial begin
        test_count = 0;
        error_count = 0;
        left_i = '0;
        right_i = '0;
        subkey_i = '0;

        check_round(32'h0000_0000, 32'h0000_0000, 32'h0000_0000,
                    "all zeros");
        check_round(32'h0000_0000, 32'h0000_0000, 32'h1234_5678,
                    "subkey propagation");
        check_round(32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff,
                    "modular addition overflow");
        check_round(32'h0000_0000, 32'h8000_0000, 32'h0000_0000,
                    "rotation across bit 31");
        check_round(32'h0123_4567, 32'h89ab_cdef, 32'h0f1e_2d3c,
                    "asymmetric operands");
        check_round(32'hdead_beef, 32'h1357_9bdf, 32'hffff_fff0,
                    "carry truncation");

        for (random_index = 0; random_index < 100; random_index = random_index + 1) begin
            random_left = $urandom;
            random_right = $urandom;
            random_subkey = $urandom;
            check_round(random_left, random_right, random_subkey, "pseudorandom vector");
        end

        if (error_count == 0) begin
            $display("PASS: feistel_round_logic passed %0d checks", test_count);
            $finish;
        end

        $fatal(1, "FAIL: feistel_round_logic failed %0d of %0d checks",
               error_count, test_count);
    end

endmodule
