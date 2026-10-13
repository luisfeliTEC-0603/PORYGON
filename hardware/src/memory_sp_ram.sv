/**
 * @brief Memoria de datos sincrona del segmento 0x00010000..0x0001FFFF.
 *
 * @details El arreglo se organiza por bytes para que una imagen de ancho 8
 * generada por tools/data_loader/load_file.py pueda cargarse directamente.
 * La posicion cero del archivo corresponde a BASE_ADDRESS. Cada lectura
 * captura una palabra little endian en el flanco positivo y conserva la
 * respuesta hasta la siguiente lectura. Las escrituras aplican una mascara
 * por byte en ese mismo flanco y no modifican los bytes deshabilitados.
 *
 * Un acceso fuera del segmento no indexa el arreglo: las escrituras se
 * descartan, una lectura captura cero con read_valid_o deshabilitado y
 * out_of_range_o marca la solicitud. El nucleo usa la validez para suprimir el
 * WB. La salida de rango es diagnostica; no implementa trap ni estado.
 */
module memory_sp_ram #(
    parameter integer MEMORY_BYTES = pkg_vliw::MEMORY_BYTES,
    parameter logic [pkg_vliw::ADDR_WIDTH-1:0] BASE_ADDRESS =
        pkg_vliw::DATA_BASE_ADDRESS,
    parameter INIT_FILE = "",
    parameter integer INIT_BYTES = 0
) (
    input logic clk_i,
    input logic rst_ni,
    input pkg_vliw::address_t address_i,
    input logic read_enable_i,
    input logic [3:0] write_enable_i,
    input pkg_vliw::word_t write_data_i,
    output pkg_vliw::word_t read_data_o,
    output logic read_valid_o,
    output logic out_of_range_o
);
    import pkg_vliw::*;

    localparam address_t LAST_WORD_ADDRESS =
        BASE_ADDRESS + MEMORY_BYTES - (DATA_WIDTH / 8);

    logic [7:0] memory [0:MEMORY_BYTES-1];
    address_t byte_offset;
    logic address_in_range;

    assign byte_offset = address_i - BASE_ADDRESS;
    assign address_in_range = (address_i >= BASE_ADDRESS) &&
                              (address_i <= LAST_WORD_ADDRESS);
    assign out_of_range_o = (read_enable_i || (|write_enable_i)) &&
                            !address_in_range;

    initial begin : initialize_memory
        integer byte_index;
        for (byte_index = 0; byte_index < MEMORY_BYTES; byte_index++) begin
            memory[byte_index] = 8'h00;
        end
        if (INIT_FILE != "") begin
            if (INIT_BYTES > 0) begin
                $readmemh(INIT_FILE, memory, 0, INIT_BYTES - 1);
            end else begin
                $readmemh(INIT_FILE, memory);
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            read_data_o <= '0;
            read_valid_o <= 1'b0;
        end else begin
            read_valid_o <= read_enable_i && address_in_range;
            if (read_enable_i) begin
                if (address_in_range) begin
                    read_data_o <= {
                        memory[byte_offset + 3],
                        memory[byte_offset + 2],
                        memory[byte_offset + 1],
                        memory[byte_offset]
                    };
                end else begin
                    read_data_o <= '0;
                end
            end

            if (address_in_range) begin
                if (write_enable_i[0]) begin
                    memory[byte_offset] <= write_data_i[7:0];
                end
                if (write_enable_i[1]) begin
                    memory[byte_offset + 1] <= write_data_i[15:8];
                end
                if (write_enable_i[2]) begin
                    memory[byte_offset + 2] <= write_data_i[23:16];
                end
                if (write_enable_i[3]) begin
                    memory[byte_offset + 3] <= write_data_i[31:24];
                end
            end
        end
    end
endmodule
