/**
 * @file l2_data_array.sv
 * @brief Arreglo de datos de L2: una línea de LW bits por (set, way).
 *
 * @details
 *   Almacena SETS*WAYS líneas. El índice lineal `set*WAYS + way` coincide
 *   con el layout de `l2_tag_array`, de modo que ambos arreglos se direccionan
 *   con la misma pareja (set, way) sin traducción: la vía elegida por el tag
 *   array es la misma que lee/escribe el data array.
 *
 *   Dos puertos de lectura combinacional, porque en un mismo ciclo dos canales
 *   leen líneas distintas:
 *     - rd0 : `l2_fill_unit` lee la línea de una operación en ST_FILL (hit L2
 *             que se entrega a L1).
 *     - rd1 : `l2_evict_unit` lee la línea de una operación en ST_EBOFF
 *             (víctima sucia que se entrega al EB).
 *
 *   Un puerto de escritura síncrona, usado por `l2_install_unit` en ST_WRITE:
 *   es la única operación que escribe datos en L2 (la línea que vuelve de L1).
 *
 *   Sin reset: el arreglo de datos no tiene bit de validez propio; la validez
 *   la gobierna `l2_tag_array`. Un reset limpia tags/valid/dirty pero no toca
 *   mem_q, que queda con datos obsoletos hasta que una instalación los
 *   sobrescriba.
 *
 * @param SETS  Número de conjuntos.
 * @param WAYS  Vías por conjunto.
 * @param LW    Ancho de línea en bits.
 * @param SET_W Ancho de índice de conjunto, $clog2(SETS).
 * @param WAY_W Ancho de índice de vía, $clog2(WAYS).
 *
 * @input  rd0_set_i   Conjunto de la línea a leer por el puerto 0 (fill).
 * @input  rd0_way_i   Vía de la línea a leer por el puerto 0.
 * @input  rd1_set_i   Conjunto de la línea a leer por el puerto 1 (evict).
 * @input  rd1_way_i   Vía de la línea a leer por el puerto 1.
 * @input  wr_valid_i  1 si esta instalación escribe la línea.
 * @input  wr_set_i    Conjunto de la línea a escribir.
 * @input  wr_way_i    Vía de la línea a escribir.
 * @input  wr_data_i   Línea a escribir.
 *
 * @output rd0_data_o  Línea leída por el puerto 0.
 * @output rd1_data_o  Línea leída por el puerto 1.
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

    // Banco de líneas: SETS*WAYS entradas de LW bits, layout lineal
    logic [LW-1:0] mem_q [0:SETS*WAYS-1];

    // Lecturas combinacionales: el índice lineal traduce (set, way) a la
    // entrada del banco, igual que en el tag array.
    assign rd0_data_o = mem_q[rd0_set_i*WAYS + rd0_way_i];
    assign rd1_data_o = mem_q[rd1_set_i*WAYS + rd1_way_i];

    // Escritura síncrona única; wr_valid_i evita escrituras espurias cuando
    // la selección del canal no corresponde a una operación real.
    always_ff @(posedge clk_i) begin
        if (wr_valid_i) mem_q[wr_set_i*WAYS + wr_way_i] <= wr_data_i;
    end
endmodule
