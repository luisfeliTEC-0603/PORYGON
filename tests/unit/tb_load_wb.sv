`timescale 1ns/1ps

/**
 * @brief Prueba la captura EX/WB del load y su retencion antes de integrar RF.
 * @details El entorno representa ID/EX y el control global de avance. Una
 * respuesta tardia conserva su PC, instruccion y destino al cambiar EX.
 */
module tb_load_wb;
    import pkg_vliw::*;
    localparam slot_t LOAD_SLOT =
        {3'd3, 3'd2, LOST_LOBU, 3'd3, 1'b0, OPCODE_LOST};
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic advance = 1'b0;
    logic rsp_valid = 1'b0;
    issued_op_t lsu = '0;
    wb_channel_t load_wb;
    always #5 clk = ~clk;

    execution_stage dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .alu0_i('0),
        .alu1_i('0),
        .lsu_i(lsu),
        .bruh_i('0),
        .crypto_i('0),
        .memory_read_data_i(32'h80FF017F),
        .advance_i(advance),
        .completion_ready_i(1'b1),
        .dmem_req_ready_i(1'b1),
        .dmem_rsp_valid_i(rsp_valid),
        .dmem_rsp_error_i(1'b0),
        .load_wb_o(load_wb)
    );

    task automatic check(input wb_channel_t expected);
        #1;
        if (load_wb !== expected)
            $fatal(1, "Canal WB recibido=%h esperado=%h", load_wb, expected);
    endtask

    initial begin
        @(negedge clk);
        rst_n = 1'b1;
        lsu = {1'b1, LOAD_SLOT, 16'b0, 32'b0, DATA_BASE_ADDRESS, 32'h40};
        check('0);
        @(posedge clk);
        check('0);
        @(negedge clk);
        rsp_valid = 1'b1;
        advance = 1'b1;
        check('0);
        @(posedge clk);
        check({1'b1, 3'd3, 32'h80, 32'h40, LOAD_SLOT});
        advance = 1'b0;
        lsu = '0;
        rsp_valid = 1'b0;
        @(posedge clk);
        check({1'b1, 3'd3, 32'h80, 32'h40, LOAD_SLOT});
        rst_n = 1'b0;
        check('0);
        rst_n = 1'b1;
        advance = 1'b1;
        @(posedge clk);
        check('0);
        $display("tb_load_wb: PASS");
        $finish;
    end
endmodule
