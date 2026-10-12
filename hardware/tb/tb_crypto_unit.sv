`timescale 1ns/1ps

module tb_crypto_unit;
    import pkg_vliw::*;

    localparam logic [127:0] INITIAL_PASSWORD =
        128'h1463_17bb_da48_db07_a9a6_7018_dff0_f76a;
    localparam logic [127:0] NEW_PASSWORD =
        128'hcafe_babe_1357_9bdf_2468_ace0_dead_beef;
    localparam word_t TEST_SUBKEY = 32'h0f1e_2d3c;

    logic clk_i;
    logic rst_ni;
    logic ex_valid_i;
    logic nop_flag_i;
    slot_t slot_i;
    reg_index_t op_a_addr_i;
    reg_index_t op_b_addr_i;
    word_t op_a_data_i;
    word_t op_b_data_i;

    logic write_enable_o [0:1];
    reg_index_t write_addr_o [0:1];
    word_t write_data_o [0:1];
    logic authenticated_o;
    logic auth_failed_o;
    logic access_error_o;

    integer test_count;
    integer error_count;
    integer idle_index;
    word_t key_material [0:3][0:3];

    crypto_unit u_dut (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .ex_valid_i     (ex_valid_i),
        .nop_flag_i     (nop_flag_i),
        .slot_i         (slot_i),
        .op_a_addr_i    (op_a_addr_i),
        .op_b_addr_i    (op_b_addr_i),
        .op_a_data_i    (op_a_data_i),
        .op_b_data_i    (op_b_data_i),
        .write_enable_o (write_enable_o),
        .write_addr_o   (write_addr_o),
        .write_data_o   (write_data_o),
        .authenticated_o(authenticated_o),
        .auth_failed_o  (auth_failed_o),
        .access_error_o (access_error_o)
    );

    always #5 clk_i = ~clk_i;

    function automatic slot_t make_slot(
        input logic [2:0] rs1,
        input logic [2:0] rs2,
        input logic [2:0] funct,
        input logic [1:0] shared_index,
        input logic [1:0] key_index,
        input logic reserved,
        input logic [1:0] opcode
    );
        make_slot = {rs1, rs2, funct, shared_index, key_index,
                     reserved, opcode};
    endfunction

    function automatic word_t rol32(
        input word_t value,
        input integer rotation
    );
        rol32 = (value << rotation) | (value >> (DATA_WIDTH - rotation));
    endfunction

    function automatic word_t expected_right(
        input word_t left,
        input word_t right,
        input word_t subkey
    );
        word_t round_function;
        begin
            round_function = (rol32(right, 5) + subkey) ^ rol32(right, 13);
            expected_right = left ^ round_function;
        end
    endfunction

    function automatic word_t reference_round_function(
        input word_t value,
        input word_t subkey
    );
        word_t modular_sum;
        begin
            modular_sum = rol32(value, 5) + subkey;
            reference_round_function = modular_sum ^ rol32(value, 13);
        end
    endfunction

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

    task automatic expect_control(
        input logic expected_enable_0,
        input logic expected_enable_1,
        input logic expected_auth_failed,
        input logic expected_access_error,
        input string test_name
    );
        begin
            expect_bit(write_enable_o[0], expected_enable_0,
                       {test_name, " channel 0 enable"});
            expect_bit(write_enable_o[1], expected_enable_1,
                       {test_name, " channel 1 enable"});
            expect_bit(auth_failed_o, expected_auth_failed,
                       {test_name, " auth_failed"});
            expect_bit(access_error_o, expected_access_error,
                       {test_name, " access_error"});
        end
    endtask

    task automatic expect_feistel_result(
        input logic expected_enable_0,
        input reg_index_t expected_addr_0,
        input word_t expected_data_0,
        input logic expected_enable_1,
        input reg_index_t expected_addr_1,
        input word_t expected_data_1,
        input string test_name
    );
        begin
            expect_control(expected_enable_0, expected_enable_1,
                           1'b0, 1'b0, test_name);
            expect_addr(write_addr_o[0], expected_addr_0,
                        {test_name, " channel 0 address"});
            expect_word(write_data_o[0], expected_data_0,
                        {test_name, " channel 0 data"});
            expect_addr(write_addr_o[1], expected_addr_1,
                        {test_name, " channel 1 address"});
            expect_word(write_data_o[1], expected_data_1,
                        {test_name, " channel 1 data"});
        end
    endtask

    task automatic drive_request(
        input logic request_valid,
        input logic request_nop,
        input slot_t request_slot,
        input reg_index_t addr_a,
        input word_t data_a,
        input reg_index_t addr_b,
        input word_t data_b
    );
        begin
            ex_valid_i = request_valid;
            nop_flag_i = request_nop;
            slot_i = request_slot;
            op_a_addr_i = addr_a;
            op_a_data_i = data_a;
            op_b_addr_i = addr_b;
            op_b_data_i = data_b;
        end
    endtask

    task automatic execute_crypto(
        input logic [2:0] funct,
        input logic [1:0] shared_index,
        input logic [1:0] key_index,
        input reg_index_t addr_a,
        input word_t data_a,
        input reg_index_t addr_b,
        input word_t data_b
    );
        begin
            @(negedge clk_i);
            drive_request(
                1'b1,
                1'b0,
                make_slot(addr_a, addr_b, funct, shared_index,
                          key_index, 1'b0, OPCODE_CRYPTO),
                addr_a,
                data_a,
                addr_b,
                data_b
            );
            @(posedge clk_i);
            #1;
        end
    endtask

    task automatic idle_cycle;
        begin
            @(negedge clk_i);
            drive_request(1'b0, 1'b1, NOP_ENCODING,
                          '0, '0, '0, '0);
            @(posedge clk_i);
            #1;
        end
    endtask

    task automatic load_credential(input logic [127:0] credential);
        begin
            execute_crypto(CRYPTO_LOPW, 2'd0, '0,
                           3'd1, credential[31:0], '0, '0);
            expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                           "LOPW credential word 0");
            execute_crypto(CRYPTO_LOPW, 2'd1, '0,
                           3'd1, credential[63:32], '0, '0);
            expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                           "LOPW credential word 1");
            execute_crypto(CRYPTO_LOPW, 2'd2, '0,
                           3'd1, credential[95:64], '0, '0);
            expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                           "LOPW credential word 2");
            execute_crypto(CRYPTO_LOPW, 2'd3, '0,
                           3'd1, credential[127:96], '0, '0);
            expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                           "LOPW credential word 3");
        end
    endtask

    task automatic authenticate(
        input logic [127:0] credential,
        input logic expected_success,
        input string test_name
    );
        begin
            load_credential(credential);
            execute_crypto(CRYPTO_AUTH, '0, '0, '0, '0, '0, '0);
            expect_control(1'b0, 1'b0, !expected_success, 1'b0,
                           test_name);
            expect_bit(authenticated_o, expected_success,
                       {test_name, " authenticated state"});
        end
    endtask

    task automatic program_all_keys;
        integer key_number;
        integer subkey_number;
        begin
            for (key_number = 0; key_number < 4;
                 key_number = key_number + 1) begin
                for (subkey_number = 0; subkey_number < 4;
                     subkey_number = subkey_number + 1) begin
                    execute_crypto(CRYPTO_WRITE, subkey_number[1:0],
                                   key_number[1:0], 3'd1,
                                   key_material[key_number][subkey_number],
                                   '0, '0);
                    expect_control(
                        1'b0, 1'b0, 1'b0, 1'b0,
                        $sformatf("program key %0d subkey %0d",
                                  key_number, subkey_number)
                    );
                end
            end
        end
    endtask

    task automatic check_full_cipher(
        input integer key_number,
        input word_t original_left,
        input word_t original_right,
        input string test_name
    );
        integer round_number;
        word_t dut_left;
        word_t dut_right;
        word_t model_left;
        word_t model_right;
        word_t next_left;
        word_t next_right;
        word_t encrypted_left;
        word_t encrypted_right;
        begin
            dut_left = original_left;
            dut_right = original_right;
            model_left = original_left;
            model_right = original_right;

            for (round_number = 0; round_number < 4;
                 round_number = round_number + 1) begin
                next_left = model_right;
                next_right = model_left
                           ^ reference_round_function(
                                 model_right,
                                 key_material[key_number][round_number]
                             );

                execute_crypto(CRYPTO_FEISTEL, round_number[1:0],
                               key_number[1:0], 3'd1, dut_left,
                               3'd2, dut_right);
                expect_feistel_result(
                    1'b1, 3'd1, next_left,
                    1'b1, 3'd2, next_right,
                    $sformatf("%s encrypt round %0d",
                              test_name, round_number)
                );

                // Solo las salidas ya capturadas por EX/WB alimentan la ronda siguiente.
                dut_left = write_data_o[0];
                dut_right = write_data_o[1];
                model_left = next_left;
                model_right = next_right;
            end

            encrypted_left = model_left;
            encrypted_right = model_right;
            expect_word(dut_left, encrypted_left,
                        {test_name, " encrypted left"});
            expect_word(dut_right, encrypted_right,
                        {test_name, " encrypted right"});

            for (round_number = 3; round_number >= 0;
                 round_number = round_number - 1) begin
                next_left = model_right
                          ^ reference_round_function(
                                model_left,
                                key_material[key_number][round_number]
                            );
                next_right = model_left;

                // El inverso usa R como operando A y L como operando B.
                execute_crypto(CRYPTO_FEISTEL, round_number[1:0],
                               key_number[1:0], 3'd2, dut_right,
                               3'd1, dut_left);
                expect_feistel_result(
                    1'b1, 3'd2, next_right,
                    1'b1, 3'd1, next_left,
                    $sformatf("%s decrypt round %0d",
                              test_name, round_number)
                );

                dut_right = write_data_o[0];
                dut_left = write_data_o[1];
                model_left = next_left;
                model_right = next_right;
            end

            expect_word(dut_left, original_left,
                        {test_name, " recovered left"});
            expect_word(dut_right, original_right,
                        {test_name, " recovered right"});
            expect_word(model_left, original_left,
                        {test_name, " reference recovered left"});
            expect_word(model_right, original_right,
                        {test_name, " reference recovered right"});
        end
    endtask

    initial begin
        $dumpfile("build/waves/crypto_unit.vcd");
        $dumpvars(0, tb_crypto_unit);

        clk_i = 1'b0;
        rst_ni = 1'b0;
        test_count = 0;
        error_count = 0;
        key_material[0][0] = 32'h0000_0000;
        key_material[0][1] = 32'h0000_0000;
        key_material[0][2] = 32'h0000_0000;
        key_material[0][3] = 32'h0000_0000;
        key_material[1][0] = 32'h0000_0001;
        key_material[1][1] = 32'h0000_0001;
        key_material[1][2] = 32'h0000_0001;
        key_material[1][3] = 32'h0000_0001;
        key_material[2][0] = 32'h0011_2233;
        key_material[2][1] = 32'h4455_6677;
        key_material[2][2] = 32'h8899_aabb;
        key_material[2][3] = 32'hccdd_eeff;
        key_material[3][0] = 32'hffff_ffff;
        key_material[3][1] = 32'hffff_fff0;
        key_material[3][2] = 32'h8000_0000;
        key_material[3][3] = 32'h7fff_ffff;
        drive_request(
            1'b1,
            1'b0,
            make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd0,
                      2'd0, 1'b0, OPCODE_CRYPTO),
            3'd1,
            32'h1111_1111,
            3'd2,
            32'h2222_2222
        );

        @(posedge clk_i);
        #1;
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "reset clears WB control");
        expect_addr(write_addr_o[0], '0, "reset clears channel 0 address");
        expect_addr(write_addr_o[1], '0, "reset clears channel 1 address");
        expect_word(write_data_o[0], '0, "reset clears channel 0 data");
        expect_word(write_data_o[1], '0, "reset clears channel 1 data");
        expect_bit(authenticated_o, 1'b0, "reset locks vault");

        @(negedge clk_i);
        rst_ni = 1'b1;
        drive_request(1'b1, 1'b1,
                      make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd0,
                                2'd0, 1'b0, OPCODE_CRYPTO),
                      3'd1, 32'h1111_1111, 3'd2, 32'h2222_2222);
        @(posedge clk_i);
        #1;
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "NOP flag rejects request");

        @(negedge clk_i);
        drive_request(1'b1, 1'b0,
                      make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd0,
                                2'd0, 1'b0, OPCODE_MATH),
                      3'd1, 32'h1111_1111, 3'd2, 32'h2222_2222);
        @(posedge clk_i);
        #1;
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "non-CRYPTO opcode rejected");

        @(negedge clk_i);
        drive_request(1'b1, 1'b0,
                      make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd0,
                                2'd0, 1'b1, OPCODE_CRYPTO),
                      3'd1, 32'h1111_1111, 3'd2, 32'h2222_2222);
        @(posedge clk_i);
        #1;
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "reserved bit rejects request");

        execute_crypto(CRYPTO_FEISTEL, 2'd0, 2'd0,
                       3'd1, 32'h0123_4567, 3'd2, 32'h89ab_cdef);
        expect_control(1'b0, 1'b0, 1'b0, 1'b1,
                       "locked Feistel reports registered access error");
        expect_bit(authenticated_o, 1'b0,
                   "locked Feistel preserves locked state");

        idle_cycle();
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "registered access error clears next cycle");

        execute_crypto(CRYPTO_AUTH, '0, '0, '0, '0, '0, '0);
        expect_control(1'b0, 1'b0, 1'b1, 1'b0,
                       "incomplete auth reports registered failure");
        expect_bit(authenticated_o, 1'b0,
                   "incomplete auth remains locked");

        idle_cycle();
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "registered auth failure clears next cycle");

        authenticate(INITIAL_PASSWORD, 1'b1,
                     "initial password authenticates");

        execute_crypto(CRYPTO_WRITE, 2'd3, 2'd2,
                       3'd1, TEST_SUBKEY, '0, '0);
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "authorized key write has no GPR result");
        expect_bit(authenticated_o, 1'b1,
                   "authorized key write preserves authentication");

        @(negedge clk_i);
        drive_request(
            1'b1,
            1'b0,
            make_slot(3'd3, 3'd4, CRYPTO_FEISTEL, 2'd3,
                      2'd2, 1'b0, OPCODE_CRYPTO),
            3'd3,
            32'h0123_4567,
            3'd4,
            32'h89ab_cdef
        );
        #1;
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "Feistel result not visible before EX/WB edge");
        @(posedge clk_i);
        #1;
        expect_feistel_result(
            1'b1,
            3'd3,
            32'h89ab_cdef,
            1'b1,
            3'd4,
            expected_right(32'h0123_4567, 32'h89ab_cdef, TEST_SUBKEY),
            "authorized Feistel result"
        );

        @(negedge clk_i);
        drive_request(
            1'b1,
            1'b0,
            make_slot(3'd0, 3'd5, CRYPTO_FEISTEL, 2'd3,
                      2'd2, 1'b0, OPCODE_CRYPTO),
            3'd0,
            32'haaaa_5555,
            3'd5,
            32'h1357_9bdf
        );
        #1;
        expect_feistel_result(
            1'b1,
            3'd3,
            32'h89ab_cdef,
            1'b1,
            3'd4,
            expected_right(32'h0123_4567, 32'h89ab_cdef, TEST_SUBKEY),
            "previous Feistel held until next edge"
        );
        @(posedge clk_i);
        #1;
        expect_feistel_result(
            1'b0,
            3'd0,
            32'h1357_9bdf,
            1'b1,
            3'd5,
            expected_right(32'haaaa_5555, 32'h1357_9bdf, TEST_SUBKEY),
            "r0 suppresses only channel 0"
        );

        execute_crypto(CRYPTO_FEISTEL, 2'd3, 2'd2,
                       3'd6, 32'hdead_beef, 3'd0, 32'h2468_ace0);
        expect_feistel_result(
            1'b1,
            3'd6,
            32'h2468_ace0,
            1'b0,
            3'd0,
            expected_right(32'hdead_beef, 32'h2468_ace0, TEST_SUBKEY),
            "r0 suppresses only channel 1"
        );

        execute_crypto(CRYPTO_FEISTEL, 2'd3, 2'd2,
                       3'd7, 32'h1111_2222, 3'd7, 32'h3333_4444);
        expect_feistel_result(
            1'b1,
            3'd7,
            32'h3333_4444,
            1'b1,
            3'd7,
            expected_right(32'h1111_2222, 32'h3333_4444, TEST_SUBKEY),
            "equal destinations propagate both channels"
        );

        program_all_keys();
        check_full_cipher(0, 32'h0000_0000, 32'h0000_0000,
                          "key 0 zero block");
        check_full_cipher(1, 32'h0000_0001, 32'h0000_0001,
                          "key 1 one block");
        check_full_cipher(2, 32'h0123_4567, 32'h89ab_cdef,
                          "key 2 asymmetric block");
        check_full_cipher(3, 32'hffff_ffff, 32'hffff_fffe,
                          "key 3 overflow block");

        execute_crypto(CRYPTO_RVK, '0, '0, '0, '0, '0, '0);
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "rvk has no GPR result");
        expect_bit(authenticated_o, 1'b0, "rvk revokes authentication");

        execute_crypto(CRYPTO_WRITE, 2'd3, 2'd2,
                       3'd1, 32'hffff_ffff, '0, '0);
        expect_control(1'b0, 1'b0, 1'b0, 1'b1,
                       "locked key write reports access error");

        authenticate(INITIAL_PASSWORD, 1'b1,
                     "reauthentication before password change");
        load_credential(NEW_PASSWORD);
        execute_crypto(CRYPTO_PWD, '0, '0, '0, '0, '0, '0);
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "complete password change accepted");
        expect_bit(authenticated_o, 1'b0,
                   "password change revokes authentication");

        authenticate(INITIAL_PASSWORD, 1'b0,
                     "old password rejected after change");
        authenticate(NEW_PASSWORD, 1'b1,
                     "new password authenticates");

        for (idle_index = 0; idle_index < 15; idle_index = idle_index + 1) begin
            idle_cycle();
        end
        expect_bit(authenticated_o, 1'b1,
                   "authentication remains before timeout");
        idle_cycle();
        expect_bit(authenticated_o, 1'b0,
                   "timeout propagates persistent locked state");

        authenticate(NEW_PASSWORD, 1'b1,
                     "reauthentication before reset priority test");
        @(negedge clk_i);
        rst_ni = 1'b0;
        drive_request(
            1'b1,
            1'b0,
            make_slot(3'd1, 3'd2, CRYPTO_FEISTEL, 2'd3,
                      2'd2, 1'b0, OPCODE_CRYPTO),
            3'd1,
            32'hffff_0001,
            3'd2,
            32'hffff_0002
        );
        @(posedge clk_i);
        #1;
        expect_control(1'b0, 1'b0, 1'b0, 1'b0,
                       "reset overrides active Feistel and events");
        expect_addr(write_addr_o[0], '0,
                    "reset priority clears channel 0 address");
        expect_addr(write_addr_o[1], '0,
                    "reset priority clears channel 1 address");
        expect_word(write_data_o[0], '0,
                    "reset priority clears channel 0 data");
        expect_word(write_data_o[1], '0,
                    "reset priority clears channel 1 data");
        expect_bit(authenticated_o, 1'b0,
                   "reset priority locks vault");

        @(negedge clk_i);
        rst_ni = 1'b1;
        drive_request(1'b0, 1'b1, NOP_ENCODING, '0, '0, '0, '0);
        @(posedge clk_i);
        #1;
        authenticate(INITIAL_PASSWORD, 1'b1,
                     "reset restores initial password");
        execute_crypto(CRYPTO_FEISTEL, 2'd3, 2'd2,
                       3'd1, 32'h0123_4567, 3'd2, 32'h89ab_cdef);
        expect_feistel_result(
            1'b1,
            3'd1,
            32'h89ab_cdef,
            1'b1,
            3'd2,
            expected_right(32'h0123_4567, 32'h89ab_cdef, 32'h0000_0000),
            "reset clears programmed subkey"
        );

        if (error_count == 0) begin
            $display("PASS: crypto_unit passed %0d checks", test_count);
            $finish;
        end

        $fatal(1, "FAIL: crypto_unit failed %0d checks of %0d",
               error_count, test_count);
    end

endmodule
