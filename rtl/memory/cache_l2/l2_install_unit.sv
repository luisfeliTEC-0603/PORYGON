/**
 * @file l2_install_unit.sv
 * @brief Canal de escritura: instala la línea de un wb_install en L2 y avanza
 *        la operación a ST_DONE.
 *
 * @details
 *   Elige la operación en ST_WRITE más antigua con l2_out_sel en modo interno
 *   (sin lock: el consumidor es el arreglo, que acepta en el mismo ciclo).
 *
 *   Separa dos tipos de efecto:
 *     - Escritura de arreglos (tag, valid, dirty, línea): NIVEL que permanece
 *       activo mientras la operación está seleccionada. Reescribir el mismo
 *       valor es idempotente, así que no hay daño si la operación tarda en
 *       transicionar a ST_DONE. Robusto ante latencia de la tabla.
 *     - Efectos laterales (ev_wr, plru_touch, resv_clr): PULSOS de un ciclo en
 *       la primera selección (first_sel). No son idempotentes: repetir ev_wr
 *       contaría dos eventos, plru_touch corrompería la política, resv_clr
 *       liberaría una reserva ya liberada. Se protegen con eff_q/eff_idx_q.
 *
 *   wb_done no se emite aquí: lo genera el top desde req_done_o cuando la
 *   operación está en ST_DONE.
 *
 *   El merge de dirty en install hit (wb_dirty | dirty_previo) lo hace el top
 *   al aceptar y lo entrega en t_dirty_i; este módulo solo escribe ese valor.
 *
 * @param N     Número de operaciones en vuelo.
 * @param AW    Ancho de dirección.
 * @param LW    Ancho de línea.
 * @param WAY_W Ancho de índice de vía.
 * @param SET_W Ancho de índice de conjunto.
 * @param TAG_W Ancho de tag.
 * @param OPW   Ancho de índice de operación, mínimo 1.
 *
 * @input  req_wr_i    Solicitud de escritura por operación.
 * @input  older_i     Matriz N×N de antigüedad.
 * @input  t_base_i    Base por operación.
 * @input  t_way_i     Vía por operación.
 * @input  t_data_i    Línea a instalar por operación.
 * @input  t_dirty_i   Dirty a instalar por operación.
 *
 * @output wr_valid_o       1 si hay una operación escribiendo los arreglos.
 * @output wr_set_o         Conjunto de la vía a escribir.
 * @output wr_way_o         Vía a escribir.
 * @output wr_tag_o         Tag a escribir.
 * @output wr_dirty_o       Dirty a escribir.
 * @output wr_data_o        Línea a escribir.
 * @output wr_idx_o         Índice de la operación que escribe.
 * @output plru_touch_valid_o 1 en la primera selección (actualizar PLRU).
 * @output plru_touch_set_o  Conjunto de la vía usada por la instalación.
 * @output plru_touch_way_o  Vía usada por la instalación.
 * @output resv_clr_valid_o  1 en la primera selección (liberar reserva).
 * @output resv_clr_set_o    Conjunto de la reserva a liberar.
 * @output resv_clr_way_o    Vía de la reserva a liberar.
 * @output ev_wr_valid_o     1 en la primera selección (avanzar a ST_DONE).
 * @output ev_wr_onehot_o    One-hot de la operación que completó la escritura.
 */

