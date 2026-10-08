import pkg_vliw::*;

module register_file #(
    parameter integer DATA_WIDTH       = pkg_vliw::DATA_WIDTH,
    parameter integer NUM_REGS         = pkg_vliw::NUM_REGS,
    parameter integer REG_INDEX_WIDTH = $clog2(NUM_REGS)
) (
    input  logic  clk_i,
    input  logic  rst_ni,

    // Direcciones de lectura (3 bits cada una) para hasta 8 operandos simultáneos
    input  logic [REG_INDEX_WIDTH-1:0] read_addr_i [0:7],
    // Datos leídos de los registros direccionados (32 bits cada uno)
    output logic [DATA_WIDTH-1:0]      read_data_o [0:7],

    // Interfaces de Escritura (4 puertos paralelos para 4 slots VLIW)
    input  logic                      write_enable_i [0:3],
    input  logic [REG_INDEX_WIDTH-1:0] write_addr_i   [0:3],
    input  logic [DATA_WIDTH-1:0]      write_data_i   [0:3]
);

    // Arreglo de 8 registros de 32 bits para almacenar el estado del CPU
    logic [DATA_WIDTH-1:0] registers_q [0:NUM_REGS-1];

    // Variables de iteración para los bucles en bloques combinacionales y secuenciales
    integer register_index;
    integer read_port;
    integer write_port;

    // ========================================================================
    // Lógica Combinacional: Lectura Asíncrona Multi-Puerto (8 Puertos)
    // ========================================================================
    // Permite que la etapa de Decode/Dispatch lea hasta 8 operandos de forma 
    // inmediata sin esperar un flanco de reloj.
    always_comb begin
        for (read_port = 0; read_port < 8; read_port = read_port + 1) begin
            // Regla de Arquitectura: r0 (dirección 0) siempre entrega cero constante
            if (read_addr_i[read_port] == '0) begin
                read_data_o[read_port] = '0;
            end else begin
                // Lectura normal del contenido guardado en el banco de registros
                read_data_o[read_port] = registers_q[read_addr_i[read_port]];
            end
        end
    end

    // ========================================================================
    // Lógica Secuencial: Escritura Síncrona Multi-Puerto (4 Puertos) y Reset
    // ========================================================================
    // Ocurre en el flanco de subida de reloj (posedge clk_i) o ante el reset.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // Reset asíncrono: Limpia todos los registros a 0x00000000
            for (register_index = 0; register_index < NUM_REGS; register_index = register_index + 1) begin
                registers_q[register_index] <= '0;
            end
        end else begin
            // Procesamiento de escrituras en paralelo para los 4 slots de Writeback (WB)
            for (write_port = 0; write_port < 4; write_port = write_port + 1) begin
                // Protecciones de Escritura:
                // 1. Debe estar activo el habilitador de escritura (write_enable_i == 1).
                // 2. Regla de Arquitectura: r0 es de SOLO LECTURA (write_addr_i != 0).
                if (write_enable_i[write_port] && (write_addr_i[write_port] != '0)) begin
                    registers_q[write_addr_i[write_port]] <= write_data_i[write_port];
                end
            end
        end
    end

endmodule