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
        // PRUEBA 1: Suma Básica en Registro (sum r1, r2) -> Latencia 1 ciclo
        // --------------------------------------------------------------------
        // Formato MATH: rs1=1, rs2=2, funct=000010 (sum), pipe=1, imm=0, opcode=00
        instruction_i = {3'd1, 3'd2, 6'b000010, 1'b1, 1'b0, 2'b00};
        is_nop_i      = 1'b0;
        op1_i         = 32'd15;
        op2_i         = 32'd25;
        #1; // Pequeño retardo combinacional
        
        if (result_o == 32'd40 && write_enable_o == 1'b1)
            $display("[PASS] PRUEBA 1: Suma combinacional 15 + 25 = %d (1 ciclo)", result_o);
        else
            $display("[FAIL] PRUEBA 1: Esperado 40, Obtenido %d", result_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 2: Suma con Inmediato Negativo (sumi r1, #-5) -> Extensión Signo
        // --------------------------------------------------------------------
        // imm_flag = 1
        instruction_i = {3'd1, 3'd0, 6'b000010, 1'b1, 1'b1, 2'b00};
        imm_data_i    = 16'hFFFB; // -5 en 16 bits (complemento a 2)
        op1_i         = 32'd20;
        #1;

        if (result_o == 32'd15) // 20 + (-5) = 15
            $display("[PASS] PRUEBA 2: Suma con Inmediato negativo (20 + -5) = %d (Sign Ext)", result_o);
        else
            $display("[FAIL] PRUEBA 2: Esperado 15, Obtenido %d", result_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 3: AND con Inmediato (andi r1, #0x8000) -> Extensión Ceros
        // --------------------------------------------------------------------
        // funct = 000100 (and), imm_flag = 1
        instruction_i = {3'd1, 3'd0, 6'b000100, 1'b1, 1'b1, 2'b00};
        imm_data_i    = 16'h8000; 
        op1_i         = 32'hFFFF_FFFF;
        #1;

        if (result_o == 32'h0000_8000) // Se extiende con ceros
            $display("[PASS] PRUEBA 3: ANDI con Extensión de Ceros = 0x%h", result_o);
        else
            $display("[FAIL] PRUEBA 3: Esperado 0x00008000, Obtenido 0x%h", result_o);

        #9;

        // --------------------------------------------------------------------
        // PRUEBA 4: Multiplicación Segmentada (mul r1, r2) -> Latencia 2 Ciclos
        // --------------------------------------------------------------------
        // funct = 001011 (mul), imm_flag = 0
        instruction_i = {3'd1, 3'd2, 6'b001011, 1'b1, 1'b0, 2'b00};
        op1_i         = 32'd6;
        op2_i         = 32'd7;
        #1;

        // Verificación en Ciclo EX1: Todavía NO debe salir el resultado
        if (result_o != 32'd42)
            $display("[PASS] PRUEBA 4a: En Ciclo EX1 el resultado aún no está listo (result_o != 42)");
        else
            $display("[FAIL] PRUEBA 4a: El resultado no debió salir en el primer ciclo");

        // EX1 captura los operandos; el siguiente flanco completa EX2.
        @(posedge clk_i);
        #1;

        if (write_enable_o == 1'b0)
            $display("[PASS] PRUEBA 4b: EX1 aún no habilita el writeback");
        else
            $display("[FAIL] PRUEBA 4b: El resultado no debe estar listo tras EX1");

        @(posedge clk_i);
        #1;

        if (result_o == 32'd42 && write_enable_o == 1'b1)
            $display("[PASS] PRUEBA 4c: EX2 Multiplicación 6 * 7 = %d (rs1)", result_o);
        else
            $display("[FAIL] PRUEBA 4c: Esperado 42 en EX2, Obtenido %d", result_o);

        // --------------------------------------------------------------------
        // PRUEBA 5: Inserción de NOP
        // --------------------------------------------------------------------
        is_nop_i = 1'b1;
        #1;
        if (write_enable_o == 1'b0)
            $display("[PASS] PRUEBA 5: NOP deshabilita escritura en banco de registros correctamente");

        #20;
        $display("==================================================");
        $display("PRUEBAS FINALIZADAS EXITOSAMENTE");
        $display("==================================================\n");
        $finish;
    end

endmodule