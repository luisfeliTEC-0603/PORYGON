// ============================================================================
// Módulo: super_alu
// Descripción: Unidad Aritmético-Lógica Especializada (pipe = 1) para VLIW.
//              - Ejecuta operaciones básicas y desplazamientos combinacionales.
//              - Ejecuta mul/muli con una tubería explícita de dos etapas.
// ============================================================================

import pkg_vliw::*;

module super_alu #(
    parameter integer DATA_WIDTH = pkg_vliw::DATA_WIDTH // 32 bits
) (
    // Señales de reloj y reset (necesarios para el pipeline de multiplicación)
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // ------------------------------------------------------------------------
    // Entradas requeridas por la interfaz del Dispatcher
    // ------------------------------------------------------------------------
    input  logic [15:0]           instruction_i, // Instrucción completa de 16 bits del slot
    input  logic                  is_nop_i,      // Bandera de NOP 
    input  logic [15:0]           imm_data_i,    // Inmediato de 16 bits
    input  logic [DATA_WIDTH-1:0] op1_i,         // Operando 1 (rs1)
    input  logic [DATA_WIDTH-1:0] op2_i,         // Operando 2 (rs2)

    // ------------------------------------------------------------------------
    // Salidas hacia la etapa de Writeback (WB)
    // ------------------------------------------------------------------------
    output logic [DATA_WIDTH-1:0] result_o,      // Resultado de 32 bits
    output logic                  write_enable_o // Habilita la escritura en RegFile
);

    // ========================================================================
    // Extracción de campos del slot de instrucción (Formato MATH)
    // ========================================================================
    logic [5:0] funct;
    logic       imm_flag;

    assign funct    = instruction_i[9:4];
    assign imm_flag = instruction_i[2];

    // ========================================================================
    // MUX de Operando B y Extensión del Inmediato (16b -> 32b)
    // ========================================================================
    logic [DATA_WIDTH-1:0] op2_selected;

    always_comb begin
        if (imm_flag) begin
            // Extensión de ceros para operaciones lógicas bit a bit
            if (funct == 6'b000100 || funct == 6'b000101 || funct == 6'b000110) begin
                op2_selected = {16'h0000, imm_data_i}; // Zero extension
            end 
            // Extensión de signo para operaciones aritméticas y corrimientos
            else begin
                op2_selected = {{16{imm_data_i[15]}}, imm_data_i}; // Sign extension
            end
        end else begin
            op2_selected = op2_i; // Uso de registro rs2
        end
    end

    // ========================================================================
    // Lógica Combinacional: Operaciones de 1 Ciclo (ALU + Barrel Shifter)
    // ========================================================================
    logic [DATA_WIDTH-1:0] comb_result;

    always_comb begin
        case (funct)
            // Operaciones básicas ALU
            6'b000001: comb_result = op2_selected;                         // mov
            6'b000010: comb_result = op1_i + op2_selected;                 // sum / sumi
            6'b000011: comb_result = op1_i - op2_selected;                 // diff / diffi
            6'b000100: comb_result = op1_i & op2_selected;                 // and / andi
            6'b000101: comb_result = op1_i | op2_selected;                 // or / ori
            6'b000110: comb_result = op1_i ^ op2_selected;                 // xor / xori
            6'b000111: comb_result = ~op1_i;                               // not

            // Desplazamientos (Barrel Shifter - 1 Ciclo)
            6'b001000: comb_result = op1_i << op2_selected[4:0];          // shl / shli (Lógico izq)
            6'b001001: comb_result = op1_i >> op2_selected[4:0];          // shr / shri (Lógico der)
            6'b001010: comb_result = $signed(op1_i) >>> op2_selected[4:0];// sar / sari (Aritmético der)

            // Comparaciones
            6'b001100: comb_result = (op1_i > op2_selected) ? 32'd1 : 32'd0;  // gtn
            6'b001101: comb_result = (op1_i < op2_selected) ? 32'd1 : 32'd0;  // ltn
            6'b001110: comb_result = (op1_i == op2_selected) ? 32'd1 : 32'd0; // eor
            6'b001111: comb_result = (op1_i != 32'd0) ? 32'd1 : 32'd0;        // nez

            default: comb_result = '0;
        endcase
    end

    // ========================================================================
    // Pipeline de multiplicación de dos etapas
    // ========================================================================
    // EX1 captura los operandos asociados a rs1 y rs2/inmediato. El producto
    // combinacional se encuentra entre EX1 y EX2, y EX2 registra el resultado.
    // Así, mul/muli tienen latencia de dos flancos, pero pueden aceptarse a
    // razón de una instrucción por ciclo.
    logic [DATA_WIDTH-1:0] mul_op1_stage1_q;
    logic [DATA_WIDTH-1:0] mul_op2_stage1_q;
    logic                  mul_valid_stage1_q;
    logic [2*DATA_WIDTH-1:0] mul_result_stage2_q;
    logic                    mul_valid_stage2_q;

    logic is_mul_instr;
    assign is_mul_instr = (!is_nop_i) && (funct == MATH_MUL);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mul_op1_stage1_q   <= '0;
            mul_op2_stage1_q   <= '0;
            mul_valid_stage1_q <= 1'b0;
            mul_result_stage2_q <= '0;
            mul_valid_stage2_q  <= 1'b0;
        end else begin
            // EX2: producto completo firmado de 32 x 32 bits.
            mul_result_stage2_q <=
                $signed(mul_op1_stage1_q) * $signed(mul_op2_stage1_q);
            mul_valid_stage2_q <= mul_valid_stage1_q;

            // EX1: captura de los operandos de la instrucción cuyo destino
            // arquitectónico es rs1.
            if (is_mul_instr) begin
                mul_op1_stage1_q   <= op1_i;
                mul_op2_stage1_q   <= op2_selected;
                mul_valid_stage1_q <= 1'b1;
            end else begin
                mul_op1_stage1_q   <= '0;
                mul_op2_stage1_q   <= '0;
                mul_valid_stage1_q <= 1'b0;
            end
        end
    end

    // ========================================================================
    // MUX Final de Salida (Combinacional vs Multiplicador Segmentado)
    // ========================================================================
    always_comb begin
        if (mul_valid_stage2_q) begin
            result_o       = mul_result_stage2_q[DATA_WIDTH-1:0];
            write_enable_o = 1'b1;
        end
        else if (is_nop_i || is_mul_instr) begin
            result_o       = '0;
            write_enable_o = 1'b0;
        end
        else begin
            result_o       = comb_result;
            write_enable_o = (funct != MATH_NOP);
        end
    end

endmodule