/**
 * @file l2_pipe.sv
 * @brief Pipeline interno de L2: línea de retardo de índices de operación.
 *
 * @details
 *   Modela las 7 etapas internas que una operación recorre entre su admisión
 *   y el momento en que la tabla de operaciones puede avanzar su estado.
 *   Etapas: AC (accept), DS (dispatch), TAG (2 ciclos), DATA (2 ciclos),
 *   RD (return). Sumadas al ciclo de accept dan los 8 ciclos de hit de L2.
 *
 *   Solo viaja el índice de la operación (`in_idx_i`). Los datos y metadatos
 *   viven en la tabla de operaciones, indexados por ese id. Por eso, si la
 *   operación se detiene al final del pipeline (porque el canal de salida no
 *   está listo), sus datos siguen intactos en la tabla y las demás
 *   operaciones pueden avanzar si sus recursos lo permiten.
 *
 *   El pipeline no tiene stalls internos: siempre avanza un índice por ciclo.
 *   Los stalls de L2 (miss de memoria, espera de eviction buffer, espera de
 *   canal de salida) se gestionan como estados de la tabla de operaciones,
 *   no como detenciones de esta línea de retardo.
 *
 *   Las salidas por etapa (`stage_valid_o`, `stage_idx_o`) exponen el índice
 *   en cada posición del shift register. No son necesarias para la
 *   integración básica, pero permiten depuración y, si en el futuro alguna
 *   etapa necesita conocer el índice antes del final, tomarlo de aquí.
 *
 *   Configuración contractual: STAGES=7. Cambiar STAGES exige ajustar los
 *   anchos de `stage_valid_o` y `stage_idx_o` en el consumidor, y recalcular
 *   el tiempo de hit.
 *
 * @param STAGES Número de etapas internas del pipeline (7).
 * @param OPW    Ancho de índice de operación (mínimo 1).
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

    // Índice presente en cada etapa (para depuración o consumidores tempranos)
    output logic [STAGES-1:0]     stage_valid_o,
    output logic [STAGES*OPW-1:0] stage_idx_o,

    // Fin del pipeline: la operación completó las STAGES etapas
    output logic                  end_valid_o,
    output logic [OPW-1:0]        end_idx_o
);
    // Registros del shift register: un bit de validez y un índice por etapa.
    logic [STAGES-1:0]     v_q;
    logic [STAGES*OPW-1:0] i_q;

    // Desplazamiento en cada flanco: la admisión entra en la posición 0 y el
    // resto se corre una etapa. Al cabo de STAGES flancos, la admisión
    // original ocupa la última posición, que es `end_*`.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            v_q <= '0;
            i_q <= '0;
        end else begin
            v_q <= {v_q[STAGES-2:0], in_valid_i};
            i_q <= {i_q[(STAGES-1)*OPW-1:0], in_idx_i};
        end
    end

    // Salidas por etapa y salida final.
    assign stage_valid_o = v_q;
    assign stage_idx_o   = i_q;
    assign end_valid_o   = v_q[STAGES-1];
    assign end_idx_o     = i_q[(STAGES-1)*OPW +: OPW];
endmodule
