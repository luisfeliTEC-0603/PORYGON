/**
 * @brief Frontera del almacenamiento de 64 KiB en el dominio de memoria.
 * @param MEMORY_BYTES Capacidad en bytes; 65536 por defecto.
 * @param BASE_ADDRESS Base fisica del segmento de datos.
 * @param INIT_FILE Imagen opcional de bytes para inicializacion.
 * @param INIT_BYTES Numero de bytes de la imagen; cero usa la imagen completa.
 * @input clk_i, rst_ni Reloj de memoria y reset activo en cero.
 * @input address_i Direccion de la palabra que se quiere acceder.
 * @input read_enable_i Solicita una lectura en el siguiente flanco positivo.
 * @input write_enable_i Mascara de cuatro bytes; cero significa no escribir.
 * @input write_data_i Palabra cuyos bytes habilitados se escriben en la RAM.
 * @output read_data_o, read_valid_o Dato y validez de la lectura registrada.
 * @output out_of_range_o Indica solicitud activa fuera del segmento de RAM.
 * @details Una palabra de 32 bits por ciclo, little endian. Lectura sincrona;
 * escritura en flanco positivo segun mascara. El controlador de bursts define
 * latencias, cruza relojes y confirma la linea completa. Esta frontera puede
 * reutiliza el almacenamiento de memory_sp_ram sin modificar su modulo.
 * El reset invalida la lectura, pero conserva los bytes almacenados.
 * @see docs/ii-proyecto/skeletons.md
 */
module main_memory #(
    parameter integer MEMORY_BYTES = pkg_memory::MEMORY_BYTES,
    parameter logic [31:0] BASE_ADDRESS = pkg_memory::DATA_BASE_ADDRESS,
    parameter INIT_FILE = "",
    parameter integer INIT_BYTES = 0
) (
    input logic clk_i,
    input logic rst_ni,

    /** @brief Direccion fisica alineada; habilitadores a cero significan idle. */
    input pkg_memory::address_t address_i,
    input logic read_enable_i,
    input pkg_memory::byte_mask_t write_enable_i,
    input pkg_memory::word_t write_data_i,

    /**
     * @brief Lectura registrada y diagnostico de direccion de solicitud.
     * @details Fuera de rango no se indexa almacenamiento: se inhibe escritura
     * y la lectura devuelve cero sin read_valid. Reset elimina validez de
     * respuesta; la carga inicial pertenece a la inicializacion del modelo.
     */
    output pkg_memory::word_t read_data_o,
    output logic read_valid_o,
    output logic out_of_range_o
);
    /**
     * @brief Reutiliza la RAM de una palabra por acceso.
     * @details Los parametros configuran el mismo segmento de main_memory;
     * los puertos pasan solicitudes y respuestas sin agregar latencia.
     * El controlador externo genera clk_i y secuencia las ocho palabras.
     */
    memory_sp_ram #(
        .MEMORY_BYTES(MEMORY_BYTES),
        .BASE_ADDRESS(BASE_ADDRESS),
        .INIT_FILE(INIT_FILE),
        .INIT_BYTES(INIT_BYTES)
    ) u_storage (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .address_i(address_i),
        .read_enable_i(read_enable_i),
        .write_enable_i(write_enable_i),
        .write_data_i(write_data_i),
        .read_data_o(read_data_o),
        .read_valid_o(read_valid_o),
        .out_of_range_o(out_of_range_o)
    );
endmodule
