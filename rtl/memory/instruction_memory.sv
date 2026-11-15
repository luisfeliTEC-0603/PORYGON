/**
 * @brief ROM sincrona de bundles del segmento de texto de 64 KiB.
 *
 * @details Cada posicion contiene un bundle de 64 bits y la posicion cero
 * corresponde a BASE_ADDRESS. INIT_FILE usa el formato de $readmemh con una
 * palabra hexadecimal de 64 bits por bundle; slot 0 ocupa los bits [15:0].
 * Las posiciones no cargadas se inicializan con el bundle NOP completo.
 *
 * @details La lectura se registra en el flanco positivo: esta salida es la
 * frontera IF/ID del bundle, sin otro registro de datos en fetch_stage.
 * read_enable_i=0 conserva el bundle; el diagnostico solo pulsa por lectura.
 * Una lectura desalineada o fuera de rango registra NOP y out_of_range_o.
 * @input clk_i, rst_ni Reloj CPU y reset asincrono activo bajo de las salidas.
 * @note Reset no modifica la imagen de instrucciones inicializada.
 */
module instruction_memory #(
    parameter integer MEMORY_BYTES = pkg_vliw::MEMORY_BYTES,
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] BASE_ADDRESS =
        pkg_vliw::TEXT_BASE_ADDRESS,
    parameter INIT_FILE = "",
    parameter integer INIT_BUNDLES = 0
) (
    input logic clk_i,
    input logic rst_ni,
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
    /** @brief La salida registrada conserva el bundle cuando IF no lee. */
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            bundle_o <= '0;
            out_of_range_o <= 1'b0;
        end else begin
            out_of_range_o <= 1'b0;
            if (read_enable_i) begin
                out_of_range_o <= !address_aligned || !address_in_range;
                if (address_aligned && address_in_range) begin
                    bundle_o <= memory[byte_offset / BUNDLE_BYTES];
                end else begin
                    bundle_o <= '0;
                end
            end
        end
    end

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
