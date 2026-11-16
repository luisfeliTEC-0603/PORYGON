/**
 * @file l2_fill_unit.sv
 * @brief Canal l2_fill: entrega de hit L2 a L1 con exclusividad.
 *
 * @details
 *   Elige la operación en ST_FILL más antigua con l2_out_sel (lock estable) y
 *   ofrece a L1 su id, base, línea y dirty. En el handshake
 *   (l2_fill_valid_o & l2_fill_ready_i) se aplican tres efectos en el mismo
 *   flanco: invalida la vía en L2 (exclusividad: la línea pasa a L1), libera
 *   la reserva de la vía y emite ev_fill para que la tabla pase a IDLE.
 *
 *   No instala copia en L2 y no genera error: el error de memoria viaja por
 *   line_return del top, no por este canal.
 *
 *   inv_*, resv_clr_* y ev_fill_* duran un solo ciclo, el del handshake; el
 *   consumidor los trata como eventos, no como niveles.
 *
 * @param N     Número de operaciones en vuelo.
 * @param AW    Ancho de dirección.
 * @param LW    Ancho de línea.
 * @param WAY_W Ancho de índice de vía.
 * @param SET_W Ancho de índice de conjunto.
 * @param OPW   Ancho de índice de operación, mínimo 1.
 *
 * @input  req_fill_i    Solicitud de fill por operación.
 * @input  older_i       Matriz NxN de antigüedad.
 * @input  t_base_i      Base por operación.
 * @input  t_way_i       Vía por operación.
 * @input  t_dirty_i     Dirty por operación.
 * @input  rd0_data_i    Línea leída del data array para la operación elegida.
 * @input  l2_fill_ready_i 1 si L1 acepta la entrega.
 *
 * @output l2_fill_valid_o 1 si hay una operación ofreciendo fill.
 * @output l2_fill_id_o    Índice de la operación ofrecida.
 * @output l2_fill_base_o  Base de la operación ofrecida.
 * @output l2_fill_data_o  Línea de la operación ofrecida.
 * @output l2_fill_dirty_o Dirty de la operación ofrecida.
 * @output l2_fill_error_o Siempre 0; el error viaja por line_return.
 * @output ev_fill_valid_o 1 en el ciclo del handshake.
 * @output ev_fill_onehot_o One-hot de la operación que completó fill.
 * @output inv_valid_o     1 en el ciclo del handshake (invalidar en L2).
 * @output inv_set_o       Conjunto a invalidar.
 * @output inv_way_o       Vía a invalidar.
 * @output resv_clr_valid_o 1 en el ciclo del handshake (liberar reserva).
 * @output resv_clr_set_o  Conjunto de la reserva a liberar.
 * @output resv_clr_way_o  Vía de la reserva a liberar.
 * @output sel_set_o       Conjunto de la operación elegida, para cablear rd0.
 * @output sel_way_o       Vía de la operación elegida, para cablear rd0.
 */

module l2_fill_unit #(
    parameter int N     = 4,
    parameter int AW    = 16,
    parameter int LW    = 256,
    parameter int WAY_W = 2,
    parameter int SET_W = 7,
    parameter int OPW   = (N > 1) ? $clog2(N) : 1
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic             clk_i,
    input  logic             rst_ni,

    // Solicitudes desde la tabla de operaciones
    input  logic [N-1:0]     req_fill_i,
    input  logic [N*N-1:0]   older_i,
    input  logic [N*AW-1:0]  t_base_i,
    input  logic [N*WAY_W-1:0] t_way_i,
    input  logic [N-1:0]     t_dirty_i,

    // Línea leída del arreglo de datos (el top la cablea con sel_set_o/sel_way_o)
    input  logic [LW-1:0]    rd0_data_i,

    // Canal externo hacia L1
    output logic             l2_fill_valid_o,
    input  logic             l2_fill_ready_i,
    output logic [OPW-1:0]   l2_fill_id_o,
    output pkg_memory::address_t l2_fill_base_o,
    output pkg_memory::line_t    l2_fill_data_o,
    output logic             l2_fill_dirty_o,
    output logic             l2_fill_error_o,

    // Efectos al handshake
    output logic             ev_fill_valid_o,
    output logic [N-1:0]     ev_fill_onehot_o,
    output logic             inv_valid_o,
    output logic [SET_W-1:0] inv_set_o,
    output logic [WAY_W-1:0] inv_way_o,
    output logic             resv_clr_valid_o,
    output logic [SET_W-1:0] resv_clr_set_o,
    output logic [WAY_W-1:0] resv_clr_way_o,

    // Selección expuesta para que el top cablee la lectura del arreglo de datos
    output logic [SET_W-1:0] sel_set_o,
    output logic [WAY_W-1:0] sel_way_o
);
    logic             sel_valid;
    logic [OPW-1:0]   sel_idx;
    logic [N-1:0]     sel_onehot;
    logic [AW-1:0]    sel_base;
    logic [SET_W-1:0] sel_set;
    logic [WAY_W-1:0] sel_way;

    // Árbitro del canal con lock: mantiene la oferta estable si L1 no acepta.
    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_fill_i), .older_i(older_i),
        .ext_valid_i(l2_fill_valid_o), .ext_ready_i(l2_fill_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    // Descomposición de la base de la operación seleccionada.
    assign sel_base = t_base_i[sel_idx*AW +: AW];
    assign sel_set  = sel_base[$clog2(pkg_memory::LINE_BYTES) +: SET_W];
    assign sel_way  = t_way_i[sel_idx*WAY_W +: WAY_W];

    // Salidas combinacionales hacia L1.
    assign l2_fill_valid_o = rst_ni && sel_valid;
    assign l2_fill_id_o    = sel_idx;
    assign l2_fill_base_o  = sel_base;
    assign l2_fill_data_o  = l2_fill_valid_o ? rd0_data_i : '0;
    assign l2_fill_dirty_o = t_dirty_i[sel_idx];
    assign l2_fill_error_o = 1'b0;

    // Handshake del canal: único ciclo en que se aplican los efectos.
    logic fill_hs;
    assign fill_hs = l2_fill_valid_o && l2_fill_ready_i;

    assign ev_fill_valid_o    = fill_hs;
    assign ev_fill_onehot_o   = fill_hs ? sel_onehot : '0;
    assign inv_valid_o        = fill_hs;
    assign inv_set_o          = sel_set;
    assign inv_way_o          = sel_way;
    assign resv_clr_valid_o   = fill_hs;
    assign resv_clr_set_o     = sel_set;
    assign resv_clr_way_o     = sel_way;

    // Selección expuesta para el cableado del arreglo de datos en el top.
    assign sel_set_o = sel_set;
    assign sel_way_o = sel_way;
endmodule
