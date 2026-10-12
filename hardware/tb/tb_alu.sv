module tb_alu;

    localparam logic [1:0] MATH_OPCODE = 2'b00;

    logic [15:0] instruction;
    logic        is_nop;
    logic [15:0] immediate;
    logic [31:0] operand_a;
    logic [31:0] operand_b;
    logic [31:0] result;
    logic [2:0]  dest_addr;
    logic        write_enable;

    alu_unit dut (
        .instruction_i(instruction),
        .is_nop_i(is_nop),
        .imm_data_i(immediate),
        .operand_a_i(operand_a),
        .operand_b_i(operand_b),
        .result_o(result),
        .dest_addr_o(dest_addr),
        .write_enable_o(write_enable)
    );

    task automatic check_result(
        input logic [5:0] funct,
        input logic       use_immediate,
        input logic [31:0] expected,
        input string       test_name
    );
        begin
            instruction = {3'd1, 3'd2, funct, 1'b0, use_immediate, MATH_OPCODE};
            is_nop = 1'b0;
            #1;
            if (dest_addr !== 3'd1)
                $fatal(1, "FAIL %s: dest=%d expected=1", test_name, dest_addr);
            if ((result !== expected) || (write_enable !== 1'b1))
                $fatal(1, "FAIL %s: result=0x%h write=%b expected=0x%h", test_name, result, write_enable, expected);
            $display("[PASS] %s: result=0x%h", test_name, result);
        end
    endtask

    // Sin escritura válida, la dirección de salida debe quedar en cero.
    always @(instruction or is_nop) begin
        #1;
        if (write_enable === 1'b0 && dest_addr !== 3'd0)
            $fatal(1, "FAIL disabled writeback: dest=%d expected=0", dest_addr);
    end

    initial begin
        instruction = 16'h0000;
        is_nop = 1'b1;
        immediate = 16'h0000;
        operand_a = 32'hDEAD_BEEF;
        operand_b = 32'hCAFE_BABE;
        #1;
        if ((result !== 32'h0) || (write_enable !== 1'b0))
            $fatal(1, "FAIL NOP: result=0x%h write=%b", result, write_enable);
        $display("[PASS] NOP: no produce resultado ni writeback");

        operand_a = 32'd7;
        operand_b = 32'd5;
        check_result(MATH_SUM, 1'b0, 32'd12, "SUM 7 + 5");
        check_result(MATH_DIFF, 1'b0, 32'd2, "DIFF 7 - 5");
        check_result(MATH_AND, 1'b0, 32'h0000_0005, "AND");
        check_result(MATH_OR, 1'b0, 32'h0000_0007, "OR");
        check_result(MATH_XOR, 1'b0, 32'h0000_0002, "XOR");

        instruction = {3'd5, 3'd2, MATH_SUM, 1'b0, 1'b0, MATH_OPCODE};
        #1;
        if (result !== 32'd12 || dest_addr !== 3'd5 || write_enable !== 1'b1)
            $fatal(1, "FAIL SUM destination R5: result=0x%h dest=%d write=%b",
                   result, dest_addr, write_enable);
        $display("[PASS] SUM destination follows rs1=R5");
        is_nop = 1'b1;
        #1;
        if (dest_addr !== 3'd0 || write_enable !== 1'b0)
            $fatal(1, "FAIL NOP with destination R5");

        operand_a = 32'h0000_0000;
        check_result(MATH_NOT, 1'b0, 32'hFFFF_FFFF, "NOT zero");

        operand_a = 32'hFFFF_FFFF;
        operand_b = 32'h0000_0001;
        check_result(MATH_SUM, 1'b0, 32'h0000_0000, "SUM overflow wraps");
        check_result(MATH_DIFF, 1'b0, 32'hFFFF_FFFE, "DIFF unsigned underflow wraps");

        operand_a = 32'd20;
        immediate = 16'hFFFB;
        check_result(MATH_SUM, 1'b1, 32'd15, "SUMI 20 + (-5)");

        operand_a = 32'hFFFF_FFFF;
        immediate = 16'h8000;
        check_result(MATH_AND, 1'b1, 32'h0000_8000, "ANDI zero extension");
        check_result(MATH_OR, 1'b1, 32'hFFFF_FFFF, "ORI zero extension");
        check_result(MATH_XOR, 1'b1, 32'hFFFF_7FFF, "XORI zero extension");

        operand_a = 32'h0000_000A;
        operand_b = 32'h0000_0003;
        check_result(MATH_GTN, 1'b0, 32'd1, "GTN true");
        check_result(MATH_LTN, 1'b0, 32'd0, "LTN false");
        check_result(MATH_EOR, 1'b0, 32'd0, "EOR unequal");
        operand_b = 32'h0000_000A;
        check_result(MATH_EOR, 1'b0, 32'd1, "EOR equal");
        check_result(MATH_NEZ, 1'b0, 32'd1, "NEZ nonzero");
        operand_a = 32'h0000_0000;
        check_result(MATH_NEZ, 1'b0, 32'd0, "NEZ zero");

        // La ALU normal no debe ejecutar corrimientos ni multiplicaciones.
        operand_a = 32'd7;
        operand_b = 32'd5;
        instruction = {3'd1, 3'd2, MATH_SHL, 1'b1, 1'b0, MATH_OPCODE};
        #1;
        if ((result !== 32'h0) || (write_enable !== 1'b0))
            $fatal(1, "FAIL SHL must be rejected: result=0x%h write=%b", result, write_enable);
        $display("[PASS] SHL rejected by normal ALU");

        instruction = {3'd1, 3'd2, MATH_MUL, 1'b1, 1'b0, MATH_OPCODE};
        #1;
        if ((result !== 32'h0) || (write_enable !== 1'b0))
            $fatal(1, "FAIL MUL must be rejected: result=0x%h write=%b", result, write_enable);
        $display("[PASS] MUL rejected by normal ALU");

        instruction = {3'd1, 3'd2, MATH_SUM, 1'b0, 1'b0, 2'b01};
        #1;
        if ((result !== 32'h0) || (write_enable !== 1'b0))
            $fatal(1, "FAIL non-MATH opcode: result=0x%h write=%b", result, write_enable);
        $display("[PASS] non-MATH opcode rejected");

        $display("tb_alu: ALL TESTS PASS");
        $finish;
    end

endmodule
