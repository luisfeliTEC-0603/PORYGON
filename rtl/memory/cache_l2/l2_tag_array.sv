/**
 * @file l2_tag_array.sv
 * @brief Arreglo de tags/valid/dirty de L2, dos lecturas y dos escrituras.
 *
 * @details
 *   Guarda por cada (set, way) el tag de TAG_W bits, el bit valid y el bit
 *   dirty. Las dos lecturas son combinacionales y devuelven la fila completa
 *   del conjunto (todos los WAYS en paralelo) para que el comparador
 *   (`l2_lookup`) y el selector de vía (`l2_way_select`) resuelvan en un solo
 *   ciclo: un puerto para el conjunto de la demanda, otro para el del install.
 *
 *   Las dos escrituras son síncronas y calificadas por su valid:
 *     - wr_*  : instalación. Escribe tag, pone valid=1 y fija dirty.
 *     - inv_* : invalidación. Pone valid=0 y dirty=0; no toca el tag, que
 *               queda como dato obsoleto hasta la próxima instalación.
 *
 *   Si wr_* e inv_* coinciden en (set, way) en el mismo ciclo, wr_* prevalece
 *   porque se evalúa después en el mismo always_ff. En la práctica no ocurre:
 *   install e invalidation no compiten por la misma vía en el mismo ciclo.
 *
 * @param SETS  Número de conjuntos.
 * @param WAYS  Vías por conjunto.
 * @param TAG_W Ancho de tag en bits.
 * @param SET_W Ancho de índice de conjunto, $clog2(SETS).
 * @param WAY_W Ancho de índice de vía, $clog2(WAYS).
 *
 * @input  rd_a_set_i      Conjunto cuya fila se lee por el puerto A.
 * @input  rd_b_set_i      Conjunto cuya fila se lee por el puerto B.
 * @input  wr_valid_i      1 si esta instalación escribe tag/valid/dirty.
 * @input  wr_set_i        Conjunto de la vía a instalar.
 * @input  wr_way_i        Vía a instalar.
 * @input  wr_tag_i        Tag a escribir.
 * @input  wr_dirty_i      Dirty a escribir.
 * @input  inv_valid_i     1 si esta invalidación pone valid=0/dirty=0.
 * @input  inv_set_i       Conjunto de la vía a invalidar.
 * @input  inv_way_i       Vía a invalidar.
 *
 * @output rd_a_tag_o      Fila de tags del conjunto rd_a_set_i, empaquetada.
 * @output rd_a_valid_o    Bit de validez por vía del conjunto rd_a_set_i.
 * @output rd_a_dirty_o    Bit de dirty por vía del conjunto rd_a_set_i.
 * @output rd_b_tag_o      Fila de tags del conjunto rd_b_set_i, empaquetada.
 * @output rd_b_valid_o    Bit de validez por vía del conjunto rd_b_set_i.
 * @output rd_b_dirty_o    Bit de dirty por vía del conjunto rd_b_set_i.
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

    // Estado por (set, way), layout lineal set*WAYS + way. Es el mismo layout
    // que usa el data array, así que (set, way) indexa ambos sin traducción.
    logic [TAG_W-1:0] tag_q   [0:SETS*WAYS-1];
    logic             valid_q [0:SETS*WAYS-1];
    logic             dirty_q [0:SETS*WAYS-1];

    // Lecturas combinacionales: cada puerto devuelve la fila completa del
    // conjunto pedido en paralelo, para que comparación y selección de vía
    // ocurran en el mismo ciclo.
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

    // Estado con reset asíncrono. Las dos escrituras se evalúan en el mismo
    // always_ff; si coinciden en (set, way), wr_* sobrescribe a inv_*.
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
