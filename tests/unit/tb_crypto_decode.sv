`timescale 1ns/1ps

module tb_crypto_decode;
    import pkg_vliw::*;

    logic ex_valid_i;
    logic nop_flag_i;
    slot_t slot_i;

    logic ex_valid_o;
    logic [2:0] funct_o;
    logic [1:0] key_index_o;
    logic [1:0] subkey_index_o;
    logic [1:0] credential_word_index_o;

    integer test_count;
    integer error_count;
    integer funct_index;

    crypto_decode u_dut (
        .ex_valid_i                 (ex_valid_i),
        .nop_flag_i                 (nop_flag_i),
        .slot_i                     (slot_i),
        .ex_valid_o                 (ex_valid_o),
        .funct_o                    (funct_o),
        .key_index_o                (key_index_o),
        .subkey_index_o             (subkey_index_o),
        .credential_word_index_o    (credential_word_index_o)
    );

    function automatic slot_t make_slot(
        input logic [2:0] rs1,
        input logic [2:0] rs2,
        input logic [2:0] funct,
        input logic [1:0] shared_index,
        input logic [1:0] key_index,
        input logic reserved,
        input logic [1:0] opcode
    );
        make_slot = {rs1, rs2, funct, shared_index, key_index, reserved, opcode};
    endfunction

    task automatic check_decode(
        input logic test_ex_valid,
        input logic test_nop_flag,
        input slot_t test_slot,
        input logic expected_valid,
        input string test_name
    );
        begin
            ex_valid_i = test_ex_valid;
            nop_flag_i = test_nop_flag;
            slot_i = test_slot;
            #1;
            test_count = test_count + 1;

            if (ex_valid_o !== expected_valid) begin
                error_count = error_count + 1;
                $error("%s: valid=%b expected=%b", test_name,
                       ex_valid_o, expected_valid);
            end

            if ((funct_o !== test_slot[9:7])
                    || (subkey_index_o !== test_slot[6:5])
                    || (credential_word_index_o !== test_slot[6:5])
                    || (key_index_o !== test_slot[4:3])) begin
                error_count = error_count + 1;
                $error("%s: incorrect field extraction", test_name);
            end
        end
    endtask

    initial begin
        $dumpfile("build/waves/crypto_decode.vcd");
        $dumpvars(0, tb_crypto_decode);

        test_count = 0;
        error_count = 0;
        ex_valid_i = 1'b0;
        nop_flag_i = 1'b1;
        slot_i = '0;

        for (funct_index = 0; funct_index <= 5; funct_index = funct_index + 1) begin
            check_decode(
                1'b1,
                1'b0,
                make_slot(funct_index, 3'd7 - funct_index, funct_index,
                          funct_index, 2'd3 - funct_index, 1'b0, OPCODE_CRYPTO),
                1'b1,
                "defined CRYPTO function"
            );
        end

        check_decode(1'b0, 1'b0,
                     make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd2, 2'd1,
                               1'b0, OPCODE_CRYPTO),
                     1'b0, "inactive EX request");
        check_decode(1'b1, 1'b1,
                     make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd2, 2'd1,
                               1'b0, OPCODE_CRYPTO),
                     1'b0, "NOP from dispatch");
        check_decode(1'b1, 1'b0,
                     make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd2, 2'd1,
                               1'b0, OPCODE_MATH),
                     1'b0, "MATH opcode");
        check_decode(1'b1, 1'b0,
                     make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd2, 2'd1,
                               1'b0, OPCODE_LOST),
                     1'b0, "LOST opcode");
        check_decode(1'b1, 1'b0,
                     make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd2, 2'd1,
                               1'b0, OPCODE_JUMP),
                     1'b0, "JUMP opcode");
        check_decode(1'b1, 1'b0,
                     make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd2, 2'd1,
                               1'b1, OPCODE_CRYPTO),
                     1'b0, "reserved bit set");
        check_decode(1'b1, 1'b0,
                     make_slot(3'd1, 3'd2, 3'b110, 2'd2, 2'd1,
                               1'b0, OPCODE_CRYPTO),
                     1'b0, "undefined function 110");
        check_decode(1'b1, 1'b0,
                     make_slot(3'd1, 3'd2, 3'b111, 2'd2, 2'd1,
                               1'b0, OPCODE_CRYPTO),
                     1'b0, "undefined function 111");
        check_decode(1'b1, 1'b1, NOP_ENCODING, 1'b0, "encoded NOP");

        if (error_count == 0) begin
            $display("PASS: crypto_decode passed %0d checks", test_count);
            $finish;
        end

        $fatal(1, "FAIL: crypto_decode failed %0d checks of %0d",
               error_count, test_count);
    end

endmodule
