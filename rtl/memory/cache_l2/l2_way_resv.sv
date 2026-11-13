/**
 * @file l2_way_resv.sv
 * @brief Bits de reserva de vía por (set, way) para operaciones en vuelo.
 *
 * @details
 *   Una vía reservada queda apartada por una operación non-blocking: no puede
 *   ser elegida como destino/víctima ni acertada por otra demanda mientras la
 *   reserva esté activa. Esto evita que dos operaciones se apropien a la vez
 *   de la misma vía, sin serializar por conjunto (solo por vía).
 *
 *   Dos puertos de lectura: en un mismo ciclo, `l2_way_select` consulta las
 *   reservas del conjunto donde elige vía, y otro consumidor puede consultar
 *   las de un conjunto distinto (p. ej. el conjunto de la demanda entrante).
 *
 *   Dos puertos de clear porque la reserva se libera en dos momentos con
 *   semántica propia, posiblemente en el mismo ciclo sobre vías distintas:
 *     clr0 : al completarse un fill (línea entregada a L1).
 *     clr1 : al completarse una escritura/install (vía ya instalada).
 *
 *   Prioridad en el mismo ciclo: clr0 -> clr1 -> set. Si una vía se libera y
 *   se reserva en el mismo ciclo, prevalece `set` (queda reservada), política
 *   conservadora para no dejar libre una vía ya tomada por otra operación.
 *
 * @param SETS  Número de conjuntos.
 * @param WAYS  Vías por conjunto.
 * @param SET_W Ancho de índice de conjunto, $clog2(SETS).
 * @param WAY_W Ancho de índice de vía, $clog2(WAYS).
 */

module l2_way_resv #(
    parameter int SETS  = 128,
    parameter int WAYS  = 4,
    parameter int SET_W = $clog2(SETS),
    parameter int WAY_W = $clog2(WAYS)
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic             clk_i,
    input  logic             rst_ni,

    // Lectura A: reservas de la fila del conjunto (combinacional)
    input  logic [SET_W-1:0] rd_a_set_i,
    output logic [WAYS-1:0]  rd_a_resv_o,

    // Lectura B: reservas de la fila del conjunto (combinacional)
    input  logic [SET_W-1:0] rd_b_set_i,
    output logic [WAYS-1:0]  rd_b_resv_o,

    // Reserva de una vía
    input  logic             set_valid_i,
    input  logic [SET_W-1:0] set_set_i,
    input  logic [WAY_W-1:0] set_way_i,

    // Liberación por fill completado
    input  logic             clr0_valid_i,
    input  logic [SET_W-1:0] clr0_set_i,
    input  logic [WAY_W-1:0] clr0_way_i,

    // Liberación por escritura/install completado
    input  logic             clr1_valid_i,
    input  logic [SET_W-1:0] clr1_set_i,
    input  logic [WAY_W-1:0] clr1_way_i
);
    // Un bit de reserva por (set, way), layout lineal set*WAYS + way.
    logic resv_q [0:SETS*WAYS-1];

    // Lecturas combinacionales de la fila de reservas.
    always_comb begin
        for (int w = 0; w < WAYS; w++) begin
            rd_a_resv_o[w] = resv_q[rd_a_set_i*WAYS + w];
            rd_b_resv_o[w] = resv_q[rd_b_set_i*WAYS + w];
        end
    end

    // Estado con reset asíncrono; orden clr0 -> clr1 -> set.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int k = 0; k < SETS*WAYS; k++) resv_q[k] <= 1'b0;
        end else begin
            if (clr0_valid_i) resv_q[clr0_set_i*WAYS + clr0_way_i] <= 1'b0;
            if (clr1_valid_i) resv_q[clr1_set_i*WAYS + clr1_way_i] <= 1'b0;
            if (set_valid_i)  resv_q[set_set_i*WAYS + set_way_i]   <= 1'b1;
        end
    end
endmodule
