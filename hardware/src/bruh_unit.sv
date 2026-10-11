import pkg_vliw::*;

/**
 * @brief Unidad de control de flujo (BRUH) del formato JUMP.
 *
 * @details
 * Combinacional pura: evalua la condicion del salto y calcula el PC destino.
 * El vaciado del pipeline ante un salto tomado es responsabilidad de
 * vliw_processor; aqui no hay estado ni penalizacion oculta.
 *
 * Decisiones pendientes de confirmacion por el grupo:
 *   - El offset se interpreta en bundles (OFFSET_SHIFT = 3). isa.md describe
 *     el campo como "en bundles, multiplo de 8 bytes"; leerlo en bytes dejaria
 *     los tres bits bajos sin uso y un alcance de solo +-15 bundles.
 *   - El salto relativo se mide desde el PC del bundle actual, no desde el
 *     siguiente, siguiendo la formula PC <- PC + off de isa.md.
 */

module bruh_unit #(
    parameter integer DATA_WIDTH = pkg_vliw::DATA_WIDTH,
    parameter integer ADDR_WIDTH = pkg_vliw::ADDR_WIDTH
) (
    input  logic [SLOT_WIDTH-1:0] instruction_i,
    input  logic                  is_nop_i,
    input  logic [SLOT_WIDTH-1:0] imm_data_i,
    input  logic [DATA_WIDTH-1:0] operand_a_i,
    input  logic [ADDR_WIDTH-1:0] pc_i,
    output logic [ADDR_WIDTH-1:0] target_pc_o,
    output logic                  branch_taken_o
);

    localparam int OFFSET_SHIFT = 3;
    localparam int OFFSET_WIDTH = 8;

    logic [1:0]                 funct;
    logic                       immediate;
    logic [OFFSET_WIDTH-1:0]    offset_field;
    logic [ADDR_WIDTH-1:0]      imm_extended;
    logic [ADDR_WIDTH-1:0]      off_extended;
    logic [ADDR_WIDTH-1:0]      offset_extended;
    logic [ADDR_WIDTH-1:0]      relative_target;
    logic                       condition_met;
    logic                       execute_enable;

    assign funct        = instruction_i[4:3];
    assign immediate    = instruction_i[2];
    assign offset_field = instruction_i[12:5];

    // Ambos offsets son con signo y se extienden antes de escalar a bundles
    assign imm_extended    = {{(ADDR_WIDTH-SLOT_WIDTH){imm_data_i[SLOT_WIDTH-1]}}, imm_data_i};
    assign off_extended    = {{(ADDR_WIDTH-OFFSET_WIDTH){offset_field[OFFSET_WIDTH-1]}}, offset_field};
    assign offset_extended = immediate ? imm_extended : off_extended;

    // El corrimiento escala bundles a bytes; en complemento a dos vale para ambos signos
    assign relative_target = pc_i + (offset_extended << OFFSET_SHIFT);

    always_comb begin
        condition_met = 1'b0;
        case (funct)
            JUMP_J:   condition_met = 1'b1;
            JUMP_JZ:  condition_met = (operand_a_i == '0);
            JUMP_JNZ: condition_met = (operand_a_i != '0);
            JUMP_JR:  condition_met = 1'b1;
        endcase
    end

    assign execute_enable = !is_nop_i && (instruction_i[1:0] == OPCODE_JUMP);
    assign branch_taken_o = execute_enable && condition_met;

    // jr descarta el offset: el destino absoluto llega por el registro
    always_comb begin
        if (!branch_taken_o)
            target_pc_o = '0;
        else if (funct == JUMP_JR)
            target_pc_o = operand_a_i[ADDR_WIDTH-1:0];
        else
            target_pc_o = relative_target;
    end

endmodule
