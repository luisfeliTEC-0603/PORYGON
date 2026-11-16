`timescale 1ns/1ps

/**
 * @brief Compara el sistema real con CPU y memoria de referencia de testbench.
 * @details Misma ISA/imagen y resultado arquitectonico con latencias distintas.
 * Verifica cierre, cancelacion de bundles jovenes, metricas conectadas y reset.
 * No usa ni sustituye las salidas aun pendientes del observador P2-10.
 */
module tb_porygon_hierarchy;
    import pkg_vliw::*;
    localparam integer REFERENCE_BYTES = 8192;
    logic clk = 0, rst_n, start = 0, ref_rst_n;
    logic stop_done, halted, ref_halted;
    pkg_metrics::cpu_events_t events, ref_events;
    logic ref_read, ref_rom_error, req_valid, req_ready, req_write;
    logic rsp_valid, rsp_ready, rsp_error;
    address_t ref_pc, req_addr;
    word_t req_data, rsp_data;
    pkg_memory::byte_mask_t mask;
    pkg_metrics::demand_origin_t ref_origin;
    bundle_t ref_bundle;
    integer bundles, instructions, begins, completions, stops, stalls;
    integer ref_bundles, ref_instructions, ref_begins, ref_completions;
    address_t held_pc;
    `include "hierarchy_snapshot.svh"
    always #5 clk = ~clk;

    porygon_system #(
        .INSTRUCTION_INIT_FILE("tests/programs/top/top_integration.mem"),
        .INSTRUCTION_INIT_BUNDLES(28)
    ) dut (
        .clk_i(clk), .rst_ni(rst_n), .perf_start_i(start),
        .perf_stop_i(1'b0), .perf_stop_error_i(1'b0),
        .stop_done_o(stop_done), .halted_o(halted), .cpu_events_o(events)
    );
    assign ref_rst_n = dut.core_rst_n;
    vliw_processor reference_cpu (
        .clk_i(clk), .rst_ni(ref_rst_n), .instruction_bundle_i(ref_bundle),
        .instruction_error_i(ref_rom_error), .instruction_address_o(ref_pc),
        .instruction_read_enable_o(ref_read), .dmem_rsp_origin_i(ref_origin),
        .perf_events_o(ref_events), .halted_o(ref_halted),
        .dmem_req_valid_o(req_valid), .dmem_req_ready_i(req_ready),
        .dmem_req_addr_o(req_addr), .dmem_req_write_o(req_write),
        .dmem_req_wdata_o(req_data), .dmem_req_wstrb_o(mask),
        .dmem_rsp_valid_i(rsp_valid), .dmem_rsp_ready_o(rsp_ready),
        .dmem_rsp_rdata_i(rsp_data), .dmem_rsp_error_i(rsp_error)
    );
    instruction_memory #(
        .INIT_FILE("tests/programs/top/top_integration.mem"), .INIT_BUNDLES(28)
    ) reference_rom (
        .clk_i(clk), .rst_ni(ref_rst_n), .address_i(ref_pc), .read_enable_i(ref_read),
        .bundle_o(ref_bundle), .out_of_range_o(ref_rom_error)
    );
    cpu_memory_reference #(.MEMORY_BYTES(REFERENCE_BYTES)) reference_memory (
        .clk_i(clk), .rst_ni(ref_rst_n), .accept_enable_i(1'b1),
        .req_valid_i(req_valid), .req_ready_o(req_ready), .req_addr_i(req_addr),
        .req_write_i(req_write), .req_wdata_i(req_data), .req_wstrb_i(mask),
        .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready), .rsp_rdata_o(rsp_data),
        .rsp_error_o(rsp_error), .rsp_origin_o(ref_origin)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            {bundles, instructions, begins, completions, stops, stalls} = '0;
            {ref_bundles, ref_instructions, ref_begins, ref_completions} = '0;
        end else begin
            bundles += events.done_bundles;
            instructions += events.done_instructions;
            begins += int'(events.dmem_begin);
            completions += int'(events.dmem_done);
            stops += int'(stop_done);
            stalls += int'(events.stall);
            ref_bundles += ref_events.done_bundles;
            ref_instructions += ref_events.done_instructions;
            ref_begins += int'(ref_events.dmem_begin);
            ref_completions += int'(ref_events.dmem_done);
            if (dut.u_data_memory.u_performance_counters.cpu_events_i !== events ||
                dut.u_data_memory.u_performance_counters.perf_stop_i !== stop_done ||
                dut.u_data_memory.u_performance_counters.perf_start_i !== start)
                $fatal(1, "Eventos CPU o start/stop desconectados del observador");
            if (events.dmem_done && events.dmem_origin !== dut.data_rsp_origin)
                $fatal(1, "Procedencia de la respuesta desconectada");
            if (halted && events !== '0) $fatal(1, "Eventos CPU posteriores al cierre");
            if (dut.core_rst_n && !halted && !dut.u_processor.pipeline_advance) begin
                held_pc = dut.instruction_address;
                for (integer port_index = 0; port_index < RF_WRITE_PORTS; port_index++)
                    if (dut.u_processor.write_enable[port_index]) $fatal(1, "WB durante stall");
                #1;
                if (dut.instruction_address !== held_pc) $fatal(1, "PC cambio durante stall");
            end
        end
    end

    initial begin
        rst_n = 0;
        #1;
        for (integer mode = 0; mode < 4; mode++) begin
            @(negedge clk);
            rst_n = 0;
            start = 0;
            repeat (3) @(negedge clk);
            for (integer index = 0; index < pkg_memory::MEMORY_BYTES; index++) begin
                dut.u_data_memory.u_main_memory.u_storage.memory[index] = 0;
                if (index < REFERENCE_BYTES) reference_memory.memory[index] = 0;
            end
            $readmemh("tests/programs/top/top_data.mem", dut.u_data_memory.u_main_memory.u_storage.memory, 0, 3);
            $readmemh("tests/programs/top/top_data.mem", reference_memory.memory, 0, 3);
            case (mode)
                0: dut.u_instruction_memory.memory[28] = 64'h2;
                1: dut.u_instruction_memory.memory[28] =
                    {16'd3, {3'd6, 3'd0, MATH_MUL, 1'b1, 1'b1, OPCODE_MATH},
                     {3'd3, 3'd1, LOST_LOW, 3'b0, 1'b0, OPCODE_LOST}, 16'h0002};
                2: dut.u_instruction_memory.memory[28] =
                    {16'h0800, {3'd3, 3'd1, LOST_LOW, 3'b0, 1'b1, OPCODE_LOST}, 16'b0, 16'h0002};
                3: dut.u_instruction_memory.memory[28] =
                    {16'h1800, {3'd3, 3'd1, LOST_STW, 3'b0, 1'b1, OPCODE_LOST}, 16'b0, 16'h0002};
            endcase
            /** Estos dos bundles no deben modificar RF ni datos. */
            dut.u_instruction_memory.memory[29] = 64'haaaae024;
            dut.u_instruction_memory.memory[30] = {48'b0, {3'd7, 3'd1, LOST_STW, 3'b0, 1'b0, OPCODE_LOST}};
            for (integer index = 28; index <= 30; index++)
                reference_rom.memory[index] = dut.u_instruction_memory.memory[index];
            rst_n = 1;
            repeat (2) @(negedge clk);
            if (dut.instruction_read_enable || dut.data_req_valid)
                $fatal(1, "Fetch/demanda antes de perf_start");
            start = 1;
            @(negedge clk);
            start = 0;
            wait (halted && ref_halted);
            @(negedge clk);
            capture_architectural_memory();
            for (integer index = 0; index < NUM_REGS; index++)
                if (dut.u_processor.u_register_file.registers_q[index] !==
                    reference_cpu.u_register_file.registers_q[index])
                    $fatal(1, "RF distinto de referencia modo=%0d r%0d", mode, index);
            for (integer index = 0; index < REFERENCE_BYTES; index++)
                if (architectural_memory[index] !== reference_memory.memory[index])
                    $fatal(1, "Datos distintos de referencia modo=%0d byte=%h", mode, index);
            for (integer index = REFERENCE_BYTES; index < pkg_memory::MEMORY_BYTES; index++)
                if (architectural_memory[index] !== 8'b0)
                    $fatal(1, "Se modificaron bytes fuera de los datos del programa");
            if (bundles != ref_bundles || instructions != ref_instructions ||
                begins != ref_begins || completions != ref_completions ||
                begins != completions || stops != 1 || stalls < 47)
                $fatal(1, "Eventos de finalizacion distintos de referencia");
            repeat (4) @(negedge clk);
            if (!halted || stop_done || events !== '0) $fatal(1, "Cierre inestable");
        end
        $display("PASS tb_porygon_hierarchy: RF/datos contra referencia, stalls, reset, cuatro cierres y eventos");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Timeout tb_porygon_hierarchy");
    end
endmodule
