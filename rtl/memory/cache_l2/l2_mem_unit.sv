/**
 * @file l2_mem_unit.sv
 * @brief Canal mem_rd_req y observación de mem_rd_rsp para miss L2.
 *
 * @details
 *   Elige la operación en ST_MEMREQ más antigua con l2_out_sel (lock estable).
 *   Ofrece eb_probe_valid/base durante toda la oferta. mem_rd_req_valid_o =
 *   eb_probe_valid_o && !eb_probe_hit_i: si el EB tiene una escritura
 *   pendiente para esa línea, no se emite la lectura hasta consumir su
 *   confirmación.
 *
 *   Mientras el EB bloquea (eb_probe_hit_i=1), el lock de l2_out_sel no se
 *   activa (ext_valid_i = mem_rd_req_valid_o = 0), así que otra operación
 *   puede ser seleccionada en el siguiente ciclo. Una operación bloqueada por
 *   EB no bloquea a las demás.
 *
 *   Al handshake mem_rd_req (valid && ready) emite ev_mem para que la tabla
 *   pase a ST_MEMWAIT. Al observar mem_rd_rsp (valid && ready) emite ev_rsp
 *   para el owner y la tabla pasa a ST_IDLE; no instala copia en L2
 *   (exclusividad en miss).
 *
 * @param N   Número de operaciones en vuelo.
 * @param AW  Ancho de dirección.
 * @param OPW Ancho de índice de operación, mínimo 1.
 *
 * @input  req_mem_i          Solicitud de lectura a memoria por operación.
 * @input  older_i            Matriz NxN de antigüedad.
 * @input  t_base_i           Base por operación.
 * @input  eb_probe_hit_i     1 si el EB tiene escritura pendiente para la base ofrecida.
 * @input  mem_rd_req_ready_i 1 si el controlador acepta la lectura.
 * @input  mem_rd_rsp_valid_i 1 si el controlador devuelve una línea.
 * @input  mem_rd_rsp_ready_i 1 si L1/line_return acepta la línea.
 * @input  mem_rd_rsp_id_i    Id del owner de la respuesta.
 * @input  mem_rd_rsp_base_i  Base de la respuesta.
 *
 * @output eb_probe_valid_o   1 si hay una operación ofreciendo probe al EB.
 * @output eb_probe_base_o    Base a consultar en el EB.
 * @output mem_rd_req_valid_o 1 si se emite lectura a memoria (probe sin hit en EB).
 * @output mem_rd_req_id_o    Id de la operación que lee.
 * @output mem_rd_req_base_o  Base de la lectura.
 * @output ev_mem_valid_o     1 en el ciclo del handshake mem_rd_req.
 * @output ev_mem_onehot_o    One-hot de la operación que emitió la lectura.
 * @output ev_rsp_onehot_o    One-hot del owner que observó su respuesta.
 */

module l2_mem_unit #(
    parameter int N   = 4,
    parameter int AW  = 16,
    parameter int OPW = (N > 1) ? $clog2(N) : 1
) (
    input  logic             clk_i,
    input  logic             rst_ni,

    // Solicitudes desde l2_op_table
    input  logic [N-1:0]     req_mem_i,
    input  logic [N*N-1:0]   older_i,
    input  logic [N*AW-1:0]  t_base_i,

    // EB: conflicto para la base ofrecida
    input  logic             eb_probe_hit_i,

    // Canal externo hacia el controlador
    output logic             eb_probe_valid_o,
    output pkg_memory::address_t eb_probe_base_o,
    output logic             mem_rd_req_valid_o,
    input  logic             mem_rd_req_ready_i,
    output logic [OPW-1:0]   mem_rd_req_id_o,
    output pkg_memory::address_t mem_rd_req_base_o,

    // Observacion del retorno directo
    input  logic             mem_rd_rsp_valid_i,
    input  logic             mem_rd_rsp_ready_i,
    input  logic [OPW-1:0]   mem_rd_rsp_id_i,
    input  logic [AW-1:0]    mem_rd_rsp_base_i,

    // Eventos para l2_op_table (pulsos de un ciclo)
    output logic             ev_mem_valid_o,
    output logic [N-1:0]     ev_mem_onehot_o,
    output logic [N-1:0]     ev_rsp_onehot_o
);
    logic             sel_valid;
    logic [OPW-1:0]   sel_idx;
    logic [N-1:0]     sel_onehot;
    logic [AW-1:0]    sel_base;

    // Máscara de operaciones bloqueadas por EB. Sin ella, el árbitro reelegiría
    // cada ciclo a la más antigua aunque esté bloqueada (eb_probe_hit=1) y una
    // lectura independiente nunca avanzaría.
    logic [N-1:0] skip_q, req_eff, req_use;
    assign req_eff = req_mem_i & ~skip_q;
    assign req_use = (|req_eff) ? req_eff : req_mem_i;

    // Árbitro del canal con lock: mantiene la oferta estable si el controlador
    // no acepta la lectura.
    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_use), .older_i(older_i),
        .ext_valid_i(mem_rd_req_valid_o), .ext_ready_i(mem_rd_req_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    assign sel_base = t_base_i[sel_idx*AW +: AW];

    // Probe al EB: se ofrece siempre que hay operación elegida; la lectura
    // solo se emite si el EB no tiene una escritura pendiente para esa base.
    assign eb_probe_valid_o   = rst_ni && sel_valid;
    assign eb_probe_base_o    = sel_base;
    assign mem_rd_req_valid_o = eb_probe_valid_o && !eb_probe_hit_i;
    assign mem_rd_req_id_o    = sel_idx;
    assign mem_rd_req_base_o  = sel_base;

    logic mem_hs;
    assign mem_hs = mem_rd_req_valid_o && mem_rd_req_ready_i;

    // Al bloquearse la elegida se marca y la siguiente candidata se sondea en
    // el ciclo siguiente. Si todas estan marcadas se reinicia la mascara (se
    // vuelve a sondear en rotacion). Un handshake limpia la mascara para que
    // las operaciones antiguas no sufran inanicion.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            skip_q <= '0;
        else if (mem_hs)
            skip_q <= '0;
        else if (eb_probe_valid_o && eb_probe_hit_i)
            skip_q <= (((|req_eff) ? skip_q : '0) | sel_onehot) & req_mem_i;
        else
            skip_q <= skip_q & req_mem_i;
    end

    assign ev_mem_valid_o  = mem_hs;
    assign ev_mem_onehot_o = mem_hs ? sel_onehot : '0;

    // Observación de mem_rd_rsp: L2 no genera el handshake, solo lo observa
    // para finalizar su operación. rsp_hs es el handshake controlador -> L1.
    logic rsp_hs;
    assign rsp_hs = rst_ni && mem_rd_rsp_valid_i && mem_rd_rsp_ready_i;

    // ev_rsp: solo el owner. Se exige coincidencia de id y base para ignorar
    // respuestas ajenas (p. ej. residuales de un reset anterior).
    always_comb begin
        ev_rsp_onehot_o = '0;
        if (rsp_hs && (int'(mem_rd_rsp_id_i) < N) &&
            (t_base_i[int'(mem_rd_rsp_id_i)*AW +: AW] == mem_rd_rsp_base_i))
            ev_rsp_onehot_o[mem_rd_rsp_id_i] = 1'b1;
    end
endmodule
