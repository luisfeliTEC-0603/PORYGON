/**
 * @file l2_out_sel.sv
 * @brief Árbitro de un canal de L2: elige la operación más antigua que lo
 *        solicita, con oferta estable durante el handshake.
 *
 * @details
 *   Varias operaciones en vuelo pueden solicitar el mismo canal en el mismo
 *   ciclo. Gana la que no tiene otra solicitante más antigua (`older_i`).
 *   Ante empate, gana la de menor índice (determinista, no contractual).
 *
 *   Lock: si el canal externo ofreció (`ext_valid_i=1`) y no aceptó
 *   (`ext_ready_i=0`), se registra la elección y se mantiene hasta el
 *   handshake, para que `sel_*` y los campos cableados a partir de ellos no
 *   cambien durante la espera. Con `ext_valid_i=0` el lock nunca se activa.
 *
 *   El drenado en empate no se resuelve aquí; en L2 lo aplica el top en la
 *   admisión, no en los canales.
 *
 * @param N   Número de operaciones en vuelo.
 * @param OPW Ancho de índice de operación, mínimo 1.
 *
 * @input  req_i       Solicitud del canal por operación.
 * @input  older_i     Matriz NxN: older_i[j*N+i]=1 si j es más antigua que i.
 * @input  ext_valid_i 1 si el canal externo ofrece; 0 desactiva el lock.
 * @input  ext_ready_i 1 si el canal externo acepta.
 *
 * @output sel_valid_o  1 si hay operación elegida (por arbitraje o lock).
 * @output sel_idx_o    Índice de la operación elegida.
 * @output sel_onehot_o One-hot del índice, para indexar vectores empaquetados.
 */

module l2_out_sel #(
    parameter int N   = 4,
    parameter int OPW = (N > 1) ? $clog2(N) : 1
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic             clk_i,
    input  logic             rst_ni,

    // Solicitudes del canal y antigüedad entre operaciones
    input  logic [N-1:0]     req_i,
    input  logic [N*N-1:0]   older_i,

    // Handshake del canal externo (ext_valid_i=0 desactiva el lock)
    input  logic             ext_valid_i,
    input  logic             ext_ready_i,

    // Operación elegida
    output logic             sel_valid_o,
    output logic [OPW-1:0]   sel_idx_o,
    output logic [N-1:0]     sel_onehot_o
);
    logic [N-1:0]   grant;
    logic           arb_valid;
    logic [OPW-1:0] arb_idx;
    logic           lock_q;
    logic [OPW-1:0] lock_idx_q;

    // Arbitraje: grant[i] se cae si otra solicitante j es más antigua que i.
    always_comb begin
        arb_valid = 1'b0;
        arb_idx   = '0;
        for (int i = 0; i < N; i++) begin
            grant[i] = req_i[i];
            for (int j = 0; j < N; j++) begin
                if (j != i && req_i[j] && older_i[j*N + i]) grant[i] = 1'b0;
            end
        end
        // Descendente + sobrescritura: ante empate, menor índice.
        for (int i = N-1; i >= 0; i--) begin
            if (grant[i]) begin arb_valid = 1'b1; arb_idx = i; end
        end
    end

    // Con lock, la elección registrada prevalece para no romper la oferta.
    assign sel_valid_o = lock_q | arb_valid;
    assign sel_idx_o   = lock_q ? lock_idx_q : arb_idx;

    // One-hot del índice elegido, para indexar vectores empaquetados en el top.
    always_comb begin
        for (int i = 0; i < N; i++)
            sel_onehot_o[i] = sel_valid_o && (sel_idx_o == i);
    end

    // Lock: se activa si el canal externo ofreció y no aceptó; se libera en
    // cualquier otro caso. Mientras lock_q=1, la operación sigue solicitando,
    // así que lock_idx_q es un índice válido.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            lock_q     <= 1'b0;
            lock_idx_q <= '0;
        end else if (ext_valid_i && !ext_ready_i) begin
            lock_q     <= 1'b1;
            lock_idx_q <= sel_idx_o;
        end else begin
            lock_q     <= 1'b0;
        end
    end
endmodule
