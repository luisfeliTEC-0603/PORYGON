/**
 * @file l2_plru.sv
 * @brief Tree-PLRU de 4 vías, 3 bits de estado por conjunto.
 *
 * @details
 *   PLRU (Pseudo-Least Recently Used) aproxima LRU con un árbol binario de
 *   bits por conjunto en lugar de contadores de edad por vía. Para 4 vías se
 *   usan 3 bits:
 *     bit0 : raíz; 1 -> víctima en {0,1}; 0 -> víctima en {2,3}.
 *     bit1 : elige entre vías 0 y 1.
 *     bit2 : elige entre vías 2 y 3.
 *
 *   La víctima se calcula combinacionalmente.
 *   El estado solo se actualiza cuando `touch_valid_i` está activo, es decir,
 *   una única vez al efectivizar la instalación (no durante el lookup).
 *   `touch` orienta los bits del camino lejos de la vía usada, de modo que la
 *   próxima consulta devuelva la vía menos recientemente usada.
 *
 *   No decide el reemplazo por sí mismo: entrega la víctima a
 *   `l2_way_select`, que aplica la prioridad vía inválida -> PLRU -> fallback.
 *
 * @param SETS  Número de conjuntos.
 * @param SET_W Ancho de índice de conjunto.
 */

module l2_plru #(
    parameter int SETS  = 128,
    parameter int SET_W = $clog2(SETS)
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic             clk_i,
    input  logic             rst_ni,

    // Consulta de víctima (combinacional, sin efectos)
    input  logic [SET_W-1:0] query_set_i,
    output logic [1:0]       victim_way_o,

    // Actualización de uso (una vez al efectivizar la instalación)
    input  logic             touch_valid_i,
    input  logic [SET_W-1:0] touch_set_i,
    input  logic [1:0]       touch_way_i
);

    // Estado PLRU por conjunto: 3 bits (árbol de 4 hojas).
    logic [2:0] bits_q [0:SETS-1];
    logic [2:0] q;

    // Víctima: recorrido del árbol según los bits.
    //   q[0]=1 -> víctima en {0,1}, elegida por ~q[1].
    //   q[0]=0 -> víctima en {2,3}, elegida por ~q[2].
    assign q = bits_q[query_set_i];
    assign victim_way_o = q[0] ? {1'b0, ~q[1]} : {1'b1, ~q[2]};

    // Actualización del camino hacia la vía usada:
    //   bit0 = way[1]; bit1 si way[1]=0; bit2 si way[1]=1.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int s = 0; s < SETS; s++) bits_q[s] <= 3'b000;
        end else if (touch_valid_i) begin
            bits_q[touch_set_i][0] <= touch_way_i[1];
            if (!touch_way_i[1]) bits_q[touch_set_i][1] <= touch_way_i[0];
            else                 bits_q[touch_set_i][2] <= touch_way_i[0];
        end
    end
endmodule
