/**
 * @file l2_tag_array.sv
 * @brief Arreglo de tags/valid/dirty de L2, dos lecturas y dos escrituras.
 *
 * @details
 *   Guarda por cada (set, way) el tag de TAG_W bits, el bit valid y el bit
 *   dirty. Los dos puertos de lectura devuelven la fila completa del conjunto
 *   (todos los WAYS en paralelo) para que el comparador y el selector de vía
 *   resuelvan en un solo ciclo. Los dos puertos de escritura son:
 *     - wr_*  : instalación (valid=1, tag y dirty del write).
 *     - inv_* : invalidación (valid=0, dirty=0).
 *
 * @param SETS  Número de conjuntos.
 * @param WAYS  Vías por conjunto.
 * @param TAG_W Ancho de tag en bits.
 * @param SET_W Ancho de índice de conjunto.
 * @param WAY_W Ancho de índice de vía.
 */

module l2_tag_array #(
    parameter int SETS  = 128,
    parameter int WAYS  = 4,
    parameter int TAG_W = 4,
    parameter int SET_W = $clog2(SETS),
    parameter int WAY_W = $clog2(WAYS)
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // Lectura A: fila completa del conjunto (combinacional)
    input  logic [SET_W-1:0]      rd_a_set_i,
    output logic [WAYS*TAG_W-1:0] rd_a_tag_o,
    output logic [WAYS-1:0]       rd_a_valid_o,
    output logic [WAYS-1:0]       rd_a_dirty_o,

    // Lectura B: fila completa del conjunto (combinacional)
    input  logic [SET_W-1:0]      rd_b_set_i,
    output logic [WAYS*TAG_W-1:0] rd_b_tag_o,
    output logic [WAYS-1:0]       rd_b_valid_o,
    output logic [WAYS-1:0]       rd_b_dirty_o,

    // Escritura de instalación: tag, valid=1, dirty
    input  logic                  wr_valid_i,
    input  logic [SET_W-1:0]      wr_set_i,
    input  logic [WAY_W-1:0]      wr_way_i,
    input  logic [TAG_W-1:0]      wr_tag_i,
    input  logic                  wr_dirty_i,

    // Invalidación: valid=0, dirty=0
    input  logic                  inv_valid_i,
    input  logic [SET_W-1:0]      inv_set_i,
    input  logic [WAY_W-1:0]      inv_way_i
);

    // Estado por (set, way), layout lineal set*WAYS + way (igual que data_array).
    logic [TAG_W-1:0] tag_q   [0:SETS*WAYS-1];
    logic             valid_q [0:SETS*WAYS-1];
    logic             dirty_q [0:SETS*WAYS-1];

    // Lecturas combinacionales: fila completa en paralelo.
    always_comb begin
        for (int w = 0; w < WAYS; w++) begin
            rd_a_tag_o[w*TAG_W +: TAG_W] = tag_q[rd_a_set_i*WAYS + w];
            rd_a_valid_o[w]              = valid_q[rd_a_set_i*WAYS + w];
            rd_a_dirty_o[w]              = dirty_q[rd_a_set_i*WAYS + w];
            rd_b_tag_o[w*TAG_W +: TAG_W] = tag_q[rd_b_set_i*WAYS + w];
            rd_b_valid_o[w]              = valid_q[rd_b_set_i*WAYS + w];
            rd_b_dirty_o[w]              = dirty_q[rd_b_set_i*WAYS + w];
        end
    end

    // Estado con reset asíncrono (negedge rst_ni).
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int k = 0; k < SETS*WAYS; k++) begin
                valid_q[k] <= 1'b0;
                dirty_q[k] <= 1'b0;
                tag_q[k]   <= '0;
            end
        end else begin
            if (inv_valid_i) begin
                valid_q[inv_set_i*WAYS + inv_way_i] <= 1'b0;
                dirty_q[inv_set_i*WAYS + inv_way_i] <= 1'b0;
            end
            if (wr_valid_i) begin
                tag_q[wr_set_i*WAYS + wr_way_i]   <= wr_tag_i;
                valid_q[wr_set_i*WAYS + wr_way_i] <= 1'b1;
                dirty_q[wr_set_i*WAYS + wr_way_i] <= wr_dirty_i;
            end
        end
    end
endmodule
