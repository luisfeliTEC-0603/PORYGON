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
            if (funct == MATH_AND || funct == MATH_OR || funct == MATH_XOR) begin
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
            MATH_MOV: comb_result = op2_selected;                         // mov
            MATH_SUM: comb_result = op1_i + op2_selected;                 // sum / sumi
            MATH_DIFF: comb_result = op1_i - op2_selected;                 // diff / diffi
            MATH_AND: comb_result = op1_i & op2_selected;                 // and / andi
            MATH_OR: comb_result = op1_i | op2_selected;                 // or / ori
            MATH_XOR: comb_result = op1_i ^ op2_selected;                 // xor / xori
            MATH_NOT: comb_result = ~op1_i;                               // not
            MATH_SHL: comb_result = op1_i << op2_selected[4:0];          // shl / shli (Lógico izq)
            MATH_SHR: comb_result = op1_i >> op2_selected[4:0];          // shr / shri (Lógico der)
            MATH_SAR: comb_result = $signed(op1_i) >>> op2_selected[4:0];// sar / sari (Aritmético der)

            // Comparaciones
            MATH_GTN: comb_result = (op1_i > op2_selected) ? 32'd1 : 32'd0;  // gtn
            MATH_LTN: comb_result = (op1_i < op2_selected) ? 32'd1 : 32'd0;  // ltn
            MATH_EOR: comb_result = (op1_i == op2_selected) ? 32'd1 : 32'd0; // eor
            MATH_NEZ: comb_result = (op1_i != 32'd0) ? 32'd1 : 32'd0;        // nez

            default: comb_result = '0;
        endcase
    end

    // ========================================================================
    // Pipeline de multiplicación de dos etapas
    // ========================================================================
    // EX1 calcula cuatro productos parciales de 16x16. EX2 los desplaza y
    // suma para formar el producto firmado completo de 64 bits.
    localparam integer HALF_WIDTH = DATA_WIDTH / 2;

    logic signed [DATA_WIDTH-1:0] mul_op1_low_ext;
    logic signed [DATA_WIDTH-1:0] mul_op2_low_ext;
    logic signed [DATA_WIDTH-1:0] mul_op1_high_ext;
    logic signed [DATA_WIDTH-1:0] mul_op2_high_ext;
    logic        [DATA_WIDTH-1:0] mul_partial_0_d;
    logic signed [DATA_WIDTH-1:0] mul_partial_1_d;
    logic signed [DATA_WIDTH-1:0] mul_partial_2_d;
    logic signed [DATA_WIDTH-1:0] mul_partial_3_d;

    logic        [DATA_WIDTH-1:0] mul_partial_0_stage1_q;
    logic signed [DATA_WIDTH-1:0] mul_partial_1_stage1_q;
    logic signed [DATA_WIDTH-1:0] mul_partial_2_stage1_q;
    logic signed [DATA_WIDTH-1:0] mul_partial_3_stage1_q;
    logic                  mul_valid_stage1_q;
    logic signed [2*DATA_WIDTH-1:0] mul_result_stage2_d;
    logic signed [2*DATA_WIDTH-1:0] mul_result_stage2_q;
    logic                    mul_valid_stage2_q;
    logic                    mul_high_stage1_q;
    logic                    mul_high_stage2_q;

    logic is_mul_instr;
    logic is_mul_high_instr;
    assign is_mul_instr = (!is_nop_i) && ((funct == MATH_MUL) || (funct == MATH_MULH));
    assign is_mul_high_instr = (!is_nop_i) && (funct == MATH_MULH);

    always_comb begin
        mul_op1_low_ext = {{HALF_WIDTH{1'b0}}, op1_i[HALF_WIDTH-1:0]};
        mul_op2_low_ext = {{HALF_WIDTH{1'b0}}, op2_selected[HALF_WIDTH-1:0]};
        mul_op1_high_ext = {{HALF_WIDTH{op1_i[DATA_WIDTH-1]}}, op1_i[DATA_WIDTH-1:HALF_WIDTH]};
        mul_op2_high_ext = {{HALF_WIDTH{op2_selected[DATA_WIDTH-1]}}, op2_selected[DATA_WIDTH-1:HALF_WIDTH]};

        mul_partial_0_d = mul_op1_low_ext * mul_op2_low_ext;
        mul_partial_1_d = mul_op1_high_ext * mul_op2_low_ext;
        mul_partial_2_d = mul_op1_low_ext * mul_op2_high_ext;
        mul_partial_3_d = mul_op1_high_ext * mul_op2_high_ext;
    end

    always_comb begin
        mul_result_stage2_d = {{DATA_WIDTH{1'b0}}, mul_partial_0_stage1_q};
        mul_result_stage2_d = mul_result_stage2_d +
                              ($signed({{DATA_WIDTH{mul_partial_1_stage1_q[DATA_WIDTH-1]}},
                                         mul_partial_1_stage1_q}) <<< HALF_WIDTH);
        mul_result_stage2_d = mul_result_stage2_d +
                              ($signed({{DATA_WIDTH{mul_partial_2_stage1_q[DATA_WIDTH-1]}},
                                         mul_partial_2_stage1_q}) <<< HALF_WIDTH);
        mul_result_stage2_d = mul_result_stage2_d +
                              ($signed({{DATA_WIDTH{mul_partial_3_stage1_q[DATA_WIDTH-1]}},
                                         mul_partial_3_stage1_q}) <<< DATA_WIDTH);
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mul_partial_0_stage1_q <= '0;
            mul_partial_1_stage1_q <= '0;
            mul_partial_2_stage1_q <= '0;
            mul_partial_3_stage1_q <= '0;
            mul_valid_stage1_q <= 1'b0;
            mul_result_stage2_q <= '0;
            mul_valid_stage2_q  <= 1'b0;
            mul_high_stage1_q   <= 1'b0;
            mul_high_stage2_q   <= 1'b0;
        end else begin
            // EX2: desplazar y sumar los cuatro productos parciales.
            mul_result_stage2_q <= mul_result_stage2_d;
            mul_valid_stage2_q <= mul_valid_stage1_q;
            mul_high_stage2_q <= mul_high_stage1_q;

            // EX1: calcular los productos parciales de la instrucción actual.
            if (is_mul_instr) begin
                mul_partial_0_stage1_q <= mul_partial_0_d;
                mul_partial_1_stage1_q <= mul_partial_1_d;
                mul_partial_2_stage1_q <= mul_partial_2_d;
                mul_partial_3_stage1_q <= mul_partial_3_d;
                mul_valid_stage1_q <= 1'b1;
                mul_high_stage1_q  <= is_mul_high_instr;
            end else begin
                mul_partial_0_stage1_q <= '0;
                mul_partial_1_stage1_q <= '0;
                mul_partial_2_stage1_q <= '0;
                mul_partial_3_stage1_q <= '0;
                mul_valid_stage1_q <= 1'b0;
                mul_high_stage1_q  <= 1'b0;
            end
        end
    end

    // ========================================================================
    // MUX Final de Salida (Combinacional vs Multiplicador Segmentado)
    // ========================================================================
    always_comb begin
        if (mul_valid_stage2_q) begin
            if (mul_high_stage2_q)
                result_o = mul_result_stage2_q[2*DATA_WIDTH-1:DATA_WIDTH];
            else
                result_o = mul_result_stage2_q[DATA_WIDTH-1:0];
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