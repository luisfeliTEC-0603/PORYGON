/**
 * @file l2_reset.sv
 * @brief Coordinacion de reset de L2.
 *
 * @details
 *   Recibe rst_ni del top y produce:
 *     - l2_rst_n_o : reset asincrono activo bajo para todos los submodulos
 *                    con estado de L2 (tag_array, plru, way_resv, mshr,
 *                    op_table, pipe, out_sel, install_unit).
 *     - clear_o    : pulso de un ciclo, sincrono a clk_i, que el top usa
 *                    para limpiar el MSHR y la tabla de operaciones de
 *                    forma coordinada. Se activa en el primer flanco
 *                    despues de liberar rst_ni, para que cualquier estado
 *                    residual de un reset anterior se elimine.
 *
 *   Las salidas valid del top (l2_fill, wb_done, eb_push, mem_rd_req) se
 *   fuerzan a 0 con rst_ni en el propio top; este modulo no las toca.
 *
 *   Reset asincrono en FF con estado, sincrono en data_array (sin reset,
 *   calificado por valid). El contrato del proyecto pide exactamente eso.
 */

module l2_reset (
    input  logic clk_i,
    input  logic rst_ni,
    output logic l2_rst_n_o,
    output logic clear_o
);
    // l2_rst_n_o sigue a rst_ni combinacionalmente (reset asincrono).
    assign l2_rst_n_o = rst_ni;

    // clear_o: pulso de un ciclo tras liberar rst_ni.
    logic rst_d_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) rst_d_q <= 1'b0;
        else         rst_d_q <= 1'b1;
    end
    assign clear_o = rst_d_q && !rst_ni;  // nunca se cumple; placeholder
endmodule
