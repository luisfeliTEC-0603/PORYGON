/**
 * @file l2_mem_unit.sv
 * @brief Canal mem_rd_req y observacion de mem_rd_rsp para miss L2.
 *
 * @details
 *   Selecciona la operacion en ST_MEMREQ mas antigua mediante l2_out_sel con
 *   lock estable. Ofrece eb_probe_valid/base durante toda la oferta de
 *   lectura. mem_rd_req_valid_o = eb_probe_valid_o && !eb_probe_hit_i: si el
 *   EB tiene una escritura pendiente para esa linea, no se emite la lectura
 *   hasta consumir su confirmacion (interfaces.md seccion 5).
 *
 *   Mientras el EB bloquea (eb_probe_hit_i=1), el lock de l2_out_sel no se
 *   activa (ext_valid_i = mem_rd_req_valid_o = 0), asi que otra operacion
 *   puede ser seleccionada en el siguiente ciclo. Es lo deseado: una
 *   operacion bloqueada por EB no bloquea a las demas (hierarchy.md seccion 5).
 *
 *   Al handshake mem_rd_req (valid && ready):
 *     - emite ev_mem para que l2_op_table pase a ST_MEMWAIT.
 *
 *   Al observar mem_rd_rsp (valid && ready) L2 no genera el handshake: solo
 *   lo observa para finalizar su operacion. En ese flanco:
 *     - ev_rsp para el owner (rsp_id): l2_op_table pasa ST_MEMWAIT -> ST_IDLE.
 *     - ev_rsp para cada waiter enganchado al MSHR de esa base:
 *       l2_op_table pasa ST_WAIT_MSHR -> ST_FILL. Asi dos demandas a la
 *       misma base no duplican mem_rd_req (T6).
 *     - mshr_release para liberar la entrada MSHR.
 *     - NO se instala copia en L2 (exclusividad en miss).
 *
 *   Los waiters de la entrada MSHR correcta los entrega el top en
 *   mshr_waiters_sel_i (N bits), seleccionados con mshr_probe_entry_i
 *   (indice de la entrada que hizo hit en el MSHR para la base del rsp).
 *   No se usa la matriz N*N directamente porque el indice de la entrada
 *   MSHR no coincide necesariamente con el id del owner.
 *
 *   Precondiciones documentadas:
 *     - mem_rd_rsp_ready_i es la aceptacion de L1/line_return, no de L2;
 *       L2 solo observa valid && ready. El top lo cablea.
 *     - Un id en ST_MEMWAIT no se reutiliza hasta que llega su rsp y la
 *       operacion termina; por eso rsp_id identifica al owner sin ambiguedad.
 *     - Caso limite attach + rsp en el mismo ciclo: la politica es que el
 *       top bloquee la aceptacion del waiter en ese ciclo (l2_get_ready_o=0)
 *       para evitar un waiter colgado. Ver documentacion del top.
 *
 *   Los pulsos ev_mem, ev_rsp y mshr_release duran un solo ciclo.
 *
 * @param N     Numero de operaciones en vuelo.
 * @param AW    Ancho de direccion.
 * @param OPW   Ancho de indice de operacion.
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

    // MSHR: waiters de la entrada que coincide con la base del rsp.
    // El top selecciona con mshr_probe_entry_i y pasa solo N bits.
    input  logic [N-1:0]     mshr_waiters_sel_i,

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
    output logic [N-1:0]     ev_rsp_onehot_o,

    // Liberacion del MSHR al observar el rsp
    output logic             mshr_release_valid_o,
    output logic [AW-1:0]    mshr_release_base_o
);
    logic             sel_valid;
    logic [OPW-1:0]   sel_idx;
    logic [N-1:0]     sel_onehot;
    logic [AW-1:0]    sel_base;

    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_mem_i), .older_i(older_i),
        .ext_valid_i(mem_rd_req_valid_o), .ext_ready_i(mem_rd_req_ready_i),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    assign sel_base = t_base_i[sel_idx*AW +: AW];

    // Canal mem_rd_req
    assign eb_probe_valid_o   = rst_ni && sel_valid;
    assign eb_probe_base_o    = sel_base;
    assign mem_rd_req_valid_o = eb_probe_valid_o && !eb_probe_hit_i;
    assign mem_rd_req_id_o    = sel_idx;
    assign mem_rd_req_base_o  = sel_base;

    logic mem_hs;
    assign mem_hs = mem_rd_req_valid_o && mem_rd_req_ready_i;

    assign ev_mem_valid_o  = mem_hs;
    assign ev_mem_onehot_o = mem_hs ? sel_onehot : '0;

    // Observacion de mem_rd_rsp
    // rsp_hs es el handshake del retorno controlador -> L1. L2 lo observa
    // para finalizar su operacion y liberar el id, sin instalar copia.
    logic rsp_hs;
    assign rsp_hs = rst_ni && mem_rd_rsp_valid_i && mem_rd_rsp_ready_i;

    // ev_rsp: owner siempre; waiters de la entrada MSHR correcta.
    // El owner avanza ST_MEMWAIT -> ST_IDLE aunque su base ya no coincida
    // (por ejemplo, por un timeout), para no dejarlo colgado.
    always_comb begin
        ev_rsp_onehot_o = '0;
        if (rsp_hs) begin
            ev_rsp_onehot_o[mem_rd_rsp_id_i] = 1'b1;
            for (int w = 0; w < N; w++) begin
                if (mshr_waiters_sel_i[w])
                    ev_rsp_onehot_o[w] = 1'b1;
            end
        end
    end

    // Liberacion del MSHR: siempre que llegue un rsp. El MSHR ignora bases
    // que no estan en vuelo, asi que es seguro.
    assign mshr_release_valid_o = rsp_hs;
    assign mshr_release_base_o  = mem_rd_rsp_base_i;
endmodule
