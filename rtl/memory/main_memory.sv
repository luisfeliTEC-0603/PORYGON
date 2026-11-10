/**
 * @brief Skeleton del almacenamiento de 64 KiB en el dominio de memoria.
 * @param MEMORY_BYTES Capacidad en bytes; 65536 por defecto.
 * @param BASE_ADDRESS Base fisica del segmento de datos.
 * @param INIT_FILE Imagen opcional de bytes para inicializacion.
 * @param INIT_BYTES Numero de bytes de la imagen; cero usa la imagen completa.
 * @input clk_i, rst_ni Reloj de memoria y su reset activo bajo.
 * @details Una palabra de 32 bits por ciclo, little endian. Lectura sincrona;
 * escritura en flanco positivo segun mascara. El controlador de bursts define
 * latencias, cruza relojes y confirma la linea completa. Esta frontera puede
 * reutilizar el almacenamiento de memory_sp_ram sin modificar su modulo.
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
    // TODO P2-03: almacenamiento e inicializacion bajo el controlador nuevo.
endmodule
