`timescale 1ns/1ps

/**
 * @brief Prueba aislada del control CPU-L1 y formato de respuesta del load.
 * @details Cada step ofrece una operacion EX estable hasta consumir respuesta.
 * El resultado esperado concatena req_valid, rsp_ready y done antes del flanco.
 */
module tb_lost_handshake;
    import pkg_vliw::*;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic nop_flag = 1'b1;
    logic req_ready = 1'b0;
    logic rsp_valid = 1'b0;
    logic completion_ready = 1'b0;
    logic req_valid, rsp_ready, done;
    logic response_error = 1'b0;
    logic load_valid, access_error;
    reg_index_t load_rd;
    word_t load_data;
    lost_inst_t instruction;
    always #5 clk = ~clk;

    lost_unit dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .nop_flag_i(nop_flag),
        .instruction_i(instruction),
        .immediate_i(16'b0),
        .base_address_i(pkg_vliw::DATA_BASE_ADDRESS),
        .store_data_i(32'hAABBCCDD),
        .memory_read_data_i(32'h80FF017F),
        .dmem_req_ready_i(req_ready),
        .dmem_rsp_valid_i(rsp_valid),
        .dmem_rsp_error_i(response_error),
        .completion_ready_i(completion_ready),
        .dmem_req_valid_o(req_valid),
        .dmem_rsp_ready_o(rsp_ready),
        .dmem_done_o(done),
        .dmem_error_o(access_error),
        .load_valid_o(load_valid),
        .load_rd_o(load_rd),
        .load_data_o(load_data)
    );

    task automatic step(
        input logic accept,
        input logic response,
        input logic consume,
        input logic [2:0] expected
    );
        @(negedge clk);
        req_ready = accept;
        rsp_valid = response;
        completion_ready = consume;
        #1;
        if ({req_valid, rsp_ready, done} !== expected)
            $fatal(1, "handshake: recibido=%b%b%b esperado=%b", req_valid, rsp_ready, done, expected);
        if (!expected[0] && (load_valid !== 1'b0 || access_error !== 1'b0))
            $fatal(1, "Resultado o error emitido antes del consumo de respuesta");
        @(posedge clk);
        #1;
    endtask

    /** @brief Comprueba el dato antes del flanco que lo transfiere hacia WB. */
    task automatic check_load(
        input logic [3:0] funct,
        input logic [2:0] lane,
        input logic error,
        input word_t expected
    );
        @(negedge clk);
        instruction = {3'd3, 3'd2, funct, lane, 1'b0, OPCODE_LOST};
        nop_flag = 1'b0;
        req_ready = 1'b1;
        rsp_valid = 1'b1;
        completion_ready = 1'b1;
        response_error = error;
        #1;
        if (done !== 1'b1 || load_valid !== !error || access_error !== error ||
            load_rd !== (error ? 3'd0 : 3'd3) || load_data !== expected)
            $fatal(1, "Load funct=%h lane=%d: valid=%b rd=%d data=%h error=%b",
                   funct, lane, load_valid, load_rd, load_data, access_error);
        @(posedge clk);
        #1;
    endtask

    initial begin
        instruction = {3'd1, 3'd2, LOST_STW, 3'b000, 1'b0, OPCODE_LOST};
        @(negedge clk);
        rst_n = 1'b1;
        nop_flag = 1'b0;
        step(1'b0, 1'b0, 1'b1, 3'b100); // Oferta sin aceptacion.
        step(1'b0, 1'b0, 1'b1, 3'b100); // Conserva la oferta.
        step(1'b1, 1'b0, 1'b1, 3'b110); // Acepta sin respuesta.
        step(1'b1, 1'b0, 1'b1, 3'b010); // No repite la solicitud aceptada.
        step(1'b1, 1'b1, 1'b0, 3'b000); // Respuesta retenida por el receptor.
        step(1'b1, 1'b1, 1'b1, 3'b011); // Consume y vuelve a OFFER.
        step(1'b1, 1'b1, 1'b1, 3'b111); // Otra operacion: hit en un flanco.
        step(1'b1, 1'b0, 1'b1, 3'b110); // Acepta otra operacion antes de reset.
        rst_n = 1'b0;
        nop_flag = 1'b1;
        rsp_valid = 1'b1;
        #1;
        if ({req_valid, rsp_ready, done} !== 3'b000)
            $fatal(1, "Transferencia durante reset");
        @(negedge clk);
        rst_n = 1'b1;
        #1;
        if ({req_valid, rsp_ready, done} !== 3'b000)
            $fatal(1, "Respuesta antigua consumida despues de reset");
        check_load(LOST_LOW, 3'd0, 1'b0, 32'h80FF017F);
        check_load(LOST_LOB, 3'd3, 1'b0, 32'hFFFFFF80);
        check_load(LOST_LOBU, 3'd3, 1'b0, 32'h00000080);
        check_load(LOST_LOH, 3'd2, 1'b0, 32'hFFFF80FF);
        check_load(LOST_LOHU, 3'd2, 1'b0, 32'h000080FF);
        instruction = {3'd3, 3'd2, LOST_LOH, 3'd2, 1'b0, OPCODE_LOST};
        rsp_valid = 1'b0;
        step(1'b1, 1'b0, 1'b1, 3'b110);
        step(1'b1, 1'b1, 1'b0, 3'b000);
        check_load(LOST_LOH, 3'd2, 1'b0, 32'hFFFF80FF);
        check_load(LOST_LOW, 3'd0, 1'b1, 32'b0);
        instruction = {3'd1, 3'd2, LOST_STW, 3'b000, 1'b0, OPCODE_LOST};
        step(1'b1, 1'b1, 1'b0, 3'b100);
        step(1'b1, 1'b1, 1'b1, 3'b011);
        if (load_valid !== 1'b0 || access_error !== 1'b1)
            $fatal(1, "Store fallido debe diagnosticar sin generar un load");
        @(negedge clk);
        nop_flag = 1'b1;
        #1;
        if (load_valid !== 1'b0 || access_error !== 1'b0)
            $fatal(1, "Resultado o diagnostico repetido sin operacion EX");
        $display("tb_lost_handshake: PASS");
        $finish;
    end
endmodule