module l2_install_unit #(
    parameter int N     = 4,
    parameter int AW    = 16,
    parameter int LW    = 256,
    parameter int WAY_W = 2,
    parameter int SET_W = 7,
    parameter int TAG_W = 20,
    parameter int OPW   = (N > 1) ? $clog2(N) : 1
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic             clk_i,
    input  logic             rst_ni,

    // Solicitudes desde la tabla de operaciones
    input  logic [N-1:0]     req_wr_i,
    input  logic [N*N-1:0]   older_i,
    input  logic [N*AW-1:0]  t_base_i,
    input  logic [N*WAY_W-1:0] t_way_i,
    input  logic [N*LW-1:0]  t_data_i,
    input  logic [N-1:0]     t_dirty_i,

    // Escritura de arreglos (nivel, idempotente)
    output logic             wr_valid_o,
    output logic [SET_W-1:0] wr_set_o,
    output logic [WAY_W-1:0] wr_way_o,
    output logic [TAG_W-1:0] wr_tag_o,
    output logic             wr_dirty_o,
    output logic [LW-1:0]    wr_data_o,
    output logic [OPW-1:0]   wr_idx_o,

    // Touch PLRU y clear de reserva (pulsos de un ciclo)
    output logic             plru_touch_valid_o,
    output logic [SET_W-1:0] plru_touch_set_o,
    output logic [WAY_W-1:0] plru_touch_way_o,
    output logic             resv_clr_valid_o,
    output logic [SET_W-1:0] resv_clr_set_o,
    output logic [WAY_W-1:0] resv_clr_way_o,

    // Evento para la tabla de operaciones (pulso de un ciclo)
    output logic             ev_wr_valid_o,
    output logic [N-1:0]     ev_wr_onehot_o
);
    logic             sel_valid;
    logic [OPW-1:0]   sel_idx;
    logic [N-1:0]     sel_onehot;
    logic [AW-1:0]    sel_base;
    logic [SET_W-1:0] sel_set;
    logic [WAY_W-1:0] sel_way;

    // Árbitro interno: el consumidor (arreglo de datos) acepta en el mismo
    // ciclo, así que ext_valid_i=0 desactiva el lock.
    l2_out_sel #(.N(N)) u_sel (
        .clk_i, .rst_ni,
        .req_i(req_wr_i), .older_i(older_i),
        .ext_valid_i(1'b0), .ext_ready_i(1'b1),
        .sel_valid_o(sel_valid), .sel_idx_o(sel_idx),
        .sel_onehot_o(sel_onehot));

    // Descomposición de la base de la operación elegida: set para indexar el
    // arreglo, way para elegir la vía.
    assign sel_base = t_base_i[sel_idx*AW +: AW];
    assign sel_set  = sel_base[$clog2(pkg_memory::LINE_BYTES) +: SET_W];
    assign sel_way  = t_way_i[sel_idx*WAY_W +: WAY_W];

    // Detección de primera selección: protege los efectos no idempotentes
    // (ev_wr, plru_touch, resv_clr) para que se apliquen una sola vez por
    // operación aunque ST_WRITE dure más de un ciclo. La escritura de
    // arreglos no usa este registro: es de nivel, idempotente.
    logic             eff_q;
    logic [OPW-1:0]   eff_idx_q;

    logic first_sel;
    assign first_sel = sel_valid && (!eff_q || (eff_idx_q != sel_idx));

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            eff_q     <= 1'b0;
            eff_idx_q <= '0;
        end else if (sel_valid) begin
            eff_q     <= 1'b1;
            eff_idx_q <= sel_idx;
        end else begin
            eff_q     <= 1'b0;
        end
    end

    // Escritura de arreglos: nivel, robusto ante latencia de la tabla.
    // Reescribir el mismo valor en ciclos consecutivos es idempotente.
    assign wr_valid_o = rst_ni && sel_valid;
    assign wr_set_o   = sel_set;
    assign wr_way_o   = sel_way;
    assign wr_tag_o   = sel_base[$clog2(pkg_memory::LINE_BYTES) + SET_W +: TAG_W];
    assign wr_idx_o   = sel_idx;
    assign wr_dirty_o = t_dirty_i[sel_idx];
    assign wr_data_o  = t_data_i[sel_idx*LW +: LW];

    // Efectos laterales: pulso, una sola vez por operación.
    assign ev_wr_valid_o      = first_sel;
    assign ev_wr_onehot_o     = first_sel ? sel_onehot : '0;
    assign plru_touch_valid_o = first_sel;
    assign plru_touch_set_o   = sel_set;
    assign plru_touch_way_o   = sel_way;
    assign resv_clr_valid_o   = first_sel;
    assign resv_clr_set_o     = sel_set;
    assign resv_clr_way_o     = sel_way;
endmodule
