import pkg_vliw::*;

module alu_unit #(
    parameter integer DATA_WIDTH = pkg_vliw::DATA_WIDTH
) (
    input logic [SLOT_WIDTH-1:0] instruction_i,
    input logic                  is_nop_i,
    input logic [SLOT_WIDTH-1:0] imm_data_i,
    input logic [DATA_WIDTH-1:0] operand_a_i,
    input logic [DATA_WIDTH-1:0] operand_b_i,
    output logic [DATA_WIDTH-1:0] result_o,
    output logic [2:0]            dest_addr_o,
    output logic                  write_enable_o
);

    logic [5:0] funct;
    logic       immediate;
    logic [DATA_WIDTH-1:0] operand_b_selected;
    logic [DATA_WIDTH-1:0] comb_result;
    logic                   is_normal_funct;
    logic                   execute_enable;

    assign funct = instruction_i[9:4];
    assign immediate = instruction_i[2];

    always_comb begin
        if (immediate && ((funct == MATH_AND) || (funct == MATH_OR) || (funct == MATH_XOR)))
            operand_b_selected = {{(DATA_WIDTH-SLOT_WIDTH){1'b0}}, imm_data_i};
        else if (immediate)
            operand_b_selected = {{(DATA_WIDTH-SLOT_WIDTH){imm_data_i[SLOT_WIDTH-1]}}, imm_data_i};
        else
            operand_b_selected = operand_b_i;
    end

    always_comb begin
        case (funct)
            MATH_MOV:  comb_result = operand_b_selected;
            MATH_SUM:  comb_result = operand_a_i + operand_b_selected;
            MATH_DIFF: comb_result = operand_a_i - operand_b_selected;
            MATH_AND:  comb_result = operand_a_i & operand_b_selected;
            MATH_OR:   comb_result = operand_a_i | operand_b_selected;
            MATH_XOR:  comb_result = operand_a_i ^ operand_b_selected;
            MATH_NOT:  comb_result = ~operand_a_i;
            MATH_GTN:  comb_result = (operand_a_i > operand_b_selected) ? 32'd1 : 32'd0;
            MATH_LTN:  comb_result = (operand_a_i < operand_b_selected) ? 32'd1 : 32'd0;
            MATH_EOR:  comb_result = (operand_a_i == operand_b_selected) ? 32'd1 : 32'd0;
            MATH_NEZ:  comb_result = (operand_a_i != '0) ? 32'd1 : 32'd0;
            default:   comb_result = '0;
        endcase
    end

    assign is_normal_funct = (funct == MATH_MOV) ||
                             (funct == MATH_SUM) ||
                             (funct == MATH_DIFF) ||
                             (funct == MATH_AND) ||
                             (funct == MATH_OR) ||
                             (funct == MATH_XOR) ||
                             (funct == MATH_NOT) ||
                             (funct == MATH_GTN) ||
                             (funct == MATH_LTN) ||
                             (funct == MATH_EOR) ||
                             (funct == MATH_NEZ);

    assign execute_enable = !is_nop_i &&
                            (instruction_i[1:0] == OPCODE_MATH) &&
                            is_normal_funct;
    assign result_o = execute_enable ? comb_result : '0;
    // En formato MATH, rs1 también es el destino. Esta ALU es combinacional.
    assign dest_addr_o = execute_enable ? instruction_i[15:13] : '0;
    assign write_enable_o = execute_enable;

endmodule
