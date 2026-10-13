/**
 * @brief Mantiene PC y registra la frontera IF/ID.
 *
 * @details La interfaz externa debe entregar combinacionalmente el bundle
 * del PC solicitado. En cada flanco se captura ese bundle y su PC; el PC
 * siguiente avanza ocho bytes o toma el destino BRUH. Un salto no invalida
 * IF/ID: los bundles jovenes son NOPs insertados por software.
 *
 * @input clk_i, rst_ni Reloj y reset activo bajo.
 * @input instruction_bundle_i Bundle correspondiente a instruction_address_o.
 * @input branch_taken_i, branch_target_i Decision EX aplicada en este flanco.
 * @output instruction_address_o, instruction_read_enable_o Solicitud IF.
 * @output bundle_o, bundle_pc_o, bundle_valid_o Frontera IF/ID registrada.
 * @note instruction_memory implementa este contrato combinacional. Una
 * memoria con latencia variable o respuesta sincronica no es compatible.
 */
module fetch_stage #(
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] INITIAL_PC = pkg_vliw::RESET_PC
) (
    input logic clk_i,
    input logic rst_ni,
    input logic branch_taken_i,
    input pkg_vliw::address_t branch_target_i,
    input pkg_vliw::bundle_t instruction_bundle_i,
    output pkg_vliw::address_t instruction_address_o,
    output logic instruction_read_enable_o,
    output pkg_vliw::bundle_t bundle_o,
    output pkg_vliw::address_t bundle_pc_o,
    output logic bundle_valid_o
);
    import pkg_vliw::*;
    address_t pc_q;

    assign instruction_address_o = pc_q;
    assign instruction_read_enable_o = rst_ni;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pc_q <= INITIAL_PC;
            bundle_o <= '0;
            bundle_pc_o <= INITIAL_PC;
            bundle_valid_o <= 1'b0;
        end else begin
            pc_q <= branch_taken_i ? branch_target_i : pc_q + BUNDLE_BYTES;
            bundle_o <= instruction_bundle_i;
            bundle_pc_o <= pc_q;
            bundle_valid_o <= 1'b1;
        end
    end
endmodule
