/**
 * @brief Mantiene PC y registra los metadatos de la frontera IF/ID.
 *
 * @details La ROM registra el bundle en el mismo flanco en que este bloque
 * captura su PC y validez. El bundle se conecta directamente a ID: registrarlo
 * otra vez agregaria una etapa. El PC siguiente avanza ocho bytes o toma el
 * destino BRUH. Un salto ordinario conserva sus dos bundles de retardo.
 *
 * @input clk_i, rst_ni Reloj y reset activo bajo.
 * @input advance_i Permiso de avance: conserva PC e IF/ID cuando vale cero.
 * @input stop_i Cancela IF/ID e inhibe lecturas; prioridad sobre advance_i.
 * @input instruction_bundle_i Respuesta registrada de la lectura IF anterior.
 * @input branch_taken_i, branch_target_i Decision EX aplicada en este flanco.
 * @output instruction_address_o, instruction_read_enable_o Solicitud IF.
 * @output bundle_o, bundle_pc_o, bundle_valid_o Bundle ROM y metadatos IF/ID.
 * @note Requiere ROM sincrona de un ciclo; no admite latencia variable.
 */
module fetch_stage #(
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] INITIAL_PC = pkg_vliw::RESET_PC
) (
    input logic clk_i,
    input logic rst_ni,
    input logic advance_i,
    input logic stop_i,
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

    /**
     * @brief El mismo permiso retiene la salida ROM y sus metadatos IF/ID.
     * @details Deshabilitar solo el PC permitiria que la ROM sustituyera el
     * bundle retenido por el del PC de solicitud, desalineandolo de su PC ID.
     * stop_i invalida IF/ID con prioridad sobre avance y conserva ambos PC.
     */
    assign instruction_address_o = pc_q;
    assign instruction_read_enable_o = rst_ni && advance_i && !stop_i;
    assign bundle_o = bundle_valid_o ? instruction_bundle_i : '0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pc_q <= INITIAL_PC;
            bundle_pc_o <= INITIAL_PC;
            bundle_valid_o <= 1'b0;
        end else if (stop_i) begin
            bundle_valid_o <= 1'b0;
        end else if (advance_i) begin
            pc_q <= branch_taken_i ? branch_target_i : pc_q + BUNDLE_BYTES;
            bundle_pc_o <= pc_q;
            bundle_valid_o <= 1'b1;
        end
    end
endmodule
