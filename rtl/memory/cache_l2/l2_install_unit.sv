/**
 * @file l2_install_unit.sv
 * @brief Canal de escritura: instala la línea de un wb_install en L2 y avanza
 *        la operación a ST_DONE.
 *
 * @details
 *   Selecciona la operación en ST_WRITE más antigua mediante `l2_out_sel` en
 *   modo interno (sin lock: el consumidor es el propio arreglo de datos, que
 *   acepta en el mismo ciclo).
 *
 *   Separación de responsabilidades entre escritura y efectos laterales:
 *
 *   - La escritura de arreglos (tag, valid, dirty, línea) es un NIVEL que
 *     permanece activo mientras la operación está seleccionada en ST_WRITE.
 *     Escribir el mismo valor en ciclos consecutivos es idempotente, así que
 *     no hay daño si la operación tarda más de un ciclo en transicionar a
 *     ST_DONE. Esta forma es robusta ante latencia de la tabla de operaciones.
 *
 *   - Los efectos laterales (`ev_wr`, `plru_touch`, `resv_clr`) se emiten
 *     como PULSOS de un solo ciclo en la primera selección de la operación
 *     (`first_sel`). No son idempotentes: repetir `ev_wr` podría interpretarse
 *     como dos eventos, repetir `plru_touch` corrompería la política de
 *     reemplazo, y repetir `resv_clr` liberaría una reserva ya liberada. Por
 *     eso se protegen con el registro `eff_q`/`eff_idx_q`.
 *
 *   `wb_done` no se emite aquí: lo genera el top a partir de `req_done_o` de
 *   la tabla de operaciones cuando la operación está en ST_DONE.
 *
 *   El merge de dirty en un install hit (dirty = wb_dirty | dirty_previo) lo
 *   realiza el top al aceptar la operación, y lo entrega en `t_dirty_i`. Este
 *   módulo se limita a escribir el valor recibido.
 *
 * @param N     Número de operaciones en vuelo.
 * @param AW    Ancho de dirección.
 * @param LW    Ancho de línea.
 * @param WAY_W Ancho de índice de vía.
 * @param SET_W Ancho de índice de conjunto.
 * @param TAG_W Ancho de tag.
 * @param OPW   Ancho de índice de operación.
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

    // Descomposición de la base de la operación seleccionada.
    assign sel_base = t_base_i[sel_idx*AW +: AW];
    assign sel_set  = sel_base[$clog2(pkg_memory::LINE_BYTES) +: SET_W];
    assign sel_way  = t_way_i[sel_idx*WAY_W +: WAY_W];

    // Detección de primera activación
    // Protege los efectos laterales NO idempotentes (evento, touch de PLRU,
    // clear de reserva) para que se apliquen una sola vez por operación,
    // aunque la operación permanezca en ST_WRITE más de un ciclo. La
    // escritura de arreglos NO usa este registro: es de nivel, idempotente.
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

    // Escritura de arreglos: nivel, robusto ante latencia de la op_table.
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
