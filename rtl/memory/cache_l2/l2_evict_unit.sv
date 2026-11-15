/**
 * @file l2_evict_unit.sv
 * @brief Canal eb_push: entrega de víctima sucia de L2 al eviction buffer.
 *
 * @details
 *   Elige la operación en ST_EBOFF más antigua con l2_out_sel (lock estable)
 *   y ofrece al EB la base de la víctima (t_vbase_i), la línea leída del
 *   arreglo (rd1_data_i) y dirty=1. En el handshake (eb_push_valid_o &
 *   eb_push_ready_i) emite ev_eb para que la tabla pase a ST_WRITE; la vía
 *   queda libre para reutilizarse al instalar la nueva línea, sin esperar la
 *   escritura a memoria.
 *
 *   Solo se usa para víctimas sucias. Una víctima limpia se invalida sin
 *   pasar por aquí: el top la lleva directo a ST_WRITE sin pasar por EBOFF.
 *
 *   La línea se lee combinacionalmente del data array. El top debe cablear
 *   rd1_set_i/rd1_way_i con sel_set_o/sel_way_o para que rd1_data_i
 *   corresponda a la víctima de la operación elegida en el mismo ciclo.
 *
 *   ev_eb dura un solo ciclo, el del handshake.
 *
 * @param N     Número de operaciones en vuelo.
 * @param AW    Ancho de dirección.
 * @param LW    Ancho de línea.
 * @param WAY_W Ancho de índice de vía.
 * @param SET_W Ancho de índice de conjunto.
 * @param OPW   Ancho de índice de operación, mínimo 1.
 *
 * @input  req_eb_i     Solicitud de eb_push por operación.
 * @input  older_i      Matriz N×N de antigüedad.
 * @input  t_vbase_i    Base de la víctima por operación.
 * @input  t_way_i      Vía por operación.
 * @input  rd1_data_i   Línea leída del data array para la operación elegida.
 * @input  eb_push_ready_i 1 si el EB acepta la víctima.
 *
 * @output eb_push_valid_o 1 si hay una operación ofreciendo eb_push.
 * @output eb_push_base_o  Base de la víctima ofrecida.
 * @output eb_push_data_o  Línea de la víctima ofrecida.
 * @output eb_push_dirty_o Siempre 1: solo se empujan víctimas sucias.
 * @output ev_eb_valid_o   1 en el ciclo del handshake.
 * @output ev_eb_onehot_o  One-hot de la operación que completó eb_push.
 * @output sel_set_o       Conjunto de la víctima elegida, para cablear rd1.
 * @output sel_way_o       Vía de la víctima elegida, para cablear rd1.
 */

module l2_evict_unit #(
    parameter int N     = 4,
    parameter int AW    = 16,
    parameter int LW    = 256,
    parameter int WAY_W = 2,
    parameter int SET_W = 7,
    parameter int OPW   = (N > 1) ? $clog2(N) : 1
) (
    input  logic             clk_i,
    input  logic             rst_ni,

    // Solicitudes desde l2_op_table
    input  logic [N-1:0]     req_eb_i,
    input  logic [N*N-1:0]   older_i,
    input  logic [N*AW-1:0]  t_vbase_i,
    input  logic [N*WAY_W-1:0] t_way_i,

    // Linea leida del arreglo (por la via de la op seleccionada)
    input  logic [LW-1:0]    rd1_data_i,

    // Canal externo hacia EB
    output logic             eb_push_valid_o,
    input  logic             eb_push_ready_i,
    output pkg_memory::address_t eb_push_base_o,
    output pkg_memory::line_t    eb_push_data_o,
    output logic             eb_push_dirty_o,

    // Evento para l2_op_table (pulso de un ciclo)
    output logic             ev_eb_valid_o,
    output logic [N-1:0]     ev_eb_onehot_o,

    // Seleccion expuesta para cablear rd1 del arreglo de datos
    output logic [SET_W-1:0] sel_set_o,
    output logic [WAY_W-1:0] sel_way_o
);
    logic             sel_valid;
    logic [OPW-1:0]   sel_idx;
    logic [N-1:0]     sel_onehot;
    logic [AW-1:0]    sel_vbase;
    logic [WAY_W-1:0] sel_way;

    // Árbitro del canal con lock: mantiene la oferta estable si el EB no acepta.
    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_eb_i), .older_i(older_i),
        .ext_valid_i(eb_push_valid_o), .ext_ready_i(eb_push_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    // Descomposición de la base de la víctima: set para indexar el arreglo,
    // way para elegir la línea dentro del set.
    assign sel_vbase = t_vbase_i[sel_idx*AW +: AW];
    assign sel_way   = t_way_i[sel_idx*WAY_W +: WAY_W];

    // La base que se empuja es la de la victima (vbase), no la base de la op.
    assign eb_push_valid_o = rst_ni && sel_valid;
    assign eb_push_base_o  = sel_vbase;
    assign eb_push_data_o  = eb_push_valid_o ? rd1_data_i : '0;
    assign eb_push_dirty_o = 1'b1;

    // Handshake: único ciclo en que se emite el evento a la tabla.
    logic eb_hs;
    assign eb_hs = eb_push_valid_o && eb_push_ready_i;

    assign ev_eb_valid_o  = eb_hs;
    assign ev_eb_onehot_o = eb_hs ? sel_onehot : '0;

    // Selección expuesta para que el top cablee rd1 del data array.
    assign sel_set_o = sel_vbase[$clog2(pkg_memory::LINE_BYTES) +: SET_W];
    assign sel_way_o = sel_way;
endmodule
