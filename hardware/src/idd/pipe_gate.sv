import pkg_vliw::*;

/**
 * @brief Compuerta parametrizable por opcode y sub-pipe.
 *
 * Devuelve el slot seleccionado, el índice del slot que hizo match y una
 * bandera que indica si hubo match. El índice permite al top calcular el
 * inmediato asociado a la instrucción seleccionada.
 *
 * @param TARGET_OPCODE Opcode que esta compuerta deja pasar.
 * @param SUB_PIPE      Sub-pipe requerido (-1 = ignorar).
 * @param SUB_PIPE_BIT  Bit del slot que codifica el sub-pipe.
 * @param NUM_SLOTS     Número de slots.
 * @param SLOT_WIDTH    Ancho del slot.
 *
 * @input  slot_i       Arreglo de slots crudos.
 * @output slot_o       Slot que hizo match (opcode + sub-pipe), o NOP.
 * @output slot_index_o Índice del slot que hizo match (0-3), o 0 si NOP.
 * @output match_o      '1' si hubo match, '0' si no.
 *
 * @note Si SUB_PIPE == -1 se ignora el sub-pipe.
 * @note Prioridad fija: si varios slots coinciden, gana el de menor índice.
 */

module pipe_gate #(
    parameter logic [1:0] TARGET_OPCODE = OPCODE_MATH,
    parameter integer     SUB_PIPE      = -1,
    parameter integer     SUB_PIPE_BIT  = 3,
    parameter integer     NUM_SLOTS     = pkg_vliw::NUM_SLOTS,
    parameter integer     SLOT_WIDTH    = pkg_vliw::SLOT_WIDTH
) (
    input  logic [SLOT_WIDTH-1:0] slot_i       [0:NUM_SLOTS-1],
    output logic [SLOT_WIDTH-1:0] slot_o,
    output logic [1:0]            slot_index_o,
    output logic                  match_o
);

    function automatic logic match(input logic [SLOT_WIDTH-1:0] slot);
        logic opcode_ok;
        logic subpipe_ok;
        begin
            opcode_ok = (slot[1:0] == TARGET_OPCODE);

            if (SUB_PIPE < 0) begin
                subpipe_ok = 1'b1;
            end
            else begin
                subpipe_ok = (slot[SUB_PIPE_BIT] == SUB_PIPE[0]);
            end

            match = opcode_ok && subpipe_ok && (slot != NOP_ENCODING);
        end
    endfunction

    always_comb begin
        slot_o       = NOP_ENCODING;
        slot_index_o = 2'b00;
        match_o      = 1'b0;

        if (match(slot_i[0])) begin
            slot_o       = slot_i[0];
            slot_index_o = 2'd0;
            match_o      = 1'b1;
        end
        else if (match(slot_i[1])) begin
            slot_o       = slot_i[1];
            slot_index_o = 2'd1;
            match_o      = 1'b1;
        end
        else if (match(slot_i[2])) begin
            slot_o       = slot_i[2];
            slot_index_o = 2'd2;
            match_o      = 1'b1;
        end
        else if (match(slot_i[3])) begin
            slot_o       = slot_i[3];
            slot_index_o = 2'd3;
            match_o      = 1'b1;
        end
    end

endmodule
