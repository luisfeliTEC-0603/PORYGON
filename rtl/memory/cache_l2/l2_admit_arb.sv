/**
 * @file l2_admit_arb.sv
 * @brief Árbitro de admisión: elige entre demanda L1 e install WB respetando
 *        la antigüedad de espera, con drenado de WB solo en empate.
 *
 * @details
 *   Resuelve quién gana la única aceptación por ciclo cuando una demanda y un
 *   install compiten por entrar a L2. La antigüedad de las operaciones en
 *   vuelo la lleva l2_op_table; este módulo lleva la antigüedad de las
 *   solicitudes que aún esperan aceptación.
 *
 *   Regla: gana la solicitud más antigua que pueda avanzar. Una solicitud más
 *   antigua pero bloqueada (pre=0) no frena a la otra. Si ambas llegan en el
 *   mismo ciclo (ninguna esperaba), gana el install (drenado de WB en empate).
 *
 *   La antigüedad de espera se registra con tres bits: get_pend_q/inst_pend_q
 *   indican qué tipo está esperando (válido y no aceptado); get_first_q
 *   registra, cuando ambas esperan, cuál llegó primero. get_older traduce ese
 *   estado a "la demanda es la más antigua".
 *
 *   No calcula pre: eso depende de tablas, reservas y way_select, que son
 *   lógica del top. El módulo solo recibe "puede avanzar" y decide "quién
 *   avanza". No añade latencia: ready sigue siendo combinacional en el ciclo
 *   actual; los registros solo afectan el desempate.
 *
 * @param N/A
 *
 * @input  clk_i        Reloj.
 * @input  rst_ni       Reset asíncrono activo bajo.
 * @input  get_valid_i  1 si una demanda L1 se presenta este ciclo.
 * @input  get_pre_i    1 si la demanda puede avanzar (slot, sin conflicto, sin reserva).
 * @input  inst_valid_i 1 si un install WB se presenta este ciclo.
 * @input  inst_pre_i   1 si el install puede avanzar (slot, sin conflicto, vía disponible).
 *
 * @output get_ready_o  1 si la demanda gana la admisión este ciclo.
 * @output inst_ready_o 1 si el install gana la admisión este ciclo.
 */

module l2_admit_arb (
    input  logic clk_i,
    input  logic rst_ni,

    input  logic get_valid_i,
    input  logic get_pre_i,
    input  logic inst_valid_i,
    input  logic inst_pre_i,

    output logic get_ready_o,
    output logic inst_ready_o
);
    logic get_pend_q, inst_pend_q, get_first_q, get_older;

    // Antigüedad de espera: si solo una solicitud está pendiente, es la más
    // antigua; si ambas lo están, manda el orden registrado; si ninguna
    // esperaba (llegan juntas), gana el install por drenado.
    always_comb begin
        case ({get_pend_q, inst_pend_q})
            2'b10:   get_older = 1'b1;          // solo la demanda espera
            2'b01:   get_older = 1'b0;          // solo el install espera
            2'b11:   get_older = get_first_q;   // ambas esperan: orden registrado
            default: get_older = 1'b0;          // llegan juntas: drenado WB
        endcase
    end

    // Cada solicitud cede el paso a la otra solo si la otra es la más antigua
    // y puede avanzar. El pre_i dentro de la condición evita que una solicitud
    // bloqueada (aunque más antigua) frene a la otra.
    assign inst_ready_o = inst_pre_i && !(get_valid_i && get_pre_i && get_older);
    assign get_ready_o  = get_pre_i  && !(inst_valid_i && inst_pre_i && !get_older);

    logic get_accept, inst_accept;
    assign get_accept  = get_valid_i  && get_ready_o;
    assign inst_accept = inst_valid_i && inst_ready_o;

    // Pendiente = válida y no aceptada. get_first_q se actualiza solo cuando
    // ambas son válidas en el mismo ciclo, registrando el desempate vigente.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            get_pend_q  <= 1'b0;
            inst_pend_q <= 1'b0;
            get_first_q <= 1'b0;
        end else begin
            get_pend_q  <= get_valid_i  && !get_accept;
            inst_pend_q <= inst_valid_i && !inst_accept;
            if (get_valid_i && inst_valid_i) get_first_q <= get_older;
        end
    end
endmodule
