`timescale 1ns/1ps

/**
 * @brief Testbench configurable para ejecutar cualquier programa y datos en porygon_system.
 * 
 * Permite pasar rutas de archivos e iteraciones por linea de comandos (+INSTR=... +DATA=...).
 */
module tb_system;
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

    integer max_cycles = 100;
    integer cycle_count = 0;
    integer data_access_errors = 0;
    integer instruction_access_errors = 0;
    integer alignment_errors = 0;
    integer auth_failed_errors = 0;
    integer access_errors = 0;

    reg [1023:0] instr_file = "";
    reg [1023:0] data_file = "";
    reg [1023:0] vcd_file = "build/waves/system.vcd";
    reg [1023:0] dump_file = "build/memory_dump.mem";

    always #5 clk = ~clk;

    porygon_system dut (
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
            cycle_count <= cycle_count + 1;
            if (data_access_error) begin
                data_access_errors <= data_access_errors + 1;
                $display("[ERROR] data_access_error at cycle %0d, pc=0x%08h, addr=0x%08h",
                         cycle_count, data_access_error_pc, dut.data_address);
            end
            if (instruction_access_error) instruction_access_errors <= instruction_access_errors + 1;
            if (invalid_address) alignment_errors <= alignment_errors + 1;
            if (auth_failed) auth_failed_errors <= auth_failed_errors + 1;
            if (access_error) access_errors <= access_errors + 1;
        end
    end

    initial begin
        void'($value$plusargs("INSTR=%s", instr_file));
        void'($value$plusargs("DATA=%s", data_file));
        void'($value$plusargs("CYCLES=%d", max_cycles));
        void'($value$plusargs("VCD=%s", vcd_file));
        void'($value$plusargs("DUMP=%s", dump_file));

        $dumpfile(vcd_file);
        $dumpvars(0, tb_system);

        if (instr_file != "") begin
            $readmemh(instr_file, dut.u_instruction_memory.memory);
            $display("[tb_system] Instrucciones cargadas desde: %0s", instr_file);
        end
        if (data_file != "") begin
            $readmemh(data_file, dut.u_data_memory.memory);
            $display("[tb_system] Datos cargados desde: %0s", data_file);
        end

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        @(negedge clk);
        rst_n = 1'b1;

        repeat (max_cycles) @(posedge clk);
        #1;

        $display("\n=======================================================");
        $display("  RESUMEN DE EJECUCION (tb_system) - %0d ciclos", cycle_count);
        $display("=======================================================");
        $display("PC final        : 0x%08h", dut.instruction_address);
        $display("Authenticated   : %b", authenticated);
        $display("Eventos Error   : data_access=%0d, instr_access=%0d, align=%0d, auth_failed=%0d, access_err=%0d",
                 data_access_errors, instruction_access_errors, alignment_errors, auth_failed_errors, access_errors);
        $display("-------------------------------------------------------");
        $display("Registros GPR:");
        for (int i = 0; i < 8; i++) begin
            $display("  r%0d = 0x%08h", i, dut.u_processor.u_register_file.registers_q[i]);
        end
        $display("=======================================================");

        $writememh(dump_file, dut.u_data_memory.memory);
        $display("Volcado de memoria generado en: %0s", dump_file);
        $finish;
    end
endmodule
