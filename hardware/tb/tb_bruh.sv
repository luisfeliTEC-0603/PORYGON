module tb_bruh;

    localparam logic [1:0] JUMP_OPCODE = 2'b10;
    localparam logic [1:0] MATH_OPCODE = 2'b00;
    localparam logic [31:0] PC_BASE = 32'h0000_0100;

    logic [15:0] instruction;
    logic        is_nop;
    logic [15:0] immediate;
    logic [31:0] operand_a;
    logic [31:0] pc;
    logic [31:0] target_pc;
    logic        branch_taken;

    bruh_unit dut (
        .instruction_i(instruction),
        .is_nop_i(is_nop),
        .imm_data_i(immediate),
        .operand_a_i(operand_a),
        .pc_i(pc),
        .target_pc_o(target_pc),
        .branch_taken_o(branch_taken)
    );

    task automatic check_branch(
        input logic [1:0]  funct,
        input logic [7:0]  offset,
        input logic        use_immediate,
        input logic        expected_taken,
        input logic [31:0] expected_target,
        input string       test_name
    );
        begin
            instruction = {3'd1, offset, funct, use_immediate, JUMP_OPCODE};
            is_nop = 1'b0;
            #1;
            if (branch_taken !== expected_taken)
                $fatal(1, "FAIL %s: taken=%b esperado=%b", test_name, branch_taken, expected_taken);
            if (expected_taken && (target_pc !== expected_target))
                $fatal(1, "FAIL %s: target=0x%h esperado=0x%h", test_name, target_pc, expected_target);
            if (!expected_taken && (target_pc !== 32'h0))
                $fatal(1, "FAIL %s: target debe ser 0 sin salto, es 0x%h", test_name, target_pc);
            $display("[PASS] %s: taken=%b target=0x%h", test_name, branch_taken, target_pc);
        end
    endtask

    initial begin
        pc = PC_BASE;
        operand_a = 32'h0000_0000;
        immediate = 16'h0000;

        instruction = {3'd1, 8'd2, JUMP_J, 1'b0, JUMP_OPCODE};
        is_nop = 1'b1;
        #1;
        if ((branch_taken !== 1'b0) || (target_pc !== 32'h0))
            $fatal(1, "FAIL NOP: taken=%b target=0x%h", branch_taken, target_pc);
        $display("[PASS] NOP: no salta");

        // Saltos incondicionales con offset del slot, en bundles de 8 bytes
        check_branch(JUMP_J, 8'd2, 1'b0, 1'b1, 32'h0000_0110, "J +2 bundles");
        check_branch(JUMP_J, 8'hFE, 1'b0, 1'b1, 32'h0000_00F0, "J -2 bundles");
        check_branch(JUMP_J, 8'd0, 1'b0, 1'b1, 32'h0000_0100, "J +0 se queda en el bundle");
        check_branch(JUMP_J, 8'd127, 1'b0, 1'b1, 32'h0000_04F8, "J +127 alcance maximo");
        check_branch(JUMP_J, 8'h80, 1'b0, 1'b1, 32'hFFFF_FD00, "J -128 envuelve bajo cero");

        // Condicionales: evaluan el registro, no las banderas de estado
        operand_a = 32'h0000_0000;
        check_branch(JUMP_JZ, 8'd4, 1'b0, 1'b1, 32'h0000_0120, "JZ con registro en cero");
        check_branch(JUMP_JNZ, 8'd4, 1'b0, 1'b0, 32'h0, "JNZ con registro en cero");

        operand_a = 32'h0000_0005;
        check_branch(JUMP_JZ, 8'd4, 1'b0, 1'b0, 32'h0, "JZ con registro distinto de cero");
        check_branch(JUMP_JNZ, 8'd4, 1'b0, 1'b1, 32'h0000_0120, "JNZ con registro distinto de cero");

        operand_a = 32'h8000_0000;
        check_branch(JUMP_JNZ, 8'd1, 1'b0, 1'b1, 32'h0000_0108, "JNZ con solo el bit de signo");

        // Salto indirecto: destino absoluto, el offset se descarta
        operand_a = 32'hDEAD_BEE0;
        check_branch(JUMP_JR, 8'd127, 1'b0, 1'b1, 32'hDEAD_BEE0, "JR ignora el offset");
        check_branch(JUMP_JR, 8'd0, 1'b1, 1'b1, 32'hDEAD_BEE0, "JR ignora tambien el inmediato");

        // Variantes con inmediato de 16 bits; el campo del slot queda sin uso
        immediate = 16'd100;
        check_branch(JUMP_J, 8'hFF, 1'b1, 1'b1, 32'h0000_0420, "JI +100 bundles");

        immediate = 16'hFFF0;
        operand_a = 32'h0000_0000;
        check_branch(JUMP_JZ, 8'h00, 1'b1, 1'b1, 32'h0000_0080, "JZI -16 bundles");

        immediate = 16'h7FFF;
        check_branch(JUMP_J, 8'h00, 1'b1, 1'b1, 32'h0004_00F8, "JI inmediato positivo maximo");

        immediate = 16'h8000;
        check_branch(JUMP_J, 8'h00, 1'b1, 1'b1, 32'hFFFC_0100, "JI inmediato negativo minimo");

        // El PC de partida no esta cableado al valor de prueba
        pc = 32'h0000_2000;
        immediate = 16'h0000;
        check_branch(JUMP_J, 8'd1, 1'b0, 1'b1, 32'h0000_2008, "J desde otro PC");

        // Un slot de otro formato no debe despachar un salto
        pc = PC_BASE;
        instruction = {3'd1, 8'd2, JUMP_J, 1'b0, MATH_OPCODE};
        is_nop = 1'b0;
        #1;
        if ((branch_taken !== 1'b0) || (target_pc !== 32'h0))
            $fatal(1, "FAIL opcode ajeno: taken=%b target=0x%h", branch_taken, target_pc);
        $display("[PASS] opcode distinto de JUMP rechazado");

        $display("tb_bruh: ALL TESTS PASS");
        $finish;
    end

endmodule
