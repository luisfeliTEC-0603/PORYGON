/**
 * @file l2_way_select.sv
 * @brief Elección de vía destino para una instalación.
 *
 * @details
 *   Selecciona la vía donde se instalará la línea de un `wb_install`.
 *
 *   Prioridad en la configuración contractual (WAYS == 4):
 *     1) primera vía inválida no reservada (menor índice, determinista);
 *     2) vía indicada por PLRU, si no está reservada;
 *     3) si la PLRU está reservada, ok_o=0 y la instalación espera.
 *
 *   En WAYS == 4 no hay fallback a una vía válida no-PLRU: la elección PLRU
 *   se conserva mientras se espera el desalojo, para no apropiarse de otra
 *   vía y para que dos operaciones no elijan la misma víctima.
 *
 *   La rama WAYS != 4 es defensiva: no hay PLRU contractual para otras
 *   geometrías, así que si no hay vía inválida libre se elige la primera no
 *   reservada. Puede desalojar una línea válida sin criterio de uso; no se
 *   usa en la configuración actual y existe solo por si se parametriza.
 *
 * @param WAYS  Número de vías por conjunto.
 * @param WAY_W Ancho de índice de vía, $clog2(WAYS).
 *
 * @input  valid_i      Bit de validez por vía de la fila del conjunto.
 * @input  resv_i       Bit de reserva por vía de la fila del conjunto.
 * @input  plru_way_i   Vía elegida por tree-PLRU; solo se consulta si WAYS==4.
 *
 * @output way_o        Vía destino elegida.
 * @output ok_o         1 si way_o es válida; 0 si la instalación debe esperar.
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

    // Prioridad combinacional: inválida libre -> PLRU libre -> (WAYS!=4) fallback.
    always_comb begin
        way_o = '0;
        ok_o  = 1'b0;

        // 1) Vía inválida no reservada. Recorrido descendente + sobrescritura:
        //    si hay varias, prevalece el último asignado, el de menor índice.
        for (int w = WAYS-1; w >= 0; w--) begin
            if (!valid_i[w] && !resv_i[w]) begin
                way_o = WAY_W'(w);
                ok_o  = 1'b1;
            end
        end

        // 2) WAYS==4: PLRU si no está reservada. Si lo está, no se busca otra
        //    vía: se conserva la elección PLRU y la instalación espera.
        if (!ok_o && (WAYS == 4) && !resv_i[plru_way_i]) begin
            way_o = WAY_W'(plru_way_i);
            ok_o  = 1'b1;
        end

        // 3) WAYS!=4: sin PLRU contractual, fallback determinista a la primera
        //    vía no reservada (puede desalojar una válida; no se usa en WAYS==4).
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
