/**
 * @file l2_way_select.sv
 * @brief Elección de vía destino para una instalación.
 *
 * @details
 *   Prioridad considerando WAY == 4:
 *     1) primera vía inválida no reservada (menor índice, determinista);
 *     2) vía indicada por PLRU, si no está reservada;
 *     3) si la PLRU está reservada, ok_o=0 y la instalación espera.
 *
 *   No se elige una vía válida no-PLRU como fallback en WAYS == 4: se debe
 *   conservar la elección PLRU mientras se espera el desalojo, y evitar que
 *   dos operaciones se apropien simultáneamente de la misma vía.
 *
 *   Para WAYS != 4 no hay PLRU contractual. En ese caso, si no hay vía
 *   inválida libre, se elige la primera vía no reservada como heurística
 *   determinista; esta rama puede desalojar una línea válida sin criterio de
 *   uso y no se usa en la configuración de 4 vías.
 *
 *   Combinacional y sin estado.
 *
 * @param WAYS  Número de vías por conjunto.
 * @param WAY_W Ancho de índice de vía, $clog2(WAYS).
 */
module l2_way_select #(
    parameter int WAYS  = 4,
    parameter int WAY_W = $clog2(WAYS)
) (
    input  logic [WAYS-1:0]  valid_i,
    input  logic [WAYS-1:0]  resv_i,
    input  logic [1:0]       plru_way_i,  // árbol de 4 hojas; solo se usa si WAYS==4
    output logic [WAY_W-1:0] way_o,
    output logic             ok_o
);

    always_comb begin
        way_o = '0;
        ok_o  = 1'b0;

        // 1) Vía inválida no reservada (menor índice gana por recorrido desc.).
        for (int w = WAYS-1; w >= 0; w--) begin
            if (!valid_i[w] && !resv_i[w]) begin
                way_o = WAY_W'(w);
                ok_o  = 1'b1;
            end
        end

        // 2) WAYS==4: vía PLRU si no está reservada; si lo está, se espera.
        if (!ok_o && (WAYS == 4) && !resv_i[plru_way_i]) begin
            way_o = WAY_W'(plru_way_i);
            ok_o  = 1'b1;
        end

        // 3) WAYS!=4 sin PLRU: fallback determinista a la primera no reservada.
        if (!ok_o && (WAYS != 4)) begin
            for (int w = WAYS-1; w >= 0; w--) begin
                if (!resv_i[w]) begin
                    way_o = WAY_W'(w);
                    ok_o  = 1'b1;
                end
            end
        end
    end
endmodule
