`timescale 1ns/1ps

/**
 * @brief Prueba retencion de resultados EX/WB y sesion CRYPTO, sin banco RF.
 * @details El entorno representa ID/EX y el control global de avance. Una
 * respuesta tardia conserva su PC, instruccion y destino al cambiar EX.
 * Una suma anterior pendiente debe sobrevivir hasta consumir esa respuesta.
 * MUL/MULH con destinos distintos se pausan en EX1, EX2 y WB; despues se
 * comprueba una operacion rapida y cancelacion por reset durante un stall.
 * Feistel y sesion se retienen durante un WRITE detenido. La sesion expira
 * tras 32 avances sin recargas; un WRITE posterior se rechaza una sola vez.
 * Preve trabajo pendiente antes de avanzar, incluido Feistel con destinos r0.
 */
module tb_load_wb;
    import pkg_vliw::*;
    localparam slot_t LOAD_SLOT =
        {3'd3, 3'd2, LOST_LOBU, 3'd3, 1'b0, OPCODE_LOST};
    localparam slot_t ALU_SLOT =
        {3'd5, 3'd2, MATH_SUM, 1'b0, 1'b0, OPCODE_MATH};
    localparam slot_t MUL_SLOT = {3'd2, 3'd1, MATH_MUL, 1'b1, 1'b0, OPCODE_MATH};
    localparam slot_t MULH_SLOT = {3'd5, 3'd1, MATH_MULH, 1'b1, 1'b0, OPCODE_MATH};
    localparam slot_t FAST_SLOT = {3'd6, 3'd1, MATH_SUM, 1'b1, 1'b0, OPCODE_MATH};
    localparam slot_t FEISTEL_SLOT = {3'd3, 3'd4, CRYPTO_FEISTEL, 2'b00, 2'b00, 1'b0, OPCODE_CRYPTO};
    localparam integer EXPECTED_AUTH_CYCLES = 32;
    localparam integer MEMORY_STALL_CYCLES = 47;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic advance = 1'b0;
    logic rsp_valid = 1'b0;
    issued_op_t lsu = '0;
    issued_op_t alu0 = '0;
    issued_op_t alu1 = '0;
    issued_op_t mul_low, mul_high, fast;
    issued_op_t crypto = '0;
    wb_channel_t load_wb, alu0_wb;
    wb_channel_t alu1_wb;
    wb_channel_t crypto_left, crypto_right;
    logic authenticated, crypto_error;
    logic work_after_advance;
    address_t crypto_pc;
    integer crypto_errors = 0;
    always #5 clk = ~clk;
    always @(posedge clk)
        if (crypto_error) crypto_errors <= crypto_errors + 1;

    execution_stage dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .alu0_i(alu0),
        .alu1_i(alu1),
        .lsu_i(lsu),
        .bruh_i('0),
        .crypto_i(crypto),
        .memory_read_data_i(32'h80FF017F),
        .advance_i(advance),
        .work_after_advance_o(work_after_advance),
        .completion_ready_i(1'b1),
        .dmem_req_ready_i(1'b1),
        .dmem_rsp_valid_i(rsp_valid),
        .dmem_rsp_error_i(1'b0),
        .load_wb_o(load_wb),
        .alu0_wb_o(alu0_wb),
        .alu1_wb_o(alu1_wb),
        .crypto_left_wb_o(crypto_left),
        .crypto_right_wb_o(crypto_right),
        .authenticated_o(authenticated),
        .access_error_o(crypto_error),
        .crypto_event_pc_o(crypto_pc)
    );

    task automatic check(input wb_channel_t expected);
        #1;
        if (load_wb !== expected)
            $fatal(1, "Canal WB recibido=%h esperado=%h", load_wb, expected);
    endtask

    /** @brief Muestra la prevision antes del flanco; no cuenta WB que termina alli. */
    task automatic expect_work(input logic expected);
        #1;
        if (work_after_advance !== expected)
            $fatal(1, "Trabajo futuro recibido=%b esperado=%b", work_after_advance, expected);
    endtask

    /** @brief Un paso real de reloj, con o sin avance del calendario VLIW. */
    task automatic step_alu1(
        input logic enable,
        input issued_op_t operation,
        input wb_channel_t expected,
        input logic expected_work
    );
        @(negedge clk);
        advance = enable;
        alu1 = operation;
        if (enable) expect_work(expected_work);
        @(posedge clk);
        #1;
        if (alu1_wb.valid !== expected.valid || (expected.valid && alu1_wb !== expected))
            $fatal(1, "SuperALU WB recibido=%h esperado=%h", alu1_wb, expected);
    endtask

    /** @brief Presenta CRYPTO retenido o aceptado; la boveda siempre recibe reloj. */
    task automatic step_crypto(
        input logic enable,
        input logic [2:0] funct,
        input logic [1:0] index,
        input word_t data,
        input address_t pc,
        input logic expected_work
    );
        @(negedge clk);
        advance = enable;
        crypto = {1'b1, {3'd3, 3'd4, funct, index, 2'b00, 1'b0, OPCODE_CRYPTO},
                  16'b0, data, 32'b0, pc};
        if (enable) expect_work(expected_work);
        @(posedge clk);
        #1;
    endtask

    initial begin
        @(negedge clk);
        rst_n = 1'b1;
        advance = 1'b1;
        alu0 = {1'b1, ALU_SLOT, 16'b0, 32'd5, 32'd7, 32'h20};
        expect_work(1'b1);
        @(posedge clk);
        #1;
        if (alu0_wb !== {1'b1, 3'd5, 32'd12, 32'h20, ALU_SLOT})
            $fatal(1, "Resultado inicial de ALU0 incorrecto");
        alu0 = '0;
        advance = 1'b0;
        lsu = {1'b1, LOAD_SLOT, 16'b0, 32'b0, DATA_BASE_ADDRESS, 32'h40};
        check('0);
        @(posedge clk);
        check('0);
        if (alu0_wb !== {1'b1, 3'd5, 32'd12, 32'h20, ALU_SLOT})
            $fatal(1, "ALU0 perdio valor o procedencia mientras EX esperaba memoria");
        @(negedge clk);
        rsp_valid = 1'b1;
        advance = 1'b1;
        check('0);
        expect_work(1'b1);
        @(posedge clk);
        check({1'b1, 3'd3, 32'h80, 32'h40, LOAD_SLOT});
        if (alu0_wb.valid !== 1'b0)
            $fatal(1, "ALU0 no libero el canal al avanzar una burbuja");
        advance = 1'b0;
        lsu = '0;
        rsp_valid = 1'b0;
        @(posedge clk);
        check({1'b1, 3'd3, 32'h80, 32'h40, LOAD_SLOT});
        rst_n = 1'b0;
        check('0);
        expect_work(1'b0);
        rst_n = 1'b1;
        advance = 1'b1;
        alu0 = {1'b1, ALU_SLOT, 16'b0, 32'd5, 32'd7, 32'h20};
        @(posedge clk);
        check('0);
        if (alu0_wb !== {1'b1, 3'd5, 32'd12, 32'h20, ALU_SLOT})
            $fatal(1, "ALU0 no reinicio despues de reset");
        advance = 1'b0;
        rst_n = 1'b0;
        #1;
        if (alu0_wb !== '0)
            $fatal(1, "Reset no cancelo ALU0 con avance deshabilitado");
        rst_n = 1'b1;
        alu0 = '0;
        mul_low = {1'b1, MUL_SLOT, 16'b0, 32'd6, 32'd7, 32'h20};
        mul_high = {1'b1, MULH_SLOT, 16'b0, 32'h80000000, 32'd1, 32'h28};
        fast = {1'b1, FAST_SLOT, 16'b0, 32'd5, 32'd7, 32'h30};
        step_alu1(1'b1, mul_low, '0, 1'b1);
        step_alu1(1'b0, mul_high, '0, 1'b1); // Producto A retenido en EX1.
        step_alu1(1'b1, mul_high, '0, 1'b1);
        step_alu1(1'b0, '0, '0, 1'b1); // Producto A en EX2 y B en EX1.
        step_alu1(1'b1, '0, {1'b1, 3'd2, 32'd42, 32'h20, MUL_SLOT}, 1'b1);
        step_alu1(1'b0, '0, {1'b1, 3'd2, 32'd42, 32'h20, MUL_SLOT}, 1'b1); // A en WB.
        step_alu1(1'b1, '0, {1'b1, 3'd5, 32'hFFFFFFFF, 32'h28, MULH_SLOT}, 1'b1);
        step_alu1(1'b1, '0, '0, 1'b0); // El producto B se consume en este flanco.
        step_alu1(1'b1, fast, {1'b1, 3'd6, 32'd12, 32'h30, FAST_SLOT}, 1'b1);
        step_alu1(1'b0, '0, {1'b1, 3'd6, 32'd12, 32'h30, FAST_SLOT}, 1'b1);
        step_alu1(1'b1, '0, '0, 1'b0);
        step_alu1(1'b1, mul_low, '0, 1'b1);
        rst_n = 1'b0;
        advance = 1'b0;
        @(posedge clk);
        #1;
        if (alu1_wb !== '0)
            $fatal(1, "Reset no cancelo SuperALU detenida");
        rst_n = 1'b1;
        repeat (3) step_alu1(1'b1, '0, '0, 1'b0);
        step_crypto(1'b1, CRYPTO_AUTH, 2'd0, 32'b0, 32'h0, 1'b1);
        step_crypto(1'b1, CRYPTO_LOPW, 2'd0, 32'hDFF0F76A, 32'h0, 1'b0);
        step_crypto(1'b1, CRYPTO_LOPW, 2'd1, 32'hA9A67018, 32'h8, 1'b0);
        step_crypto(1'b1, CRYPTO_LOPW, 2'd2, 32'hDA48DB07, 32'h10, 1'b0);
        step_crypto(1'b1, CRYPTO_LOPW, 2'd3, 32'h146317BB, 32'h18, 1'b0);
        step_crypto(1'b1, CRYPTO_AUTH, 2'd0, 32'b0, 32'h20, 1'b0);
        if (authenticated !== 1'b1)
            $fatal(1, "AUTH no abrio la sesion");
        @(negedge clk);
        crypto = {1'b1, {3'd0, 3'd0, CRYPTO_FEISTEL, 5'b0, OPCODE_CRYPTO},
                  16'b0, 32'b0, 32'b0, 32'h28};
        expect_work(1'b1);
        @(posedge clk);
        #1;
        if (crypto_left.valid || crypto_right.valid) $fatal(1, "Feistel r0 habilito RF");
        @(negedge clk);
        crypto = '0;
        expect_work(1'b0);
        step_crypto(1'b1, CRYPTO_FEISTEL, 2'd0, 32'd1, 32'h28, 1'b1);
        repeat (MEMORY_STALL_CYCLES) step_crypto(1'b0, CRYPTO_WRITE, 2'd0, 32'hDEADBEEF, 32'h30, 1'b0);
        if (authenticated !== 1'b1 || dut.u_crypto.u_key_vault.auth_timer_q !== EXPECTED_AUTH_CYCLES)
            $fatal(1, "El stall modifico la sesion o su cuenta restante");
        if (dut.u_crypto.u_key_vault.keys_q[0][0] !== 32'b0)
            $fatal(1, "WRITE retenido modifico la llave antes de avanzar");
        if (crypto_left !== {1'b1, 3'd3, 32'd0, 32'h28, FEISTEL_SLOT} ||
            crypto_right !== {1'b1, 3'd4, 32'd1, 32'h28, FEISTEL_SLOT})
            $fatal(1, "Feistel aceptado perdio resultados o procedencia durante el stall");
        step_crypto(1'b1, CRYPTO_WRITE, 2'd0, 32'hDEADBEEF, 32'h30, 1'b0);
        if (crypto_error !== 1'b0 || authenticated !== 1'b1 ||
            dut.u_crypto.u_key_vault.keys_q[0][0] !== 32'hDEADBEEF)
            $fatal(1, "WRITE autorizado no se completo al reanudar");
        @(negedge clk);
        advance = 1'b1;
        crypto = '0;
        repeat (EXPECTED_AUTH_CYCLES - 1) @(posedge clk);
        #1;
        if (authenticated !== 1'b1)
            $fatal(1, "Sesion expiro antes de 32 avances sin recargas");
        @(posedge clk);
        #1;
        if (authenticated !== 1'b0)
            $fatal(1, "Sesion no expiro al completar 32 avances sin recargas");
        step_crypto(1'b1, CRYPTO_WRITE, 2'd0, 32'hDEADBEEF, 32'h30, 1'b1);
        if (crypto_error !== 1'b1 || crypto_left.valid || crypto_right.valid)
            $fatal(1, "WRITE no se rechazo con la autorizacion vigente al reanudar");
        @(negedge clk);
        advance = 1'b0;
        crypto = '0;
        repeat (2) @(posedge clk);
        #1;
        if (crypto_error !== 1'b0 || crypto_errors !== 0 || crypto_pc !== 32'h30)
            $fatal(1, "Diagnostico pendiente emitido durante stall");
        @(negedge clk);
        advance = 1'b1;
        expect_work(1'b0);
        repeat (2) @(posedge clk);
        #1;
        if (crypto_errors !== 1 || crypto_error !== 1'b0)
            $fatal(1, "Diagnostico CRYPTO perdido o repetido al reanudar");
        step_crypto(1'b1, CRYPTO_WRITE, 2'd0, 32'hDEADBEEF, 32'h38, 1'b1);
        advance = 1'b0;
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        if (dut.u_crypto.access_error_o !== 1'b0 || authenticated !== 1'b0)
            $fatal(1, "Reset no cancelo CRYPTO detenida con diagnostico pendiente");
        $display("tb_load_wb: PASS");
        $finish;
    end
endmodule
