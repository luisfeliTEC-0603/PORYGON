/**
 * @file l2_pipe.sv
 * @brief Pipeline interno de L2: línea de retardo de índices de operación.
 *
 * @details
 *   Modela las 7 etapas que una operación recorre entre su admisión y el
 *   momento en que l2_op_table puede avanzar su estado. Con el ciclo de
 *   accept son los 8 ciclos de hit de L2.
 *
 *   Solo viaja el índice. Datos y metadatos viven en l2_op_table, indexados
 *   por ese id: si la operación se detiene al final, sus datos siguen intactos
 *   y las demás pueden avanzar.
 *
 *   Sin stalls internos: siempre avanza un índice por ciclo. Las esperas de
 *   L2 (memoria, EB, canal de salida) son estados de la tabla, no detenciones
 *   de este pipeline.
 *
 * @param STAGES Número de etapas internas (7).
 * @param OPW    Ancho de índice de operación, mínimo 1.
 *
 * @input  in_valid_i   1 si una operación entra al pipeline este ciclo.
 * @input  in_idx_i     Índice de la operación que entra.
 *
 * @output stage_valid_o Validez por etapa del shift register.
 * @output stage_idx_o   Índice por etapa del shift register.
 * @output end_valid_o   1 si la operación completó las STAGES etapas.
 * @output end_idx_o     Índice de la operación que completó las etapas.
 */

module l2_pipe #(
    parameter int STAGES = 7,
    parameter int OPW    = 2
) (
    // Reloj y reset asíncrono, activo bajo
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // Admisión de una operación al pipeline
    input  logic                  in_valid_i,
    input  logic [OPW-1:0]        in_idx_i,

    // Índice presente en cada etapa (depuración)
    output logic [STAGES-1:0]     stage_valid_o,
    output logic [STAGES*OPW-1:0] stage_idx_o,

    // Fin del pipeline: la operación completó las STAGES etapas
    output logic                  end_valid_o,
    output logic [OPW-1:0]        end_idx_o
);
    // Shift register: un bit de validez y un índice por etapa.
    logic [STAGES-1:0]     v_q;
    logic [STAGES*OPW-1:0] i_q;

    // La admisión entra en la posición 0; el resto se corre una etapa.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            v_q <= '0;
            i_q <= '0;
        end else begin
            v_q <= {v_q[STAGES-2:0], in_valid_i};
            i_q <= {i_q[(STAGES-1)*OPW-1:0], in_idx_i};
        end
    end

    // Salidas por etapa (depuración) y salida final tras STAGES flancos.
    assign stage_valid_o = v_q;
    assign stage_idx_o   = i_q;
    assign end_valid_o   = v_q[STAGES-1];
    assign end_idx_o     = i_q[(STAGES-1)*OPW +: OPW];
endmodule
