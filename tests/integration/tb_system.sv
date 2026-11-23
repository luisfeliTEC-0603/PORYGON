`timescale 1ns/1ps

/**
 * @brief Testbench configurable para ejecutar cualquier programa y datos en porygon_system.
 * 
 * Permite pasar rutas de archivos y un watchdog por linea de comandos.
 * La ejecucion normal termina al vaciar el programa tras su salto final.
 */
module tb_system;
    parameter bit REFERENCE_WITHOUT_CACHE = 1'b0;
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
    logic perf_start = 0, perf_stop;
    logic stop_done, halted;
    pkg_metrics::cpu_events_t cpu_events;
    pkg_metrics::snapshot_t perf_snapshot;
    logic snapshot_valid;
    `include "hierarchy_snapshot.svh"
    `include "metrics_export.svh"

    localparam integer DEFAULT_MAX_CYCLES = 100000;

    integer max_cycles = DEFAULT_MAX_CYCLES;
    integer cycle_count = 0;
    integer data_access_errors = 0;
    integer instruction_access_errors = 0;
    integer alignment_errors = 0;
    integer auth_failed_errors = 0;
    integer access_errors = 0;
    logic halt_detected = 1'b0;
    logic watchdog_expired = 1'b0;
    address_t halt_pc = '0;

    reg [1023:0] instr_file = "";
    reg [1023:0] data_file = "";
    reg [1023:0] vcd_file = "build/waves/system.vcd";
    reg [1023:0] dump_file = "build/memory_dump.mem";
    reg [1023:0] result_file = "";
    reg [1023:0] metrics_file = "build/metrics.txt";
    integer metrics_fd;
    integer result_fd;
    integer total_errors;

    always #5 clk = ~clk;

    porygon_system #(.REFERENCE_WITHOUT_CACHE(REFERENCE_WITHOUT_CACHE)) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .perf_start_i(perf_start), .perf_stop_i(perf_stop),
        .perf_stop_error_i(perf_stop), .stop_done_o(stop_done), .halted_o(halted),
        .cpu_events_o(cpu_events),
        .perf_snapshot_o(perf_snapshot), .perf_snapshot_valid_o(snapshot_valid),
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
        if (!rst_n) begin
            cycle_count <= 0;
            data_access_errors <= 0;
            instruction_access_errors <= 0;
            alignment_errors <= 0;
            auth_failed_errors <= 0;
            access_errors <= 0;
            halt_detected <= 1'b0;
            watchdog_expired <= 1'b0;
            halt_pc <= '0;
        end else if (dut.core_started_q && !halt_detected && !watchdog_expired) begin
            cycle_count <= cycle_count + 1;
            if (data_access_error) begin
                data_access_errors <= data_access_errors + 1;
                $display("[ERROR] data_access_error at cycle %0d, pc=0x%08h, addr=0x%08h",
                         cycle_count, data_access_error_pc, dut.data_address);
            end
            if (cpu_events.instruction_error.valid) instruction_access_errors <= instruction_access_errors + 1;
            if (invalid_address) alignment_errors <= alignment_errors + 1;
            if (auth_failed) auth_failed_errors <= auth_failed_errors + 1;
            if (access_error) access_errors <= access_errors + 1;

            // El codegen representa halt como un salto tomado al PC del propio JUMP.
            if (dut.u_processor.stop_fire &&
                (dut.u_processor.branch_target ==
                 dut.u_processor.u_execution.bruh_i.pc)) begin
                halt_pc <= dut.u_processor.u_execution.bruh_i.pc;
            end
            if (stop_done) begin
                halt_detected <= 1'b1;
            end else if ((cycle_count + 1) >= max_cycles) begin
                watchdog_expired <= 1'b1;
            end
        end
    end

    assign perf_stop = rst_n && dut.core_started_q && !halt_detected && !stop_done &&
                       ((cycle_count + 1) >= max_cycles);

    initial begin
        void'($value$plusargs("INSTR=%s", instr_file));
        void'($value$plusargs("DATA=%s", data_file));
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
        void'($value$plusargs("VCD=%s", vcd_file));
        void'($value$plusargs("DUMP=%s", dump_file));
        void'($value$plusargs("RESULT=%s", result_file));
        void'($value$plusargs("METRICS=%s", metrics_file));

        $dumpfile(vcd_file);
        $dumpvars(0, tb_system);

        #1;

        if (instr_file != "") begin
            $readmemh(instr_file, dut.u_instruction_memory.memory);
            $display("[tb_system] Instrucciones cargadas desde: %0s", instr_file);
        end
        if (data_file != "") begin
            $readmemh(data_file, dut.u_data_memory.u_main_memory.u_storage.memory);
            $display("[tb_system] Datos cargados desde: %0s", data_file);
        end

        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        @(negedge clk);
        rst_n = 1'b1;
        perf_start = 1'b1;
        @(negedge clk);
        perf_start = 1'b0;

        wait (halt_detected || watchdog_expired);
        #1;
        if (!snapshot_valid) $fatal(1, "La medicion no cerro con el programa/watchdog");
        metrics_fd = $fopen(metrics_file, "w");
        if (!metrics_fd) $fatal(1, "No se pudo exportar la medicion: %0s", metrics_file);
        export_metrics(metrics_fd);
        $fclose(metrics_fd);

        $display("\n=======================================================");
        $display("  RESUMEN DE EJECUCION (tb_system) - %0d ciclos", cycle_count);
        $display("=======================================================");
        if (halt_detected)
            $display("Terminacion     : HALT por salto a si mismo en 0x%08h", halt_pc);
        else
            $display("Terminacion     : TIMEOUT (MAX_CYCLES=%0d)", max_cycles);
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

        capture_architectural_memory();
        $writememh(dump_file, architectural_memory);
        $display("Volcado de memoria generado en: %0s", dump_file);

        if (result_file != "") begin
            total_errors = data_access_errors + instruction_access_errors +
                           alignment_errors + auth_failed_errors + access_errors;
            result_fd = $fopen(result_file, "w");
            if (result_fd == 0) begin
                $fatal(1, "No se pudo crear el archivo de resultados: %0s", result_file);
            end
            $fdisplay(result_fd, "cycles=%0d", cycle_count);
            $fdisplay(result_fd, "max_cycles=%0d", max_cycles);
            $fdisplay(result_fd, "halted=%0d", halt_detected);
            $fdisplay(result_fd, "halt_pc=0x%08h", halt_pc);
            $fdisplay(result_fd, "timeout=%0d", watchdog_expired);
            $fdisplay(result_fd, "pc=0x%08h", dut.instruction_address);
            $fdisplay(result_fd, "authenticated=%0d", authenticated);
            $fdisplay(result_fd, "data_access_errors=%0d", data_access_errors);
            $fdisplay(result_fd, "instruction_access_errors=%0d", instruction_access_errors);
            $fdisplay(result_fd, "alignment_errors=%0d", alignment_errors);
            $fdisplay(result_fd, "auth_failed_errors=%0d", auth_failed_errors);
            $fdisplay(result_fd, "access_errors=%0d", access_errors);
            $fdisplay(result_fd, "errors=%0d", total_errors);
            for (int i = 0; i < 8; i++) begin
                $fdisplay(result_fd, "r%0d=0x%08h", i,
                          dut.u_processor.u_register_file.registers_q[i]);
            end
            $fclose(result_fd);
        end
        $finish;
    end
endmodule
