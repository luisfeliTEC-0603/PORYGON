`timescale 1ns/1ps

module tb_key_vault;
    import pkg_vliw::*;

    localparam logic [127:0] TEST_PASSWORD =
        128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210;
    localparam logic [127:0] NEW_PASSWORD =
        128'hcafe_babe_1357_9bdf_2468_ace0_dead_beef;
    localparam integer TEST_TIMEOUT_CYCLES = 4;

    logic clk_i;
    logic rst_ni;
    logic ex_valid_i;
    logic [2:0] funct_i;
    logic [1:0] key_index_i;
    logic [1:0] subkey_index_i;
    logic [1:0] credential_word_index_i;
    word_t op_a_data_i;

    logic feistel_commit_o;
    word_t subkey_o;
    logic authenticated_o;
    logic auth_failed_o;
    logic access_error_o;

    integer test_count;
    integer error_count;
    integer key_number;
    integer subkey_number;
    word_t expected_subkey;

    key_vault #(
        .INITIAL_PASSWORD    (TEST_PASSWORD),
        .AUTH_TIMEOUT_CYCLES (TEST_TIMEOUT_CYCLES)
    ) u_dut (
        .clk_i                       (clk_i),
        .rst_ni                      (rst_ni),
        .ex_valid_i                  (ex_valid_i),
        .funct_i                     (funct_i),
        .key_index_i                 (key_index_i),
        .subkey_index_i              (subkey_index_i),
        .credential_word_index_i     (credential_word_index_i),
        .op_a_data_i                 (op_a_data_i),
        .feistel_commit_o            (feistel_commit_o),
        .subkey_o                    (subkey_o),
        .authenticated_o             (authenticated_o),
        .auth_failed_o               (auth_failed_o),
        .access_error_o              (access_error_o)
    );

    always #5 clk_i = ~clk_i;

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

    task automatic prepare_operation(
        input logic [2:0] funct,
        input logic [1:0] key_index,
        input logic [1:0] subkey_index,
        input logic [1:0] word_index,
        input word_t data
    );
        begin
            @(negedge clk_i);
            ex_valid_i = 1'b1;
            funct_i = funct;
            key_index_i = key_index;
            subkey_index_i = subkey_index;
            credential_word_index_i = word_index;
            op_a_data_i = data;
            #1;
        end
    endtask

    task automatic commit_operation;
        begin
            @(posedge clk_i);
            #1;
            ex_valid_i = 1'b0;
            funct_i = CRYPTO_AUTH;
            key_index_i = '0;
            subkey_index_i = '0;
            credential_word_index_i = '0;
            op_a_data_i = '0;
            #1;
        end
    endtask

    task automatic load_credential(input logic [127:0] credential);
        begin
            prepare_operation(CRYPTO_LOPW, '0, '0, 2'd0, credential[31:0]);
            expect_bit(access_error_o, 1'b0, "LOPW word 0 accepted");
            commit_operation();
            prepare_operation(CRYPTO_LOPW, '0, '0, 2'd1, credential[63:32]);
            commit_operation();
            prepare_operation(CRYPTO_LOPW, '0, '0, 2'd2, credential[95:64]);
            commit_operation();
            prepare_operation(CRYPTO_LOPW, '0, '0, 2'd3, credential[127:96]);
            commit_operation();
        end
    endtask

    task automatic authenticate(
        input logic [127:0] credential,
        input logic expected_success,
        input string test_name
    );
        begin
            load_credential(credential);
            prepare_operation(CRYPTO_AUTH, '0, '0, '0, '0);
            expect_bit(auth_failed_o, !expected_success, test_name);
            commit_operation();
            expect_bit(authenticated_o, expected_success, test_name);
        end
    endtask

    task automatic idle_cycles(input integer cycles);
        integer cycle;
        begin
            @(negedge clk_i);
            ex_valid_i = 1'b0;
            for (cycle = 0; cycle < cycles; cycle = cycle + 1) begin
                @(posedge clk_i);
                #1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/waves/key_vault.vcd");
        $dumpvars(0, tb_key_vault);

        clk_i = 1'b0;
        rst_ni = 1'b0;
        ex_valid_i = 1'b0;
        funct_i = CRYPTO_AUTH;
        key_index_i = '0;
        subkey_index_i = '0;
        credential_word_index_i = '0;
        op_a_data_i = '0;
        test_count = 0;
        error_count = 0;

        repeat (2) @(posedge clk_i);
        #1;
        expect_bit(authenticated_o, 1'b0, "reset starts locked");
        expect_word(subkey_o, '0, "reset hides subkeys");
        @(negedge clk_i);
        rst_ni = 1'b1;

        prepare_operation(CRYPTO_FEISTEL, 2'd0, 2'd0, '0, '0);
        expect_bit(feistel_commit_o, 1'b0, "locked Feistel rejected");
        expect_word(subkey_o, '0, "locked Feistel hides key");
        expect_bit(access_error_o, 1'b1, "locked Feistel reports error");
        commit_operation();

        prepare_operation(CRYPTO_WRITE, 2'd0, 2'd0, '0, 32'hffff_ffff);
        expect_bit(access_error_o, 1'b1, "locked write reports error");
        commit_operation();

        prepare_operation(CRYPTO_PWD, '0, '0, '0, '0);
        expect_bit(access_error_o, 1'b1, "locked password change reports error");
        commit_operation();

        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd0, TEST_PASSWORD[31:0]);
        commit_operation();
        prepare_operation(CRYPTO_AUTH, '0, '0, '0, '0);
        expect_bit(auth_failed_o, 1'b1, "incomplete credential fails");
        commit_operation();
        expect_bit(authenticated_o, 1'b0, "incomplete credential remains locked");

        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd1, TEST_PASSWORD[63:32]);
        commit_operation();
        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd2, TEST_PASSWORD[95:64]);
        commit_operation();
        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd3, TEST_PASSWORD[127:96]);
        commit_operation();
        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd0, TEST_PASSWORD[31:0]);
        commit_operation();
        prepare_operation(CRYPTO_AUTH, '0, '0, '0, '0);
        expect_bit(auth_failed_o, 1'b1,
                   "LOPW word 0 restarts credential assembly");
        commit_operation();

        authenticate(TEST_PASSWORD, 1'b1, "initial password authenticates");
        prepare_operation(CRYPTO_AUTH, '0, '0, '0, '0);
        expect_bit(auth_failed_o, 1'b1, "auth consumes credential buffer");
        commit_operation();
        expect_bit(authenticated_o, 1'b0,
                   "auth without a new credential revokes session");
        authenticate(TEST_PASSWORD, 1'b1,
                     "reauthentication after consumed credential");

        for (key_number = 0; key_number < 4; key_number = key_number + 1) begin
            for (subkey_number = 0; subkey_number < 4;
                 subkey_number = subkey_number + 1) begin
                prepare_operation(CRYPTO_FEISTEL, key_number, subkey_number,
                                  '0, '0);
                expect_word(subkey_o, '0, "reset initializes subkey to zero");
                commit_operation();
            end
        end

        for (key_number = 0; key_number < 4; key_number = key_number + 1) begin
            for (subkey_number = 0; subkey_number < 4;
                 subkey_number = subkey_number + 1) begin
                expected_subkey = 32'ha500_0000
                                | (key_number << 8)
                                | subkey_number;
                prepare_operation(CRYPTO_WRITE, key_number, subkey_number,
                                  '0, expected_subkey);
                expect_bit(access_error_o, 1'b0, "authorized key write");
                commit_operation();
            end
        end

        for (key_number = 0; key_number < 4; key_number = key_number + 1) begin
            for (subkey_number = 0; subkey_number < 4;
                 subkey_number = subkey_number + 1) begin
                expected_subkey = 32'ha500_0000
                                | (key_number << 8)
                                | subkey_number;
                prepare_operation(CRYPTO_FEISTEL, key_number, subkey_number,
                                  '0, '0);
                expect_bit(feistel_commit_o, 1'b1, "authorized Feistel commits");
                expect_word(subkey_o, expected_subkey, "selected subkey");
                commit_operation();
                expect_word(subkey_o, '0, "idle cycle hides selected subkey");
            end
        end

        idle_cycles(TEST_TIMEOUT_CYCLES - 1);
        expect_bit(authenticated_o, 1'b1,
                   "session remains before LOPW boundary activity");
        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd0, NEW_PASSWORD[31:0]);
        commit_operation();
        expect_bit(authenticated_o, 1'b1,
                   "authenticated LOPW reloads timeout");
        idle_cycles(TEST_TIMEOUT_CYCLES - 1);
        expect_bit(authenticated_o, 1'b1,
                   "LOPW reload lasts through timeout boundary minus one");

        prepare_operation(CRYPTO_FEISTEL, 2'd1, 2'd2, '0, '0);
        commit_operation();
        idle_cycles(TEST_TIMEOUT_CYCLES - 1);
        expect_bit(authenticated_o, 1'b1, "session remains before timeout");
        prepare_operation(CRYPTO_FEISTEL, 2'd1, 2'd2, '0, '0);
        expect_bit(feistel_commit_o, 1'b1, "Feistel wins over expiration");
        commit_operation();
        expect_bit(authenticated_o, 1'b1, "activity reloads timeout");

        idle_cycles(TEST_TIMEOUT_CYCLES);
        expect_bit(authenticated_o, 1'b0, "idle timeout revokes session");
        prepare_operation(CRYPTO_FEISTEL, 2'd1, 2'd2, '0, '0);
        expect_bit(access_error_o, 1'b1, "Feistel after timeout reports error");
        commit_operation();

        authenticate(TEST_PASSWORD, 1'b1, "reauthentication after timeout");
        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd0, NEW_PASSWORD[31:0]);
        commit_operation();
        prepare_operation(CRYPTO_PWD, '0, '0, '0, '0);
        expect_bit(access_error_o, 1'b1, "incomplete password change rejected");
        commit_operation();
        expect_bit(authenticated_o, 1'b1, "rejected password change keeps session");

        load_credential(NEW_PASSWORD);
        prepare_operation(CRYPTO_PWD, '0, '0, '0, '0);
        expect_bit(access_error_o, 1'b0, "complete password change accepted");
        commit_operation();
        expect_bit(authenticated_o, 1'b0, "password change revokes session");

        authenticate(TEST_PASSWORD, 1'b0, "old password rejected");
        authenticate(NEW_PASSWORD, 1'b1, "new password authenticates");
        authenticate(TEST_PASSWORD, 1'b0, "failed auth revokes active session");
        authenticate(NEW_PASSWORD, 1'b1, "reauthentication after failed auth");

        prepare_operation(CRYPTO_RVK, '0, '0, '0, '0);
        commit_operation();
        expect_bit(authenticated_o, 1'b0, "rvk revokes session");
        prepare_operation(CRYPTO_RVK, '0, '0, '0, '0);
        expect_bit(access_error_o, 1'b0, "rvk is idempotent while locked");
        commit_operation();

        authenticate(NEW_PASSWORD, 1'b1, "new password before reset");
        prepare_operation(CRYPTO_WRITE, 2'd2, 2'd3, '0, 32'hdead_beef);
        @(posedge clk_i);
        #1;
        ex_valid_i = 1'b0;
        prepare_operation(CRYPTO_LOPW, '0, '0, 2'd0, NEW_PASSWORD[31:0]);
        commit_operation();
        @(negedge clk_i);
        rst_ni = 1'b0;
        ex_valid_i = 1'b1;
        funct_i = CRYPTO_WRITE;
        key_index_i = 2'd2;
        subkey_index_i = 2'd3;
        op_a_data_i = 32'hffff_ffff;
        #1;
        expect_bit(authenticated_o, 1'b1,
                   "synchronous reset waits for active edge");
        @(posedge clk_i);
        #1;
        expect_bit(authenticated_o, 1'b0, "reset has priority");
        @(negedge clk_i);
        rst_ni = 1'b1;
        ex_valid_i = 1'b0;

        prepare_operation(CRYPTO_AUTH, '0, '0, '0, '0);
        expect_bit(auth_failed_o, 1'b1,
                   "reset clears partial credential");
        commit_operation();

        authenticate(TEST_PASSWORD, 1'b1, "reset restores initial password");
        prepare_operation(CRYPTO_FEISTEL, 2'd2, 2'd3, '0, '0);
        expect_word(subkey_o, '0, "reset clears all subkeys");
        commit_operation();

        @(negedge clk_i);
        ex_valid_i = 1'b0;
        funct_i = CRYPTO_RVK;
        @(posedge clk_i);
        #1;
        expect_bit(authenticated_o, 1'b1, "invalid EX causes no state change");

        if (error_count == 0) begin
            $display("PASS: key_vault passed %0d checks", test_count);
            $finish;
        end

        $fatal(1, "FAIL: key_vault failed %0d checks of %0d",
               error_count, test_count);
    end

endmodule
