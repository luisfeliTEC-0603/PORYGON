/**
 * @file l2_lookup.sv
 * @brief Comparador de tags de una fila de conjunto: detecta hit y devuelve la vía.
 *
 * @details
 *   Recibe la fila completa del conjunto (TAG y valid de todos los ways,
 *   empaquetados) y un tag buscado. Compara cada vía válida contra el tag
 *   y reporta hit_o y la vía donde coincide.
 *
 *   Se recorre de mayor a menor índice y se sobrescribe way_o en cada match,
 *   de modo que si hubiera más de una coincidencia (situación inconsistente,
 *   no esperada) gane la vía de MENOR índice.
 *
 *   Puramente combinacional y sin estado: la fila de tags la entrega
 *   `l2_tag_array`; este módulo solo compara.
 *
 * @param WAYS  Vías por conjunto.
 * @param TAG_W Ancho de tag en bits.
 * @param WAY_W Ancho de índice de vía.
 */

module l2_lookup #(
    parameter int WAYS  = 4,
    parameter int TAG_W = 4,
    parameter int WAY_W = $clog2(WAYS)
) (
    // Fila completa del conjunto
    input  logic [WAYS*TAG_W-1:0] tags_i,
    input  logic [WAYS-1:0]       valid_i,
    input  logic [TAG_W-1:0]      tag_i,

    // Resultado de la comparación
    output logic                  hit_o,
    output logic [WAY_W-1:0]      way_o
);
    always_comb begin
        hit_o = 1'b0;
        way_o = '0;
        // Recorrido descendente: el último match (menor índice) prevalece.
        for (int w = WAYS-1; w >= 0; w--) begin
            if (valid_i[w] && (tags_i[w*TAG_W +: TAG_W] == tag_i)) begin
                hit_o = 1'b1;
                way_o = w;
            end
        end
    end
endmodule
