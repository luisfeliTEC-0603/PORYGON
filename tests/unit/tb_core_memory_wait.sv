`timescale 1ns/1ps

/**
 * @brief Prueba espera y campos CPU-L1 de loads y stores que terminan con error.
 * @details Doble de ROM sincrona: todas las posiciones contienen el mismo load
 * desde r0, direccion fuera de datos. El entorno retrasa aceptacion/respuesta;
 * no modela una jerarquia funcional ni comprueba aun los otros productores WB.
 */
module tb_core_memory_wait;
    import pkg_vliw::*;
    localparam slot_t LOAD_SLOT = {3'd3, 3'd0, LOST_LOW, 3'b000, 1'b0, OPCODE_LOST};
    localparam slot_t STORE_SLOT = {3'd3, 3'd0, LOST_STB, 3'b001, 1'b0, OPCODE_LOST};
    slot_t memory_slot = LOAD_SLOT;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic req_ready = 1'b0;
    logic rsp_valid = 1'b0;
    logic req_valid, read_enable;
    address_t pc, held_pc;
    pkg_memory::address_t req_addr;
    pkg_memory::word_t req_wdata;
    pkg_memory::byte_mask_t req_wstrb;
    logic req_write;
    issued_op_t held_lsu;
    bundle_t bundle = '0;
    always #5 clk = ~clk;
    always @(posedge clk)
        if (read_enable) bundle <= {{(BUNDLE_WIDTH-SLOT_WIDTH){1'b0}}, memory_slot};

    vliw_processor dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .instruction_bundle_i(bundle),
        .dmem_rsp_rdata_i(32'b0),
        .dmem_req_ready_i(req_ready),
        .dmem_rsp_valid_i(rsp_valid),
        .dmem_rsp_error_i(1'b1),
        .dmem_req_valid_o(req_valid),
        .dmem_req_addr_o(req_addr),
        .dmem_req_write_o(req_write),
        .dmem_req_wstrb_o(req_wstrb),
        .dmem_req_wdata_o(req_wdata),
        .instruction_address_o(pc),
        .instruction_read_enable_o(read_enable)
    );

    initial begin
        @(negedge clk);
        rst_n = 1'b1;
        wait (req_valid);
        @(negedge clk);
        held_pc = pc;
        held_lsu = dut.ex_operation[UNIT_LSU];
        repeat (2) @(posedge clk);
        #1;
        if (pc !== held_pc || dut.ex_operation[UNIT_LSU] !== held_lsu || !req_valid || read_enable)
            $fatal(1, "Fronteras no retenidas antes de aceptar");
        if ({req_addr, req_write, req_wstrb, req_wdata} !== '0)
            $fatal(1, "Campos CPU-L1 incorrectos para low r3, 0(r0)");
        @(negedge clk);
        req_ready = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (pc !== held_pc || dut.ex_operation[UNIT_LSU] !== held_lsu || req_valid || read_enable)
            $fatal(1, "Solicitud repetida o avance antes de la respuesta");
        @(negedge clk);
        rsp_valid = 1'b1;
        @(posedge clk);
        #1;
        rsp_valid = 1'b0;
        if (pc !== held_pc + BUNDLE_BYTES)
            $fatal(1, "La respuesta con error no reanudo el nucleo");
        rst_n = 1'b0;
        req_ready = 1'b0;
        memory_slot = STORE_SLOT;
        @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        wait (req_valid);
        @(negedge clk);
        if ({req_addr, req_write, req_wstrb, req_wdata} !== {32'b0, 1'b1, 4'b0010, 32'b0})
            $fatal(1, "Campos CPU-L1 incorrectos para stb r3, 1(r0)");
        req_ready = 1'b1;
        @(posedge clk);
        #1;
        if (req_valid !== 1'b0)
            $fatal(1, "Store aceptado se volvio a ofrecer");
        @(negedge clk);
        rsp_valid = 1'b1;
        @(posedge clk);
        #1;
        $display("tb_core_memory_wait: PASS");
        $finish;
    end

    initial begin
        #1000;
        $fatal(1, "Timeout esperando el progreso del control del nucleo");
    end
endmodule
