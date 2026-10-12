/**
 * @brief Decodifica y valida el slot CRYPTO recibido por crypto_unit.
 *
 * @details
 * Extrae funct, índice de llave e índice compartido de ronda, subllave o
 * palabra. Una solicitud solo es válida cuando está activa en EX, no es NOP,
 * usa el opcode CRYPTO, mantiene el bit reservado en cero y selecciona una
 * función definida por la ISA.
 *
 * @input  ex_valid_i                  Solicitud vigente en la etapa EX.
 * @input  nop_flag_i                  Indica que dispatch no entregó una operación.
 * @input  slot_i                      Slot CRYPTO de 16 bits.
 * @output ex_valid_o                  Solicitud CRYPTO con codificación válida.
 * @output funct_o                     Operación CRYPTO codificada en [9:7].
 * @output key_index_o                 Índice de llave codificado en [4:3].
 * @output subkey_index_o              Índice de ronda o subllave en [6:5].
 * @output credential_word_index_o     Índice de palabra LOPW en [6:5].
 *
 * @note Los campos se extraen siempre, pero solo producen efectos cuando
 *       ex_valid_o está activo.
 */
module crypto_decode (
    input  logic ex_valid_i,
    input  logic nop_flag_i,
    input  logic [pkg_vliw::SLOT_WIDTH-1:0] slot_i,

    output logic ex_valid_o,
    output logic [2:0] funct_o,
    output logic [1:0] key_index_o,
    output logic [1:0] subkey_index_o,
    output logic [1:0] credential_word_index_o
);

    logic valid_funct;

    assign funct_o = slot_i[9:7];
    assign subkey_index_o = slot_i[6:5];
    assign credential_word_index_o = slot_i[6:5];
    assign key_index_o = slot_i[4:3];

    always_comb begin
        valid_funct = 1'b0;

        case (funct_o)
            pkg_vliw::CRYPTO_AUTH,
            pkg_vliw::CRYPTO_WRITE,
            pkg_vliw::CRYPTO_FEISTEL,
            pkg_vliw::CRYPTO_PWD,
            pkg_vliw::CRYPTO_RVK,
            pkg_vliw::CRYPTO_LOPW: valid_funct = 1'b1;
            default: valid_funct = 1'b0;
        endcase
    end

    assign ex_valid_o = ex_valid_i
                      && !nop_flag_i
                      && (slot_i[1:0] == pkg_vliw::OPCODE_CRYPTO)
                      && !slot_i[2]
                      && valid_funct;

endmodule
