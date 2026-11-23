/**
 * @brief Tipos y valores por defecto de la jerarquia de datos del Proyecto II.
 * @details Direcciones fisicas de 32 bits; lineas de 32 bytes little endian.
 * Byte base+k ocupa line[8*k +: 8]. Los anchos de identificador son derivados.
 * @see docs/ii-proyecto/hierarchy.md
 * @see docs/ii-proyecto/interfaces.md
 */
package pkg_memory;
    localparam integer LINE_BYTES = 32;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer WORDS_PER_LINE = 8;
    localparam integer L1_BYTES = 4096;
    localparam integer L1_WAYS = 2;
    localparam integer L2_BYTES = 16384;
    localparam integer L2_WAYS = 4;
    localparam integer L2_HIT_CYCLES = 8;
    localparam integer WRITE_BUFFER_DEPTH_DEFAULT = 4;
    localparam integer EVICTION_BUFFER_DEPTH_DEFAULT = 8;
    localparam integer L2_MAX_INFLIGHT_DEFAULT = 4;
    localparam integer MEM_CLOCK_DIV_DEFAULT = 2;
    localparam integer MEM_READ_FIRST_WORD_CYCLES_DEFAULT = 25;
    localparam integer MEM_WRITE_FIRST_WORD_CYCLES_DEFAULT = 25;
    localparam integer MEM_TIMEOUT_CYCLES_DEFAULT = 128;
    localparam integer CPU_HZ = 100000000;
    localparam integer MEMORY_BYTES = pkg_vliw::MEMORY_BYTES;
    localparam logic [31:0] DATA_BASE_ADDRESS = pkg_vliw::DATA_BASE_ADDRESS;

    typedef pkg_vliw::address_t address_t;
    typedef pkg_vliw::word_t word_t;
    typedef logic [LINE_BITS-1:0] line_t;
    typedef logic [3:0] byte_mask_t;

    /** @brief Codificacion de fill_source de interfaces.md; valor 3 reservado. */
    typedef enum logic [1:0] {
        FILL_WB = 2'd0,
        FILL_L2 = 2'd1,
        FILL_MEMORY = 2'd2,
        FILL_RESERVED = 2'd3
    } fill_source_t;

    /** @brief Ancho max(1, ceil(log2(entries))) para un identificador. */
    function automatic integer id_width(input integer entries);
        id_width = (entries > 1) ? $clog2(entries) : 1;
    endfunction
endpackage
