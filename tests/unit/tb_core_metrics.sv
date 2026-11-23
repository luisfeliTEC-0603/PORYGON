`timescale 1ns/1ps
/** @brief Eventos por flanco: causas exclusivas, origen, diagnosticos y retardo. */
module tb_core_metrics;
    import pkg_vliw::*;
    import pkg_metrics::*;
    logic clk = 0, rst_n = 0, advance = 0, halted = 0;
    logic id_valid = 1, admit = 0, rom_error = 0, stop = 0;
    logic ex_valid = 0, branch = 0, taken = 0, active = 1;
    logic req_valid = 1, req_ready = 0, rsp_valid = 0, rsp_ready = 0, done = 0, error = 0;
    logic alignment = 0;
    bundle_t bundle = 0;
    cpu_events_t events;
    always #5 clk = ~clk;
    core_metrics dut (
        .clk_i(clk), .rst_ni(rst_n), .advance_i(advance), .halted_i(halted),
        .fetch_active_i(1'b1), .fetch_transfer_i(advance && !stop),
        .id_valid_i(id_valid), .id_admit_i(admit), .id_pc_i(32'h20000),
        .instruction_error_i(rom_error), .stop_admission_i(stop),
        .ex_valid_i(ex_valid), .ex_bundle_i(bundle), .wb_operations_i(8'b0), .mul_operation_i(1'b0),
        .branch_valid_i(branch), .branch_taken_i(taken), .memory_active_i(active),
        .req_valid_i(req_valid), .req_ready_i(req_ready), .rsp_valid_i(rsp_valid), .rsp_ready_i(rsp_ready),
        .dmem_done_i(done), .dmem_error_i(error), .dmem_write_i(1'b0), .dmem_origin_i(ORIGIN_WB),
        .alignment_error_i(alignment), .effective_address_i(32'h10001), .events_o(events)
    );
    task automatic tick;
        @(posedge clk);
        #1;
        @(negedge clk);
    endtask
    task automatic wait_event(input wait_reason_t reason, input logic first);
        #1;
        if (!events.stall || events.wait_reason !== reason || events.dmem_begin !== first ||
            events.stage_mem_stalls !== events.stage_occupied || events.done_instructions != 0)
            $fatal(1, "Espera incorrecta razon=%0d evento=%h", reason, events);
    endtask
    initial begin
        @(negedge clk);
        rst_n = 1;
        rom_error = 1;
        wait_event(WAIT_ACCEPT, 1);
        tick();
        rom_error = 0;
        wait_event(WAIT_ACCEPT, 0);
        req_ready = 1;
        wait_event(WAIT_MISS, 0);
        tick();
        req_valid = 0;
        rsp_valid = 1;
        wait_event(WAIT_RESPONSE, 0);
        tick();
        advance = 1; rsp_ready = 1; done = 1; admit = 1;
        #1;
        if (!events.dmem_done || events.dmem_origin !== ORIGIN_WB ||
            !events.instruction_error.valid || events.instruction_error.address !== 32'h20000)
            $fatal(1, "Se perdio origen o diagnostico ROM retenido");
        tick();
        req_valid = 1; error = 1;
        #1;
        if (!events.dmem_begin || events.dmem_origin !== ORIGIN_ERROR || events.instruction_error.valid)
            $fatal(1, "Acceso siguiente/error o diagnostico duplicado");
        tick();
        req_valid = 0; rsp_valid = 0; done = 0; active = 0; admit = 0;
        advance = 0; alignment = 1; rom_error = 1;
        tick();
        rom_error = 0; stop = 1;
        tick();
        stop = 0; admit = 1; advance = 1;
        #1;
        if (events.instruction_error.valid || !events.alignment_error.valid ||
            events.alignment_error.address !== 32'h10001)
            $fatal(1, "Cancelacion ROM o diagnostico de alineacion incorrectos");
        alignment = 0; ex_valid = 1; branch = 1; taken = 1; bundle = 64'h22;
        tick();
        branch = 0; bundle = 0;
        #1;
        if (!events.branch_delay) $fatal(1, "Falta primer bundle de retardo");
        tick();
        advance = 0;
        #1;
        if (events.branch_delay) $fatal(1, "Retardo contado durante stall");
        tick();
        advance = 1;
        #1;
        if (!events.branch_delay) $fatal(1, "Falta segundo bundle de retardo");
        tick();
        #1;
        if (events.branch_delay) $fatal(1, "Retardo contado mas de dos veces");
        halted = 1;
        #1;
        if (events !== '0) $fatal(1, "Eventos posteriores al cierre");
        rst_n = 0;
        #1;
        if (events !== '0) $fatal(1, "Eventos durante reset");
        $display("tb_core_metrics: PASS");
        $finish;
    end
endmodule
