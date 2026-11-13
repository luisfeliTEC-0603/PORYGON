/**
 * @file l2_out_sel.sv
 * @brief Árbitro de un canal de L2: elige la operación más antigua que lo
 *        solicita, con bloqueo de oferta estable durante el handshake.
 *
 * @details
 *   Cada canal de L2 (fill, mem, eb, wr, done) puede ser solicitado por varias
 *   operaciones en vuelo al mismo tiempo. Este módulo resuelve cuál de ellas
 *   usa el canal en el ciclo actual.
 *
 *   Regla de arbitraje: gana la solicitante que no tiene otra operación
 *   activa más antigua solicitando el mismo canal. La antigüedad llega en
 *   `older_i` como matriz N×N: `older_i[j*N + i] = 1` significa que j es más
 *   antigua que i. Al recorrer las solicitantes de mayor a menor índice y
 *   sobrescribir, el resultado es determinista: ante empate, gana la de menor
 *   índice.
 *
 *   Bloqueo de oferta (lock): si el canal externo ofreció (`ext_valid_i=1`)
 *   pero no aceptó (`ext_ready_i=0`), el árbitro registra la elección y la
 *   mantiene hasta que el handshake se complete. Así, aunque en ciclos
 *   posteriores aparezca una operación más antigua, `sel_valid_o`, `sel_idx_o`
 *   y los campos que el top cablea a partir de ellos no cambian durante la
 *   espera. Es el equivalente al requisito de estabilidad de valid hasta
 *   handshake en protocolos tipo AXI.
 *
 *   Sin handshake externo (arbitraje interno donde el consumidor siempre
 *   acepta en el mismo ciclo), se pasa `ext_valid_i=0` y el lock nunca se
 *   activa; el módulo se comporta como un árbitro combinacional puro.
 *
 *   El desempate "empate -> drenado" no se implementa aquí: este módulo solo
 *   elige la más antigua. La política de drenado, si aplica, la resuelve el
 *   consumidor a partir de las salidas.
 *
 *   Precondición del lock: mientras `lock_q=1`, la operación bloqueada debe
 *   seguir solicitando el canal (su estado en la tabla de operaciones no
 *   avanza hasta el handshake). Si el consumidor cambiara su estado antes del
 *   handshake, el lock ofrecería un id inválido.
 *
 * @param N   Número de operaciones en vuelo.
 * @param OPW Ancho de índice de operación (mínimo 1).
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

    // Arbitraje combinacional
    // grant[i]=1 solo si i solicita el canal y ninguna otra solicitante j es
    // más antigua que i. El segundo lazo recorre descendente para que, ante
    // empate, gane el menor índice.
    always_comb begin
        arb_valid = 1'b0;
        arb_idx   = '0;
        for (int i = 0; i < N; i++) begin
            grant[i] = req_i[i];
            for (int j = 0; j < N; j++) begin
                if (j != i && req_i[j] && older_i[j*N + i]) grant[i] = 1'b0;
            end
        end
        for (int i = N-1; i >= 0; i--) begin
            if (grant[i]) begin arb_valid = 1'b1; arb_idx = i; end
        end
    end

    // Selección con lock
    // Mientras lock_q=1, la elección registrada prevalece sobre el arbitraje.
    assign sel_valid_o = lock_q | arb_valid;
    assign sel_idx_o   = lock_q ? lock_idx_q : arb_idx;

    // One-hot del índice elegido, útil para indexar vectores empaquetados
    // (base_o, data_o, etc.) en el top.
    always_comb begin
        for (int i = 0; i < N; i++)
            sel_onehot_o[i] = sel_valid_o && (sel_idx_o == i);
    end

    // Estado del lock
    // Se activa cuando el canal externo ofreció y no aceptó; se libera en
    // cualquier otro caso (handshake completado, oferta retirada, o reset).
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
