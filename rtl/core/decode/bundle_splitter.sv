import pkg_vliw::*;

/**
 * @brief Divide un bundle VLIW de 64 bits en sus 4 slots de 16 bits.
 *
 * Mapeo de bits:
 * @code
 *   Bundle[15:0]   -> slot_o[0]
 *   Bundle[31:16]  -> slot_o[1]
 *   Bundle[47:32]  -> slot_o[2]
 *   Bundle[63:48]  -> slot_o[3]
 * @endcode
 *
 * @param BUNDLE_WIDTH Ancho total del bundle en bits.
 * @param SLOT_WIDTH   Ancho de cada slot en bits.
 * @param NUM_SLOTS    Número de slots por bundle.
 *
 * @input  bundle_i  Bundle VLIW de BUNDLE_WIDTH bits.
 * @output slot_o    Arreglo de NUM_SLOTS slots de SLOT_WIDTH bits cada uno.
 *
 * @note Es puramente cableado: no consume lógica, solo routing.
 */

module bundle_splitter #(
    parameter integer BUNDLE_WIDTH = pkg_vliw::BUNDLE_WIDTH,
    parameter integer SLOT_WIDTH   = pkg_vliw::SLOT_WIDTH,
    parameter integer NUM_SLOTS    = pkg_vliw::NUM_SLOTS
) (
    input  logic [BUNDLE_WIDTH-1:0] bundle_i,
    output logic [SLOT_WIDTH-1:0]   slot_o [0:NUM_SLOTS-1]
);

    always_comb begin
        for (int s = 0; s < NUM_SLOTS; s++) begin
            slot_o[s] = bundle_i[s*SLOT_WIDTH +: SLOT_WIDTH];
        end
    end

endmodule
