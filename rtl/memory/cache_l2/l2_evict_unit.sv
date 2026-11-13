/**
 * @file l2_evict_unit.sv
 * @brief Canal eb_push: entrega de victima sucia de L2 al eviction buffer.
 *
 * @details
 *   Selecciona la operacion en ST_EBOFF mas antigua mediante l2_out_sel con
 *   lock estable. Ofrece base de la victima (t_vbase_i), linea leida del
 *   arreglo (rd1_data_i) y dirty=1. Al handshake (eb_push_valid_o &
 *   eb_push_ready_i):
 *     - emite ev_eb para que l2_op_table pase a ST_WRITE,
 *     - la via queda libre para reutilizarse al instalar la nueva linea
 *       (no se espera la escritura a memoria, interfaces.md seccion 5).
 *
 *   Solo se usa para victimas sucias. Una victima limpia se invalida sin
 *   pasar por aqui (el top la lleva directo a ST_WRITE sin pasar por
 *   ST_EBOFF).
 *
 *   El top debe cablear rd1_set_i/rd1_way_i del arreglo de datos con las
 *   salidas sel_set_o/sel_way_o de este modulo, de modo que rd1_data_i
 *   corresponda a la victima de la operacion elegida en el mismo ciclo.
 *
 *   El pulso ev_eb dura un solo ciclo, el del handshake.
 *
 * @param N     Numero de operaciones en vuelo.
 * @param AW    Ancho de direccion.
 * @param LW    Ancho de linea.
 * @param WAY_W Ancho de via.
 * @param SET_W Ancho de conjunto.
 * @param OPW   Ancho de indice de operacion.
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

    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_eb_i), .older_i(older_i),
        .ext_valid_i(eb_push_valid_o), .ext_ready_i(eb_push_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    assign sel_vbase = t_vbase_i[sel_idx*AW +: AW];
    assign sel_way   = t_way_i[sel_idx*WAY_W +: WAY_W];

    // La base que se empuja es la de la victima (vbase), no la base de la op.
    assign eb_push_valid_o = rst_ni && sel_valid;
    assign eb_push_base_o  = sel_vbase;
    assign eb_push_data_o  = eb_push_valid_o ? rd1_data_i : '0;
    assign eb_push_dirty_o = 1'b1;

    logic eb_hs;
    assign eb_hs = eb_push_valid_o && eb_push_ready_i;

    assign ev_eb_valid_o  = eb_hs;
    assign ev_eb_onehot_o = eb_hs ? sel_onehot : '0;

    // El top cablea rd1_set_i = sel_set_o, rd1_way_i = sel_way_o.
    assign sel_set_o = sel_vbase[$clog2(pkg_memory::LINE_BYTES) +: SET_W];
    assign sel_way_o = sel_way;
endmodule
