/**
 * @file l2_lookup.sv
 * @brief Comparador de tags de una fila de conjunto: detecta hit y devuelve la vía.
 *
 * @details
 *   Recibe la fila completa del conjunto (tags y valid de todos los ways,
 *   empaquetados) y un tag buscado. Compara cada vía válida contra el tag y
 *   reporta hit_o y la vía donde coincide.
 *
 * @param WAYS  Vías por conjunto.
 * @param TAG_W Ancho de tag en bits.
 * @param WAY_W Ancho de índice de vía.
 *
 * @input  tags_i  Fila de tags del conjunto, empaquetada como WAYS segmentos de TAG_W bits.
 * @input  valid_i Bit de validez por vía de la fila.
 * @input  tag_i   Tag buscado.
 *
 * @output hit_o   Hay al menos una vía válida cuyo tag coincide con tag_i.
 * @output way_o   Vía donde coincide (menor índice si hay más de una).
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
