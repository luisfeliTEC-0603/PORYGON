/**
 * @file l2_data_array.sv
 * @brief Arreglo de datos de L2: una línea de LW bits por (set, way).
 *
 * @details
 *   Almacena SETS*WAYS líneas. El índice lineal `set*WAYS + way` coincide
 *   con el layout de `l2_tag_array`, de modo que ambos arreglos se direccionan
 *   con la misma pareja (set, way) sin traducción.
 *
 * @param SETS  Número de conjuntos. 
 * @param WAYS  Vías por conjunto.
 * @param LW    Ancho de línea en bits.
 * @param SET_W Ancho de índice de conjunto.
 * @param WAY_W Ancho de índice de vía.
 */

module l2_data_array #(
    parameter int SETS  = 128,
    parameter int WAYS  = 4,
    parameter int LW    = 256,
    parameter int SET_W = $clog2(SETS),
    parameter int WAY_W = $clog2(WAYS)
) (
    // Reloj
    input  logic             clk_i,

    // Lectura 0 (combinacional)
    input  logic [SET_W-1:0] rd0_set_i,
    input  logic [WAY_W-1:0] rd0_way_i,
    output logic [LW-1:0]    rd0_data_o,

    // Lectura 1 (combinacional)
    input  logic [SET_W-1:0] rd1_set_i,
    input  logic [WAY_W-1:0] rd1_way_i,
    output logic [LW-1:0]    rd1_data_o,

    // Escritura síncrona calificada por wr_valid_i
    input  logic             wr_valid_i,
    input  logic [SET_W-1:0] wr_set_i,
    input  logic [WAY_W-1:0] wr_way_i,
    input  logic [LW-1:0]    wr_data_i
);

    // Banco de líneas: SETS*WAYS entradas de LW bits.
    // Sin reset; la validez la gobierna el tag array.
    logic [LW-1:0] mem_q [0:SETS*WAYS-1];

    // Lecturas combinacionales directas.
    assign rd0_data_o = mem_q[rd0_set_i*WAYS + rd0_way_i];
    assign rd1_data_o = mem_q[rd1_set_i*WAYS + rd1_way_i];

    // Escritura síncrona única; wr_valid_i evita escrituras espurias.
    always_ff @(posedge clk_i) begin
        if (wr_valid_i) mem_q[wr_set_i*WAYS + wr_way_i] <= wr_data_i;
    end
endmodule
