/**
 * @brief Memoria combinacional de bundles del segmento de texto de 64 KiB.
 *
 * @details Cada posicion contiene un bundle de 64 bits y la posicion cero
 * corresponde a BASE_ADDRESS. INIT_FILE usa el formato de $readmemh con una
 * palabra hexadecimal de 64 bits por bundle; slot 0 ocupa los bits [15:0].
 * Las posiciones no cargadas se inicializan con el bundle NOP completo.
 *
 * Una solicitud desalineada o fuera del segmento devuelve NOP y activa la
 * salida diagnostica out_of_range_o. No se introduce latencia ni estado, por
 * lo que el contrato combinacional de fetch_stage permanece sin cambios.
 */
module instruction_memory #(
    parameter integer MEMORY_BYTES = pkg_vliw::MEMORY_BYTES,
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] BASE_ADDRESS =
        pkg_vliw::TEXT_BASE_ADDRESS,
    parameter INIT_FILE = "",
    parameter integer INIT_BUNDLES = 0
) (
    input pkg_vliw::address_t address_i,
    input logic read_enable_i,
    output pkg_vliw::bundle_t bundle_o,
    output logic out_of_range_o
);
    import pkg_vliw::*;

    localparam integer BUNDLE_COUNT = MEMORY_BYTES / BUNDLE_BYTES;
    localparam address_t LAST_BUNDLE_ADDRESS =
        BASE_ADDRESS + MEMORY_BYTES - BUNDLE_BYTES;

    bundle_t memory [0:BUNDLE_COUNT-1];
    address_t byte_offset;
    logic address_aligned;
    logic address_in_range;

    assign byte_offset = address_i - BASE_ADDRESS;
    assign address_aligned = (address_i[$clog2(BUNDLE_BYTES)-1:0] == '0);
    assign address_in_range = (address_i >= BASE_ADDRESS) &&
                              (address_i <= LAST_BUNDLE_ADDRESS);
    assign bundle_o = (read_enable_i && address_aligned && address_in_range)
        ? memory[byte_offset / BUNDLE_BYTES] : '0;
    assign out_of_range_o = read_enable_i &&
                            (!address_aligned || !address_in_range);

    initial begin : initialize_memory
        integer bundle_index;
        for (bundle_index = 0; bundle_index < BUNDLE_COUNT; bundle_index++) begin
            memory[bundle_index] = '0;
        end
        if (INIT_FILE != "") begin
            if (INIT_BUNDLES > 0) begin
                $readmemh(INIT_FILE, memory, 0, INIT_BUNDLES - 1);
            end else begin
                $readmemh(INIT_FILE, memory);
            end
        end
    end
endmodule
