/**
 * @file l2_done_unit.sv
 * @brief Canal wb_done: confirmación de instalación hacia el write buffer.
 *
 * @details
 *   Elige la operación en ST_DONE más antigua con l2_out_sel (lock estable) y
 *   ofrece su id por wb_done_valid_o / wb_done_id_o. La confirmación solo se
 *   ofrece para operaciones que ya escribieron la línea en los arreglos
 *   (ST_DONE se alcanza después de ST_WRITE).
 *
 *   En el handshake (wb_done_valid_o && wb_done_ready_i) se emite un único
 *   efecto, en ese mismo flanco: ev_done_onehot_o (one-hot de la operación
 *   elegida) para que la tabla libere la posición y el id. ev_done_valid_o es
 *   el mismo handshake como escalar (lo usa el top para métricas). Ambos duran
 *   un solo ciclo: el consumidor los trata como eventos, no como niveles.
 *
 *   A diferencia de fill/evict/mem/install, este canal no lee arreglos, no
 *   invalida vías ni libera reservas: la reserva de la vía se liberó al
 *   escribir (l2_install_unit).
 *
 *   Incluido principalmente por motivos de simetria y modularidad.
 *
 * @param N   Número de operaciones en vuelo.
 * @param OPW Ancho de índice de operación, mínimo 1.
 *
 * @input  req_done_i      Solicitud de done por operación (operaciones en ST_DONE).
 * @input  older_i         Matriz N×N: older_i[j*N+i]=1 si j es más antigua que i.
 * @input  wb_done_ready_i 1 si el write buffer acepta la confirmación.
 *
 * @output wb_done_valid_o  1 si hay una operación ofreciendo confirmación.
 * @output wb_done_id_o     Id de la operación confirmada.
 * @output ev_done_valid_o  1 en el ciclo del handshake.
 * @output ev_done_onehot_o One-hot de la operación que completó.
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

    // Árbitro del canal con lock: mantiene la oferta estable si el WB no acepta.
    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_done_i), .older_i(older_i),
        .ext_valid_i(wb_done_valid_o), .ext_ready_i(wb_done_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    assign wb_done_valid_o = rst_ni && sel_valid;
    assign wb_done_id_o    = sel_idx;

    // Handshake: único ciclo en que se emite el evento a la tabla.
    logic done_hs;
    assign done_hs = wb_done_valid_o && wb_done_ready_i;

    assign ev_done_valid_o  = done_hs;
    assign ev_done_onehot_o = done_hs ? sel_onehot : '0;
endmodule
