`timescale 1ns/1ps

module tb_top;
    import pkg_vliw::*;

    logic clk = 1'b0;
    logic rst_n;
    logic authenticated;
    logic auth_failed;
    logic access_error;
    address_t crypto_event_pc;
    logic invalid_address;
    address_t invalid_address_pc;
    logic instruction_access_error;
    address_t instruction_access_error_pc;
    logic data_access_error;
    address_t data_access_error_pc;

    integer checks_passed = 0;
    integer data_access_errors = 0;
    integer instruction_access_errors = 0;
    integer alignment_errors = 0;
    integer crypto_errors = 0;
    address_t last_data_access_error_pc = '0;

    always #5 clk = ~clk;

    porygon_system #(
        .INSTRUCTION_INIT_FILE("hardware/tb/programs/top_integration.mem"),
        .INSTRUCTION_INIT_BUNDLES(28),
        .DATA_INIT_FILE("hardware/tb/programs/top_data.mem"),
        .DATA_INIT_BYTES(4)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .authenticated_o(authenticated),
        .auth_failed_o(auth_failed),
        .access_error_o(access_error),
        .crypto_event_pc_o(crypto_event_pc),
        .invalid_address_o(invalid_address),
        .invalid_address_pc_o(invalid_address_pc),
        .instruction_access_error_o(instruction_access_error),
        .instruction_access_error_pc_o(instruction_access_error_pc),
        .data_access_error_o(data_access_error),
        .data_access_error_pc_o(data_access_error_pc)
    );

    always @(posedge clk) begin
        if (rst_n) begin
            if (data_access_error) begin
                data_access_errors = data_access_errors + 1;
                last_data_access_error_pc = data_access_error_pc;
            end
            if (instruction_access_error) begin
                instruction_access_errors = instruction_access_errors + 1;
            end
            if (invalid_address) begin
                alignment_errors = alignment_errors + 1;
            end
            if (auth_failed || access_error) begin
                crypto_errors = crypto_errors + 1;
            end
        end
    end

    task automatic expect_word(
        input string name,
        input word_t actual,
        input word_t expected
    );
        if (actual !== expected) begin
            $fatal(1, "%s: recibido=%08h esperado=%08h", name, actual, expected);
        end
        checks_passed = checks_passed + 1;
    endtask

    task automatic expect_byte(
        input string name,
        input logic [7:0] actual,
        input logic [7:0] expected
    );
        if (actual !== expected) begin
            $fatal(1, "%s: recibido=%02h esperado=%02h", name, actual, expected);
        end
        checks_passed = checks_passed + 1;
    endtask

    task automatic expect_reset_state;
        integer register_index;
        begin
            for (register_index = 0; register_index < NUM_REGS; register_index++) begin
                expect_word(
                    $sformatf("reset r%0d", register_index),
                    dut.u_processor.u_register_file.registers_q[register_index],
                    32'h0000_0000
                );
            end
        end
    endtask

    initial begin
        $dumpfile("build/waves/top.vcd");
        $dumpvars(0, tb_top);

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        expect_reset_state();

        // Primera pasada: reset con el bundle MUL/CRYPTO ya emitido. El reset
        // debe cancelar ID/EX, multiplicacion, loads y eventos pendientes.
        @(negedge clk);
        rst_n = 1'b1;
        wait (dut.instruction_address == 32'h0000_00C0);
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        expect_reset_state();

        data_access_errors = 0;
        instruction_access_errors = 0;
        alignment_errors = 0;
        crypto_errors = 0;
        last_data_access_error_pc = '0;

        // Segunda pasada completa desde PC=0.
        @(negedge clk);
        rst_n = 1'b1;
        repeat (45) @(posedge clk);
        #1;

        expect_word("r0 constante", dut.u_processor.u_register_file.registers_q[0],
                    32'h0000_0000);
        expect_word("r1 base datos", dut.u_processor.u_register_file.registers_q[1],
                    32'h0001_0000);
        expect_word("r2 load original y branch tomado",
                    dut.u_processor.u_register_file.registers_q[2], 32'h1234_5678);
        expect_word("r3 load valido preservado tras load fuera de rango",
                    dut.u_processor.u_register_file.registers_q[3], 32'h1234_5678);
        expect_word("r4 mascara little endian",
                    dut.u_processor.u_register_file.registers_q[4], 32'h1234_7878);
        expect_word("r5 direccion fuera de rango",
                    dut.u_processor.u_register_file.registers_q[5], 32'h0002_0000);
        expect_word("r6 multiplicacion", dut.u_processor.u_register_file.registers_q[6],
                    32'h0000_0003);
        expect_word("r7 branch no tomado", dut.u_processor.u_register_file.registers_q[7],
                    32'h0000_2223);

        expect_byte("RAM +4 byte 0", dut.u_data_memory.memory[4], 8'h78);
        expect_byte("RAM +5 byte preservado/escrito", dut.u_data_memory.memory[5], 8'h78);
        expect_byte("RAM +6 byte preservado", dut.u_data_memory.memory[6], 8'h34);
        expect_byte("RAM +7 byte preservado", dut.u_data_memory.memory[7], 8'h12);

        if (data_access_errors != 1 ||
            last_data_access_error_pc !== 32'h0000_00A8) begin
            $fatal(1, "diagnostico rango datos: eventos=%0d pc=%08h",
                   data_access_errors, last_data_access_error_pc);
        end
        checks_passed = checks_passed + 1;

        if (instruction_access_errors != 0 || alignment_errors != 0 ||
            crypto_errors != 0 || authenticated !== 1'b0) begin
            $fatal(1, "eventos inesperados: if=%0d align=%0d crypto=%0d auth=%b",
                   instruction_access_errors, alignment_errors,
                   crypto_errors, authenticated);
        end
        checks_passed = checks_passed + 1;

        $writememh("build/memory_dump.mem", dut.u_data_memory.memory);
        $display("RAM dump: build/memory_dump.mem");
        $display("PASS tb_top: %0d comprobaciones", checks_passed);
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "timeout tb_top");
    end
endmodule
