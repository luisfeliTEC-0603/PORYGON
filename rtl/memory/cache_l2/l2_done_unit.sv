/**
 * @file l2_done_unit.sv
 * @brief Canal wb_done: confirmacion de instalacion hacia el write buffer.
 *
 * @details
 *   Selecciona la operacion en ST_DONE mas antigua mediante `l2_out_sel` con
 *   lock estable y ofrece su id por `wb_done_valid_o` / `wb_done_id_o`. La
 *   confirmacion solo se ofrece para operaciones que ya escribieron la linea
 *   en los arreglos (ST_DONE se alcanza despues de ST_WRITE).
 *
 *   Al completarse el handshake (`wb_done_valid_o && wb_done_ready_i`) se
 *   produce un unico efecto, en ese mismo flanco: `ev_done_onehot_o` (one-hot
 *   de la operacion elegida) para que la tabla libere la posicion y el id.
 *   `ev_done_valid_o` es el mismo handshake como escalar (lo usa el top para
 *   metricas). Ambos duran un solo ciclo: el consumidor los trata como
 *   eventos, no como niveles.
 *
 *   A diferencia de fill/evict/mem/install, este canal no lee arreglos, no
 *   invalida vias ni libera reservas: la reserva de la via se libero al
 *   escribir (l2_install_unit).
 *
 *   Contrato de reset: asincrono, activo bajo. `wb_done_valid_o` y los
 *   eventos se anulan con `rst_ni`; el lock de `l2_out_sel` se limpia.
 *
 * @param N   Numero de operaciones en vuelo.
 * @param OPW Ancho de indice de operacion (mínimo 1).
 */
module l2_done_unit #(
    parameter int N   = 4,
    parameter int OPW = (N > 1) ? $clog2(N) : 1
) (
    input  logic             clk_i,
    input  logic             rst_ni,

    input  logic [N-1:0]     req_done_i,   // operaciones en ST_DONE
    input  logic [N*N-1:0]   older_i,      // older_i[j*N+i]=1: j mas antigua que i

    output logic             wb_done_valid_o,
    input  logic             wb_done_ready_i,
    output logic [OPW-1:0]   wb_done_id_o,

    output logic             ev_done_valid_o,
    output logic [N-1:0]     ev_done_onehot_o
);
    logic           sel_valid;
    logic [OPW-1:0] sel_idx;
    logic [N-1:0]   sel_onehot;

    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_done_i), .older_i(older_i),
        .ext_valid_i(wb_done_valid_o), .ext_ready_i(wb_done_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    assign wb_done_valid_o = rst_ni && sel_valid;
    assign wb_done_id_o    = sel_idx;

    logic done_hs;
    assign done_hs = wb_done_valid_o && wb_done_ready_i;

    assign ev_done_valid_o  = done_hs;
    assign ev_done_onehot_o = done_hs ? sel_onehot : '0;
endmodule
