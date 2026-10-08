import pkg_vliw::*;
// Simulacion alu, unicamente para makefile
module alu_unit #(
    parameter integer DATA_WIDTH = pkg_vliw::DATA_WIDTH
) (
    input logic [DATA_WIDTH-1:0] operand_a_i,
    input logic [DATA_WIDTH-1:0] operand_b_i,
    output logic [DATA_WIDTH-1:0] result_o
);

    always_comb begin
        result_o = operand_a_i + operand_b_i;
    end

endmodule