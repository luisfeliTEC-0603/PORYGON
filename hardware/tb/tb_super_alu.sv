`timescale 1ns/1ps

import pkg_vliw::*;

module tb_super_alu;

    // ------------------------------------------------------------------------
    // Señales de prueba (DUT Inputs & Outputs)
    // ------------------------------------------------------------------------
    logic        clk_i;
    logic        rst_ni;
    logic [15:0] instruction_i;
    logic        is_nop_i;
    logic [15:0] imm_data_i;
    logic [31:0] op1_i;
    logic [31:0] op2_i;

    logic [31:0] result_o;
    logic        write_enable_o;
    integer     cycle_count;

    // ------------------------------------------------------------------------
    // Instancia de la Super ALU (Device Under Test - DUT)
    // ------------------------------------------------------------------------
    super_alu #(
        .DATA_WIDTH(32)
    ) dut (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .instruction_i (instruction_i),
        .is_nop_i       (is_nop_i),
        .imm_data_i     (imm_data_i),
        .op1_i          (op1_i),
        .op2_i          (op2_i),
        .result_o       (result_o),
        .write_enable_o (write_enable_o)
    );

    // ------------------------------------------------------------------------
    // Generación de Reloj (Periodo = 10ns -> 100 MHz)
    // ------------------------------------------------------------------------
    always #5 clk_i = ~clk_i;

    always @(posedge clk_i) begin
        cycle_count = cycle_count + 1;
        #1;
        $display("[CICLO %0d | t=%0t] rst_n=%b nop=%b instr=0x%h funct=0x%h imm=0x%h op1=0x%h op2=0x%h result=0x%h write=%b",
                 cycle_count, $time, rst_ni, is_nop_i, instruction_i,
                 instruction_i[9:4], imm_data_i, op1_i, op2_i,
                 result_o, write_enable_o);
    end

    // ------------------------------------------------------------------------
    // Secuencia de Pruebas
    // ------------------------------------------------------------------------
    initial begin
        // Configuración para GTKWave
        $dumpfile("waveform_super_alu.vcd");
        $dumpvars(0, tb_super_alu);

        // Inicialización de señales
        clk_i         = 0;
        rst_ni        = 0;
        cycle_count   = 0;
        instruction_i = '0;
        is_nop_i      = 1'b1;
        imm_data_i    = '0;
        op1_i         = '0;
        op2_i         = '0;

        // Reset del sistema
        #12;
        rst_ni = 1;
        #8;

        $display("\n==================================================");
        $display("INICIANDO PRUEBAS DE SUPER ALU (Icarus Verilog)");
        $display("==================================================");

        // --------------------------------------------------------------------
        // PRUEBA 1: NOP real. Debe ser la primera instruccion revisada.
        // --------------------------------------------------------------------
        instruction_i = 16'h0000;
        is_nop_i      = 1'b1;
        imm_data_i    = 16'h0000;
        op1_i         = 32'hDEAD_BEEF;
        op2_i         = 32'hCAFE_BABE;
        #1;

        if (result_o == 32'h0000_0000 && write_enable_o == 1'b0)
            $display("[PASS] PRUEBA 1: NOP no produce resultado ni habilita writeback");
        else
            $display("[FAIL] PRUEBA 1: NOP produjo result=0x%h write=%b", result_o, write_enable_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 2: Suma Básica en Registro (sum r1, r2) -> Latencia 1 ciclo
        // --------------------------------------------------------------------
        // Formato MATH: rs1=1, rs2=2, funct=000010 (sum), pipe=1, imm=0, opcode=00
        instruction_i = {3'd1, 3'd2, 6'b000010, 1'b1, 1'b0, 2'b00};
        is_nop_i      = 1'b0;
        op1_i         = 32'd15;
        op2_i         = 32'd25;
        #1; // Pequeño retardo combinacional
        
        if (result_o == 32'd40 && write_enable_o == 1'b1)
            $display("[PASS] PRUEBA 2: Suma combinacional 15 + 25 = %d (1 ciclo)", result_o);
        else
            $display("[FAIL] PRUEBA 2: Esperado 40, Obtenido %d", result_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 3: Suma con Inmediato Negativo (sumi r1, #-5) -> Extensión Signo
        // --------------------------------------------------------------------
        // imm_flag = 1
        instruction_i = {3'd1, 3'd0, 6'b000010, 1'b1, 1'b1, 2'b00};
        imm_data_i    = 16'hFFFB; // -5 en 16 bits (complemento a 2)
        op1_i         = 32'd20;
        #1;

        if (result_o == 32'd15) // 20 + (-5) = 15
            $display("[PASS] PRUEBA 3: Suma con Inmediato negativo (20 + -5) = %d (Sign Ext)", result_o);
        else
            $display("[FAIL] PRUEBA 3: Esperado 15, Obtenido %d", result_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 4: AND con Inmediato (andi r1, #0x8000) -> Extensión Ceros
        // --------------------------------------------------------------------
        // funct = 000100 (and), imm_flag = 1
        instruction_i = {3'd1, 3'd0, 6'b000100, 1'b1, 1'b1, 2'b00};
        imm_data_i    = 16'h8000; 
        op1_i         = 32'hFFFF_FFFF;
        #1;

        if (result_o == 32'h0000_8000) // Se extiende con ceros
            $display("[PASS] PRUEBA 4: ANDI con Extensión de Ceros = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 4: Esperado 0x00008000, Obtenido 0x%h", result_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 5: Multiplicación Segmentada (mul r1, r2) -> Latencia 2 Ciclos
        // --------------------------------------------------------------------
        // funct = 001011 (mul), imm_flag = 0
        instruction_i = {3'd1, 3'd2, 6'b001011, 1'b1, 1'b0, 2'b00};
        op1_i         = 32'd6;
        op2_i         = 32'd7;
        #1;

        // Verificación en Ciclo EX1: Todavía NO debe salir el resultado
        if (result_o != 32'd42)
            $display("[PASS] PRUEBA 5a: En Ciclo EX1 el resultado aún no está listo (result_o != 42)");
        else
            $display("[FAIL] PRUEBA 5a: El resultado no debió salir en el primer ciclo");

        // EX1 captura los operandos; el siguiente flanco completa EX2.
        @(posedge clk_i);
        #1;

        if (write_enable_o == 1'b0)
            $display("[PASS] PRUEBA 5b: EX1 aún no habilita el writeback");
        else
            $display("[FAIL] PRUEBA 5b: El resultado no debe estar listo tras EX1");

        @(posedge clk_i);
        #1;

        if (result_o == 32'd42 && write_enable_o == 1'b1)
            $display("[PASS] PRUEBA 5c: EX2 Multiplicación 6 * 7 = %d (rs1)", result_o);
        else
            $display("[FAIL] PRUEBA 5c: Esperado 42 en EX2, Obtenido %d", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 5d: Multiplicacion pequena paso a paso (6 * 9 = 54).
        // EX1 calcula p0=6*9=54 y p1=p2=p3=0; EX2 combina los parciales.
        // --------------------------------------------------------------------
        is_nop_i = 1'b1;
        repeat (2) @(posedge clk_i);
        instruction_i = {3'd1, 3'd2, 6'b001011, 1'b1, 1'b0, 2'b00};
        is_nop_i = 1'b0;
        op1_i = 32'd6;
        op2_i = 32'd9;
        @(posedge clk_i);
        #1;
        if (write_enable_o == 1'b0)
            $display("[PASS] PRUEBA 5d-EX1: 6 * 9 aun no tiene writeback");
        else
            $display("[FAIL] PRUEBA 5d-EX1: writeback prematuro, result=0x%h", result_o);
        @(posedge clk_i);
        #1;
        if (result_o == 32'd54 && write_enable_o == 1'b1)
            $display("[PASS] PRUEBA 5d-EX2: 6 * 9 = %d", result_o);
        else
            $display("[FAIL] PRUEBA 5d-EX2: esperado 54, obtenido %d", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 5e: Productos parciales no nulos en ambas mitades.
        // 0x00010002 * 0x00030004 = 0x0003000a0008.
        // --------------------------------------------------------------------
        instruction_i = {3'd1, 3'd2, 6'b001011, 1'b1, 1'b0, 2'b00};
        op1_i = 32'h0001_0002;
        op2_i = 32'h0003_0004;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'h000a_0008 && write_enable_o == 1'b1)
            $display("[PASS] PRUEBA 5e: productos parciales, low=0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 5e: esperado low=0x000a0008, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 6: Corrimientos y casos limite de 32 bits.
        // --------------------------------------------------------------------
        // Se drena el resultado pendiente de la multiplicacion anterior.
        is_nop_i = 1'b1;
        repeat (2) @(posedge clk_i);
        is_nop_i = 1'b0;
        instruction_i = {3'd1, 3'd2, 6'b001000, 1'b1, 1'b0, 2'b00};
        op1_i = 32'h0000_0001;
        op2_i = 32'd31;
        #1;
        if (result_o == 32'h8000_0000 && write_enable_o)
            $display("[PASS] PRUEBA 6a: SHL 1 << 31 = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 6a: SHL esperado 0x80000000, obtenido 0x%h", result_o);

        instruction_i = {3'd1, 3'd2, 6'b001001, 1'b1, 1'b0, 2'b00};
        op1_i = 32'hFFFF_FFFF;
        op2_i = 32'd31;
        #1;
        if (result_o == 32'h0000_0001 && write_enable_o)
            $display("[PASS] PRUEBA 6b: SHR 0xffffffff >> 31 = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 6b: SHR esperado 0x00000001, obtenido 0x%h", result_o);

        instruction_i = {3'd1, 3'd2, 6'b001010, 1'b1, 1'b0, 2'b00};
        op1_i = 32'h8000_0000;
        op2_i = 32'd31;
        #1;
        if (result_o == 32'hFFFF_FFFF && write_enable_o)
            $display("[PASS] PRUEBA 6c: SAR 0x80000000 >>> 31 = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 6c: SAR esperado 0xffffffff, obtenido 0x%h", result_o);

        instruction_i = {3'd1, 3'd2, 6'b001000, 1'b1, 1'b1, 2'b00};
        imm_data_i = 16'd0;
        op1_i = 32'hA5A5_5A5A;
        #1;
        if (result_o == 32'hA5A5_5A5A && write_enable_o)
            $display("[PASS] PRUEBA 6d: SHLI con desplazamiento 0 conserva el valor");
        else
            $display("[FAIL] PRUEBA 6d: SHLI esperado 0xA5A55A5A, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 7: Multiplicacion 32x32, parte baja y overflow.
        // --------------------------------------------------------------------
        instruction_i = {3'd1, 3'd2, 6'b001011, 1'b1, 1'b0, 2'b00};
        imm_data_i = 16'h0000;
        op1_i = 32'hFFFF_FFFF;
        op2_i = 32'hFFFF_FFFF;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'h0000_0001 && write_enable_o)
            $display("[PASS] PRUEBA 7: MUL signed(-1) * signed(-1), low = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 7: MUL esperado 0x00000001, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 8: MULH 32x32, parte alta firmada.
        // --------------------------------------------------------------------
        instruction_i = {3'd1, 3'd2, 6'b010000, 1'b1, 1'b0, 2'b00};
        op1_i = 32'h8000_0000;
        op2_i = 32'h0000_0001;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'hFFFF_FFFF && write_enable_o)
            $display("[PASS] PRUEBA 8: MULH 0x80000000 * 1, high = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 8: MULH esperado 0xffffffff, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 9: MULI con inmediato de 16 bits extendido con signo.
        // --------------------------------------------------------------------
        instruction_i = {3'd1, 3'd0, 6'b001011, 1'b1, 1'b1, 2'b00};
        imm_data_i = 16'hFFFF;
        op1_i = 32'h8000_0000;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'h8000_0000 && write_enable_o)
            $display("[PASS] PRUEBA 9: MULI 0x80000000 * -1, low = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 9: MULI esperado 0x80000000, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 10: MULHI con inmediato positivo y parte alta no cero.
        // --------------------------------------------------------------------
        instruction_i = {3'd1, 3'd0, 6'b010000, 1'b1, 1'b1, 2'b00};
        imm_data_i = 16'h7FFF;
        op1_i = 32'h7FFF_FFFF;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'h0000_3FFF && write_enable_o)
            $display("[PASS] PRUEBA 10: MULHI 0x7fffffff * 0x7fff, high = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 10: MULHI esperado 0x00003fff, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 11: MULHI con inmediato positivo y producto negativo.
        // --------------------------------------------------------------------
        imm_data_i = 16'h0001;
        op1_i = 32'h8000_0000;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'hFFFF_FFFF && write_enable_o)
            $display("[PASS] PRUEBA 11: MULHI 0x80000000 * 1, high = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 11: MULHI esperado 0xffffffff, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 12: MULHI con inmediato negativo y extensión de signo.
        // --------------------------------------------------------------------
        imm_data_i = 16'hFFFF;
        op1_i = 32'h0000_0001;
        @(posedge clk_i);
        @(posedge clk_i);
        #1;
        if (result_o == 32'hFFFF_FFFF && write_enable_o)
            $display("[PASS] PRUEBA 12: MULHI 1 * -1, high = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 12: MULHI esperado 0xffffffff, obtenido 0x%h", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 13: Inserción de NOP después de una operación
        // --------------------------------------------------------------------
        is_nop_i = 1'b1;
        // El resultado de MUL sigue visible durante el ciclo de writeback y
        // se limpia en el flanco siguiente. Se esperan dos flancos para
        // comprobar el NOP sin ese resultado pendiente.
        repeat (2) @(posedge clk_i);
        #1;
        if (write_enable_o == 1'b0)
            $display("[PASS] PRUEBA 13: NOP deshabilita escritura en banco de registros correctamente");
        else
            $display("[FAIL] PRUEBA 13: NOP habilitó escritura en banco de registros");

        #20;
        $display("==================================================");
        $display("PRUEBAS FINALIZADAS EXITOSAMENTE");
        $display("==================================================\n");
        $finish;
    end

endmodule